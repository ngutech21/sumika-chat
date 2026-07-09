struct DirectToolResultResponse: Equatable, Sendable {
  var content: String
  var modelProjectionPolicy: AssistantModelProjectionPolicy
}

enum ToolLoopDirectResponseRenderer {
  static func directResponse(
    after record: ToolCallRecord,
    toolResult: ToolResultModelMessage,
    request: ToolLoopRequest
  ) -> DirectToolResultResponse? {
    guard record.status == .completed else {
      return nil
    }

    switch record.resultPayload {
    case .finishTask(.success) where request.toolProfile == .agent:
      guard case .finishTask(let input) = record.request.payload else {
        return nil
      }
      return DirectToolResultResponse(
        content: input.summary,
        modelProjectionPolicy: .override(
          "Delivered finish_task summary directly to the user."
        )
      )
    case .readFile(.success(let path, _)) where record.request.toolName == .showFile:
      let projection = ToolResultProjector.project(
        payload: toolResult.payload, request: record.request)
      return DirectToolResultResponse(
        content: directReadFileResponse(path: path, display: projection.display),
        modelProjectionPolicy: .override(
          "Displayed show_file result for \(path.rawValue) directly to the user."
        )
      )
    case .listFiles(let result) where shouldRespondDirectlyToListFiles(request):
      let projection = ToolResultProjector.project(
        payload: toolResult.payload, request: record.request)
      return DirectToolResultResponse(
        content: directListFilesResponse(result: result, display: projection.display),
        modelProjectionPolicy: .override(
          "Displayed list_files result for \(result.root.rawValue) directly to the user."
        )
      )
    case .workspaceDiff(.success(let path, let content))
    where shouldRespondDirectlyToWorkspaceDiff(request):
      return DirectToolResultResponse(
        content: directWorkspaceDiffResponse(path: path, content: content),
        modelProjectionPolicy: .override("Displayed workspace_diff result directly to the user.")
      )
    default:
      return nil
    }
  }

  private static func directReadFileResponse(
    path: WorkspaceRelativePath,
    display: ToolDisplayPayload
  ) -> String {
    var response = "Here is `\(path.rawValue)`:"
    guard case .fileContent(_, let content) = display else {
      return response
    }
    let body = content.text.isEmpty ? "(empty)" : content.text
    response += "\n\n"
    response += fencedCodeBlock(for: body, path: path)
    if content.truncated {
      response += "\n\nResult truncated."
    }
    if content.redacted {
      response += "\n\nSome content was redacted."
    }
    return response
  }

  private static func fencedCodeBlock(for body: String, path: WorkspaceRelativePath) -> String {
    let fence = markdownFence(for: body)
    let language = CodeLanguage(filePath: path.rawValue)?.rawValue ?? ""
    let openingFence = language.isEmpty ? fence : "\(fence)\(language)"
    var block = "\(openingFence)\n\(body)"
    if !block.hasSuffix("\n") {
      block += "\n"
    }
    block += fence
    return block
  }

  private static func markdownFence(for body: String) -> String {
    var longestRun = 0
    var currentRun = 0

    for character in body {
      if character == "`" {
        currentRun += 1
        longestRun = max(longestRun, currentRun)
      } else {
        currentRun = 0
      }
    }

    return String(repeating: "`", count: max(3, longestRun + 1))
  }

  private static func directListFilesResponse(
    result: ListFilesResult,
    display: ToolDisplayPayload
  ) -> String {
    var response = "Files in `\(result.root.rawValue)`:"
    guard case .fileList(_, let entries, let truncated) = display else {
      return response
    }
    let body =
      entries.isEmpty
      ? "(empty)"
      : entries.map { entry in
        entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
      }.joined(separator: "\n")
    response += "\n\n"
    response += body.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "    \($0)" }
      .joined(separator: "\n")
    if truncated {
      response += "\n\nResult truncated."
    }
    return response
  }

  private static func directWorkspaceDiffResponse(
    path: WorkspaceRelativePath?,
    content: ToolTextOutput
  ) -> String {
    var response =
      if let path {
        "Workspace changes for `\(path.rawValue)`:"
      } else {
        "Workspace changes:"
      }
    let body = content.text.isEmpty ? "No workspace changes." : content.text
    response += "\n\n"
    response += body.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "    \($0)" }
      .joined(separator: "\n")
    if content.truncated {
      response += "\n\nResult truncated."
    }
    if content.redacted {
      response += "\n\nSome content was redacted."
    }
    return response
  }

  private static func shouldRespondDirectlyToListFiles(_ request: ToolLoopRequest) -> Bool {
    guard request.interactionMode == .agent,
      let userContent = latestUserRequestContent(for: request)
    else {
      return false
    }
    return isDirectListFilesRequest(userContent)
  }

  private static func latestUserRequestContent(for request: ToolLoopRequest) -> String? {
    guard
      let assistantIndex = request.items.firstIndex(where: {
        $0.messageID == request.assistantMessageID
      }
      )
    else {
      return request.items.reversed().compactMap(\.userContent).first
    }

    return request.items[..<assistantIndex].reversed().compactMap(\.userContent).first
  }

  private static func isDirectListFilesRequest(_ content: String) -> Bool {
    let lowered = content.lowercased()
    guard
      !containsAny(
        [
          " and ",
          " then ",
          "tell me",
          "summarize",
          "summary",
          "explain",
          "analy",
          "inspect",
          "read",
          "search",
          "find",
          "choose",
          "entry point",
          "structure",
          "which one",
          "which file should",
          "which file looks",
          "which file is",
        ],
        in: lowered
      )
    else {
      return false
    }

    let mentionsFile =
      containsAny(["file", "files"], in: lowered)
    let hasListVerb = containsAny(["list"], in: lowered)
    let asksWhichFiles = containsAny(
      ["what files", "which files"],
      in: lowered
    )
    let hasDisplayVerb = containsAny(
      ["show", "display", "print"],
      in: lowered
    )
    let mentionsDirectory = containsAny(
      ["directory", "current dir", "dir", "folder"],
      in: lowered
    )
    let mentionsPluralFiles = containsAny(["files"], in: lowered)

    return (hasListVerb && mentionsFile)
      || asksWhichFiles
      || (hasDisplayVerb && mentionsPluralFiles && mentionsDirectory)
  }

  private static func shouldRespondDirectlyToWorkspaceDiff(_ request: ToolLoopRequest) -> Bool {
    guard let userContent = latestUserRequestContent(for: request) else {
      return false
    }

    let lowered = userContent.lowercased()
    guard
      !containsAny(
        [
          " and ",
          " then ",
          "tell me",
          "summarize",
          "summary",
          "explain",
          "analy",
          "inspect",
          "review",
          "fix",
          "edit",
          "change it",
          "implement",
          "update",
          "which ",
          "erklär",
          "erklaer",
          "analys",
          "prüf",
          "pruef",
          "repar",
          "ändere",
          "aendere",
          "implementier",
        ],
        in: lowered
      )
    else {
      return false
    }

    let asksForDisplay = containsAny(
      ["show", "display", "print", "zeige", "zeig", "anzeigen"],
      in: lowered
    )
    let asksForDiff = containsAny(
      [
        "git diff",
        "workspace diff",
        "diff",
        "changes",
        "änderungen",
        "aenderungen",
        "git status",
        "git changes",
      ],
      in: lowered
    )

    return asksForDisplay && asksForDiff
  }

  private static func containsAny(_ needles: [String], in haystack: String) -> Bool {
    needles.contains { haystack.contains($0) }
  }
}
