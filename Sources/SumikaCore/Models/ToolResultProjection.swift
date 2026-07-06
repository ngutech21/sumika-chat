import Foundation

public struct ToolResultProjection: Equatable, Sendable {
  public let display: ToolDisplayPayload
  public let observation: ToolModelObservation
  public let metadata: ToolResultModelMetadata
}

public struct ToolResultModelMetadata: Equatable, Sendable {
  public var kind: String
  public var duplicate: Bool
  public var fields: [ToolResultModelMetadataField]
  public var nextAllowedActions: [String]
  public var notReexecuted: Bool
  public var replayedResultKind: String?
  public var forbiddenRepeat: Bool
  public var nextStep: String?

  public init(
    kind: String,
    duplicate: Bool = false,
    fields: [ToolResultModelMetadataField] = [],
    nextAllowedActions: [String] = [],
    notReexecuted: Bool = false,
    replayedResultKind: String? = nil,
    forbiddenRepeat: Bool = false,
    nextStep: String? = nil
  ) {
    self.kind = kind
    self.duplicate = duplicate
    self.fields = fields
    self.nextAllowedActions = nextAllowedActions
    self.notReexecuted = notReexecuted
    self.replayedResultKind = replayedResultKind
    self.forbiddenRepeat = forbiddenRepeat
    self.nextStep = nextStep
  }
}

public struct ToolResultModelMetadataField: Equatable, Sendable {
  public var name: String
  public var value: ToolResultModelMetadataValue

  public init(name: String, value: ToolResultModelMetadataValue) {
    self.name = name
    self.value = value
  }
}

public indirect enum ToolResultModelMetadataValue: Equatable, Sendable {
  case array([ToolResultModelMetadataValue])
  case string(String)
  case int(Int)
  case bool(Bool)
  case null
}

public enum ProjectionLimitStrategy: Equatable, Sendable {
  case head
  case tail
  case headTail
}

public struct ProjectionLimit: Equatable, Sendable {
  public var maxCharacters: Int
  public var strategy: ProjectionLimitStrategy

  public init(maxCharacters: Int, strategy: ProjectionLimitStrategy) {
    self.maxCharacters = maxCharacters
    self.strategy = strategy
  }

  public static let defaultModelObservation = ProjectionLimit(
    maxCharacters: 8_000,
    strategy: .headTail
  )
}

public struct ProjectionLimitResult: Equatable, Sendable {
  public let text: String
  public let wasLimited: Bool
}

public enum ProjectionLimiter {
  private static let marker = "\n[tool observation truncated]\n"

  public static func limit(_ text: String, limit: ProjectionLimit) -> ProjectionLimitResult {
    guard text.count > limit.maxCharacters else {
      return ProjectionLimitResult(text: text, wasLimited: false)
    }
    guard limit.maxCharacters > 0 else {
      return ProjectionLimitResult(text: "", wasLimited: true)
    }

    let marker = truncatedMarker(maxCharacters: limit.maxCharacters)
    let availableCharacters = max(0, limit.maxCharacters - marker.count)

    let limitedText =
      switch limit.strategy {
      case .head:
        String(text.prefix(availableCharacters)) + marker
      case .tail:
        marker + String(text.suffix(availableCharacters))
      case .headTail:
        headTailLimitedText(text, marker: marker, availableCharacters: availableCharacters)
      }

    return ProjectionLimitResult(text: limitedText, wasLimited: true)
  }

  private static func truncatedMarker(maxCharacters: Int) -> String {
    guard marker.count <= maxCharacters else {
      return String(marker.prefix(maxCharacters))
    }
    return marker
  }

  private static func headTailLimitedText(
    _ text: String,
    marker: String,
    availableCharacters: Int
  ) -> String {
    let headCount = (availableCharacters + 1) / 2
    let tailCount = availableCharacters / 2
    return String(text.prefix(headCount)) + marker + String(text.suffix(tailCount))
  }
}

public enum ToolDisplayPayload: Equatable, Sendable {
  case fileContent(path: WorkspaceRelativePath, content: ToolTextOutput)
  case fileList(root: WorkspaceRelativePath, entries: [WorkspaceFileEntry], truncated: Bool)
  case searchResults(
    root: WorkspaceRelativePath,
    pattern: String,
    matches: [SearchFileMatch],
    truncated: Bool
  )
  case workspaceDiff(path: WorkspaceRelativePath?, content: ToolTextOutput)
  case summary(status: ToolResultStatus, text: String, affectedPaths: [WorkspaceRelativePath])
}

public struct ToolModelObservation: Codable, Equatable, Sendable {
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let affectedPaths: [WorkspaceRelativePath]
  public let blocks: [ToolObservationBlock]

  private init(
    toolName: ToolName,
    status: ToolResultStatus,
    affectedPaths: [WorkspaceRelativePath],
    blocks: [ToolObservationBlock]
  ) {
    self.toolName = toolName
    self.status = status
    self.affectedPaths = affectedPaths
    self.blocks = blocks
  }

  static func success(
    toolName: ToolName,
    affectedPaths: [WorkspaceRelativePath],
    blocks: [ToolObservationBlock]
  ) -> ToolModelObservation {
    precondition(
      !blocks.contains(where: \.isFailure),
      "Success tool observations cannot contain failure blocks."
    )
    return ToolModelObservation(
      toolName: toolName,
      status: .success,
      affectedPaths: affectedPaths,
      blocks: blocks
    )
  }

  static func structured(
    toolName: ToolName,
    status: ToolResultStatus,
    affectedPaths: [WorkspaceRelativePath],
    blocks: [ToolObservationBlock]
  ) -> ToolModelObservation {
    precondition(
      status != .denied,
      "Denied tool observations require failure text."
    )
    if status == .success {
      precondition(
        !blocks.contains(where: \.isFailure),
        "Success tool observations cannot contain failure blocks."
      )
    }
    return ToolModelObservation(
      toolName: toolName,
      status: status,
      affectedPaths: affectedPaths,
      blocks: blocks
    )
  }

  static func failed(
    toolName: ToolName,
    affectedPaths: [WorkspaceRelativePath],
    text: String
  ) -> ToolModelObservation {
    failure(
      toolName: toolName,
      status: .failed,
      affectedPaths: affectedPaths,
      text: text
    )
  }

  static func denied(
    toolName: ToolName,
    affectedPaths: [WorkspaceRelativePath],
    text: String
  ) -> ToolModelObservation {
    failure(
      toolName: toolName,
      status: .denied,
      affectedPaths: affectedPaths,
      text: text
    )
  }

  private static func failure(
    toolName: ToolName,
    status: ToolResultStatus,
    affectedPaths: [WorkspaceRelativePath],
    text: String
  ) -> ToolModelObservation {
    ToolModelObservation(
      toolName: toolName,
      status: status,
      affectedPaths: affectedPaths,
      blocks: [.failure(text)]
    )
  }
}

public enum ToolObservationBlock: Codable, Equatable, Sendable {
  case summary(String)
  case fileDisplayedToUser(
    path: WorkspaceRelativePath,
    range: String?,
    lineCount: Int?,
    byteCount: Int?,
    truncated: Bool,
    redacted: Bool
  )
  case fileContent(path: WorkspaceRelativePath, content: ToolTextOutput)
  case fileList(
    root: WorkspaceRelativePath,
    entries: [WorkspaceFileEntry],
    totalCount: Int,
    truncated: Bool
  )
  case searchSnippets(
    root: WorkspaceRelativePath,
    pattern: String,
    matches: [SearchFileMatch],
    totalCount: Int,
    truncated: Bool
  )
  case editReceipt(
    path: WorkspaceRelativePath,
    diffSummary: String?,
    matchStrategy: EditMatchStrategy?
  )
  case commandResult(RunCommandResult)
  case diagnostics(WorkspaceDiagnosticsResult)
  case webSearch(
    query: String, provider: WebSearchProvider, results: [WebSearchResult], truncated: Bool)
  case webFetch(
    url: String,
    provider: WebFetchProvider?,
    finalURL: String,
    statusCode: Int,
    contentType: String?,
    content: ToolTextOutput,
    byteCount: Int
  )
  case failure(String)
}

extension ToolObservationBlock {
  fileprivate var isFailure: Bool {
    if case .failure = self {
      return true
    }
    return false
  }
}

public struct ToolResultProjectionPolicy: Equatable, Sendable {
  public var maxListObservationEntries: Int
  public var maxSearchObservationSnippets: Int
  public var includeShowFileBodyInObservation: Bool
  public var includeReadFileBodyInObservation: Bool
  public var modelObservationLimit: ProjectionLimit

  public init(
    maxListObservationEntries: Int = 40,
    maxSearchObservationSnippets: Int = 20,
    includeShowFileBodyInObservation: Bool = false,
    includeReadFileBodyInObservation: Bool = true,
    modelObservationLimit: ProjectionLimit = .defaultModelObservation
  ) {
    self.maxListObservationEntries = maxListObservationEntries
    self.maxSearchObservationSnippets = maxSearchObservationSnippets
    self.includeShowFileBodyInObservation = includeShowFileBodyInObservation
    self.includeReadFileBodyInObservation = includeReadFileBodyInObservation
    self.modelObservationLimit = modelObservationLimit
  }

  public static let `default` = ToolResultProjectionPolicy()
}

public enum ToolResultProjector {
  public static func project(
    payload: ToolResultPayload,
    request: ToolCallRequest,
    policy: ToolResultProjectionPolicy = .default
  ) -> ToolResultProjection {
    switch payload {
    case .readFile(let result):
      return projectReadFile(result, request: request, policy: policy)
    case .listFiles(let result):
      return projectListFiles(result, request: request, policy: policy)
    case .globFiles(let result):
      return projectGlobFiles(result, request: request, policy: policy)
    case .searchFiles(let result):
      return projectSearchFiles(result, request: request, policy: policy)
    case .workspaceDiff(let result):
      return projectWorkspaceDiff(result, request: request)
    case .workspaceDiagnostics(let result):
      return projectWorkspaceDiagnostics(result, request: request)
    case .writeFile(let result):
      return projectWriteFile(result, request: request)
    case .editFile(let result):
      return projectEditFile(result, request: request)
    case .runCommand(let result):
      return projectRunCommand(result, request: request)
    case .todoWrite(let result):
      return projectTodoWrite(result, request: request)
    case .askUser(let result):
      return projectAskUser(result, request: request)
    case .browserRefresh(let result):
      return projectBrowserRefresh(result, request: request)
    case .browserInspect(let result):
      return projectBrowserInspect(result, request: request)
    case .webSearch(let result):
      return projectWebSearch(result, request: request, policy: policy)
    case .webFetch(let result):
      return projectWebFetch(result, request: request)
    case .duplicateToolCall(let result):
      return duplicateProjection(result, request: request)
    case .invalidTool(let result):
      let text = invalidToolText(result, request: request)
      return summaryProjection(
        toolName: request.toolName,
        status: .failed,
        text: text,
        affectedPaths: []
      )
    case .failure(let failure):
      return summaryProjection(
        toolName: request.toolName,
        status: failure.reason.projectedStatus,
        text: failure.projectedText,
        affectedPaths: failure.path.map { [$0] } ?? []
      )
    }
  }

}

private func toolResultProjection(
  display: ToolDisplayPayload,
  observation: ToolModelObservation,
  kind: String? = nil,
  metadataFields: [ToolResultModelMetadataField]? = nil,
  nextAllowedActions: [String]? = nil,
  duplicate: Bool = false,
  notReexecuted: Bool = false,
  replayedResultKind: String? = nil,
  forbiddenRepeat: Bool = false,
  nextStep: String? = nil
) -> ToolResultProjection {
  let primaryBlock = primaryResultBlock(from: observation.blocks)
  let resolvedKind = kind ?? resultKind(for: observation)
  let resolvedFields = metadataFields ?? primaryBlock.map(metadataFields(for:)) ?? []
  let resolvedNextAllowedActions =
    nextAllowedActions
    ?? defaultNextAllowedActions(
      for: observation.toolName,
      block: primaryBlock
    )

  return ToolResultProjection(
    display: display,
    observation: observation,
    metadata: ToolResultModelMetadata(
      kind: resolvedKind,
      duplicate: duplicate,
      fields: resolvedFields,
      nextAllowedActions: resolvedNextAllowedActions,
      notReexecuted: notReexecuted,
      replayedResultKind: replayedResultKind,
      forbiddenRepeat: forbiddenRepeat,
      nextStep: nextStep
    )
  )
}

private func resultKind(for observation: ToolModelObservation) -> String {
  guard let primaryBlock = primaryResultBlock(from: observation.blocks) else {
    return observation.status == .success ? "summary" : "failure"
  }
  return resultKind(for: primaryBlock)
}

private func resultKind(for block: ToolObservationBlock) -> String {
  switch block {
  case .summary:
    return "summary"
  case .fileDisplayedToUser:
    return "file_displayed"
  case .fileContent:
    return "file_content"
  case .fileList:
    return "listing"
  case .searchSnippets:
    return "search_matches"
  case .editReceipt:
    return "edit_receipt"
  case .commandResult:
    return "command_result"
  case .diagnostics:
    return "diagnostics"
  case .webSearch:
    return "web_search"
  case .webFetch:
    return "web_fetch"
  case .failure:
    return "failure"
  }
}

private func primaryResultBlock(from blocks: [ToolObservationBlock]) -> ToolObservationBlock? {
  blocks.first { block in
    if case .summary = block {
      return false
    }
    return true
  }
}

private func metadataFields(for block: ToolObservationBlock) -> [ToolResultModelMetadataField] {
  switch block {
  case .summary:
    return []
  case .fileDisplayedToUser(
    let path,
    let range,
    let lineCount,
    let byteCount,
    let truncated,
    let redacted
  ):
    return [
      .init(name: "path", value: .string(path.rawValue)),
      .init(name: "range", value: range.map(ToolResultModelMetadataValue.string) ?? .null),
      .init(name: "line_count", value: lineCount.map(ToolResultModelMetadataValue.int) ?? .null),
      .init(name: "byte_count", value: byteCount.map(ToolResultModelMetadataValue.int) ?? .null),
      .init(name: "truncated", value: .bool(truncated)),
      .init(name: "redacted", value: .bool(redacted)),
    ]
  case .fileContent(let path, let content):
    return [
      .init(name: "path", value: .string(path.rawValue)),
      .init(name: "truncated", value: .bool(content.truncated)),
      .init(name: "redacted", value: .bool(content.redacted)),
    ]
  case .fileList(let root, let entries, let totalCount, let truncated):
    return [
      .init(name: "path", value: .string(root.rawValue)),
      .init(name: "entry_count", value: .int(totalCount)),
      .init(name: "visible_entry_count", value: .int(entries.count)),
      .init(name: "truncated", value: .bool(truncated)),
    ]
  case .searchSnippets(let root, let pattern, let matches, let totalCount, let truncated):
    return [
      .init(name: "path", value: .string(root.rawValue)),
      .init(name: "pattern", value: .string(pattern)),
      .init(name: "match_count", value: .int(totalCount)),
      .init(name: "visible_match_count", value: .int(matches.count)),
      .init(name: "truncated", value: .bool(truncated)),
    ]
  case .editReceipt(let path, _, let matchStrategy):
    var fields = [ToolResultModelMetadataField(name: "path", value: .string(path.rawValue))]
    if let matchStrategy {
      fields.append(.init(name: "match_strategy", value: .string(matchStrategy.rawValue)))
    }
    return fields
  case .commandResult(let result):
    var fields: [ToolResultModelMetadataField] = [
      .init(name: "command", value: .string(result.command)),
      .init(
        name: "exit_code",
        value: result.exitCode.map { .int(Int($0)) } ?? .null
      ),
      .init(name: "timed_out", value: .bool(result.timedOut)),
      .init(name: "cancelled", value: .bool(result.cancelled)),
      .init(name: "stdout_present", value: .bool(!result.stdout.text.isEmpty)),
      .init(name: "stdout_truncated", value: .bool(result.stdout.truncated)),
      .init(name: "stderr_present", value: .bool(!result.stderr.text.isEmpty)),
      .init(name: "stderr_truncated", value: .bool(result.stderr.truncated)),
    ]
    if let outputRef = result.outputRef {
      fields.append(.init(name: "output_ref", value: .string(outputRef)))
    }
    return fields
  case .diagnostics(let result):
    return [
      .init(name: "output_ref", value: .string(result.outputRef)),
      .init(name: "diagnostic_count", value: .int(result.diagnostics.count)),
    ]
  case .webSearch(let query, let provider, let results, let truncated):
    return [
      .init(name: "query", value: .string(query)),
      .init(name: "provider", value: .string(provider.displayName)),
      .init(name: "result_count", value: .int(results.count)),
      .init(name: "truncated", value: .bool(truncated)),
    ]
  case .webFetch(
    let url, let provider, let finalURL, let statusCode, let contentType, let content,
    let byteCount):
    return [
      .init(name: "url", value: .string(url)),
      .init(name: "final_url", value: .string(finalURL)),
      .init(name: "provider", value: .string(provider?.displayName ?? "unknown")),
      .init(name: "status_code", value: .int(statusCode)),
      .init(
        name: "content_type",
        value: contentType.map(ToolResultModelMetadataValue.string) ?? .null
      ),
      .init(name: "byte_count", value: .int(byteCount)),
      .init(name: "truncated", value: .bool(content.truncated)),
      .init(name: "redacted", value: .bool(content.redacted)),
    ]
  case .failure:
    return []
  }
}

private func defaultNextAllowedActions(
  for toolName: ToolName,
  block: ToolObservationBlock?
) -> [String] {
  switch toolName {
  case .listFiles, .globFiles, .searchFiles:
    return ["read_file", "final_answer"]
  case .readFile:
    return ["edit_file", "final_answer"]
  case .runCommand:
    if case .commandResult(let result) = block, result.outputRef != nil {
      return ["workspace_diagnostics", "final_answer"]
    }
    return ["final_answer"]
  case .webSearch:
    return ["web_fetch", "final_answer"]
  case .workspaceDiagnostics:
    return ["read_file", "edit_file", "final_answer"]
  case .workspaceDiff, .webFetch, .showFile, .editFile, .writeFile, .askUser, .browserRefresh,
    .browserInspect, .todoWrite, .invalid:
    return ["final_answer"]
  default:
    return ["final_answer"]
  }
}

private func duplicateProjection(
  _ result: DuplicateToolCallResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  let replayedObservation = result.replayedObservation
  let affectedPaths =
    if result.affectedPaths.isEmpty {
      replayedObservation?.affectedPaths ?? []
    } else {
      result.affectedPaths
    }
  // A blocked (2nd+) duplicate withholds the replayed content and is framed non-success
  // FOR THE MODEL only (a denied observation), to break the loop. The UI/persisted
  // display below stays `.success` (benign "duplicate replay").
  let observation: ToolModelObservation
  if result.blocked {
    observation = ToolModelObservation.denied(
      toolName: request.toolName,
      affectedPaths: affectedPaths,
      text: duplicateContentSummary(result)
    )
  } else {
    observation = ToolModelObservation.structured(
      toolName: request.toolName,
      status: replayedObservation?.status ?? .success,
      affectedPaths: affectedPaths,
      blocks: [ToolObservationBlock.summary(duplicateContentSummary(result))]
        + (replayedObservation?.blocks ?? [])
    )
  }

  return toolResultProjection(
    display: .summary(status: .success, text: result.message, affectedPaths: affectedPaths),
    observation: observation,
    kind: "duplicate_replay",
    duplicate: true,
    notReexecuted: true,
    replayedResultKind: replayedObservation.map { resultKind(for: $0) },
    forbiddenRepeat: true,
    nextStep: duplicateNextStepHint(for: request.toolName)
  )
}

private func duplicateContentSummary(_ result: DuplicateToolCallResult) -> String {
  let previousCallID = RuntimeToolCallID.string(for: result.previousCallID)
  let prefix = "Duplicate of \(previousCallID): "
  guard result.message.hasPrefix(prefix) else {
    return result.message
  }
  return "Duplicate replay: " + result.message.dropFirst(prefix.count)
}

private func duplicateNextStepHint(for toolName: ToolName) -> String {
  switch toolName {
  case .readFile:
    return
      "Next step: use the replayed file content to answer or edit. Do not call read_file again with identical arguments unless the file changed or you need a different range."
  case .listFiles:
    return
      "Next step: choose a path and call read_file, or answer. Do not call list_files again with identical arguments."
  case .globFiles:
    return
      "Next step: choose a matched path and call read_file, or answer. Do not call glob_files again with identical arguments."
  case .searchFiles:
    return
      "Next step: choose a matched path and call read_file, or answer. Do not call search_files again with identical arguments."
  case .workspaceDiff:
    return
      "Next step: use the replayed diff to answer or choose a specific file. Do not call workspace_diff again with identical arguments."
  case .workspaceDiagnostics:
    return
      "Next step: use the replayed diagnostics to fix or answer. Do not call workspace_diagnostics again with identical arguments."
  case .webSearch:
    return
      "Next step: use these results, call web_fetch for a specific URL, or answer. Do not call web_search again with identical arguments."
  case .webFetch:
    return
      "Next step: use the replayed page content to answer. Do not call web_fetch again with identical arguments."
  default:
    return
      "Next step: use the replayed result or answer. Do not call this tool again with identical arguments."
  }
}

private func invalidToolText(
  _ result: InvalidToolResult,
  request: ToolCallRequest
) -> String {
  let baseText = "The tool call was invalid: \(result.reason.message)"
  switch request.toolName {
  case .editFile:
    return """
      \(baseText)
      No file was changed.
      Do not claim completion.
      Retry edit_file with path, old_text, and new_text, or say no change was made.
      If old_text is unknown, call read_file first.
      """
  case .writeFile:
    return """
      \(baseText)
      No file was changed.
      Do not claim completion.
      Retry write_file with path and content, or say no change was made.
      """
  default:
    return baseText
  }
}

private func summaryProjection(
  toolName: ToolName,
  status: ToolResultStatus,
  text: String,
  affectedPaths: [WorkspaceRelativePath],
  kind: String? = nil
) -> ToolResultProjection {
  let observation =
    switch status {
    case .success:
      ToolModelObservation.success(
        toolName: toolName,
        affectedPaths: affectedPaths,
        blocks: [.summary(text)]
      )
    case .failed:
      ToolModelObservation.failed(
        toolName: toolName,
        affectedPaths: affectedPaths,
        text: text
      )
    case .denied:
      ToolModelObservation.denied(
        toolName: toolName,
        affectedPaths: affectedPaths,
        text: text
      )
    }

  return toolResultProjection(
    display: .summary(status: status, text: text, affectedPaths: affectedPaths),
    observation: observation,
    kind: kind
  )
}

private func projectReadFile(
  _ result: ReadFileResult,
  request: ToolCallRequest,
  policy: ToolResultProjectionPolicy
) -> ToolResultProjection {
  switch result {
  case .success(let path, let content):
    let includeBody =
      request.toolName == .showFile
      ? policy.includeShowFileBodyInObservation
      : policy.includeReadFileBodyInObservation
    return toolResultProjection(
      display: .fileContent(path: path, content: content),
      observation: ToolModelObservation.success(
        toolName: request.toolName,
        affectedPaths: [path],
        blocks: [
          includeBody
            ? .fileContent(path: path, content: content)
            : .fileDisplayedToUser(
              path: path,
              range: readRange(from: request),
              lineCount: lineCount(content.text),
              byteCount: content.text.utf8.count,
              truncated: content.truncated,
              redacted: content.redacted
            )
        ]
      )
    )
  case .unchanged(let path, let readKey):
    return summaryProjection(
      toolName: request.toolName,
      status: .success,
      text:
        "File unchanged since previous read: \(path.rawValue)\(readKey.range.map { " for \($0)" } ?? "").",
      affectedPaths: [path]
    )
  case .repeatedReadWarning(let path, let count):
    return summaryProjection(
      toolName: request.toolName,
      status: .success,
      text:
        "Repeated read_file loop detected for \(path.rawValue) after \(count) reads. Stop reading this file again unless it changed or you need a different range.",
      affectedPaths: [path]
    )
  case .failed(let path, let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: path.map { [$0] } ?? []
    )
  }
}

private func projectListFiles(
  _ result: ListFilesResult,
  request: ToolCallRequest,
  policy: ToolResultProjectionPolicy
) -> ToolResultProjection {
  toolResultProjection(
    display: .fileList(root: result.root, entries: result.entries, truncated: result.truncated),
    observation: ToolModelObservation.success(
      toolName: request.toolName,
      affectedPaths: [result.root],
      blocks: [
        .fileList(
          root: result.root,
          entries: Array(result.entries.prefix(policy.maxListObservationEntries)),
          totalCount: result.entries.count,
          truncated: result.truncated
            || result.entries.count > policy.maxListObservationEntries,
        )
      ]
    )
  )
}

private func projectGlobFiles(
  _ result: GlobFilesResult,
  request: ToolCallRequest,
  policy: ToolResultProjectionPolicy
) -> ToolResultProjection {
  let entries = result.matches.map { WorkspaceFileEntry(path: $0, kind: .file) }
  return toolResultProjection(
    display: .fileList(root: result.root, entries: entries, truncated: result.truncated),
    observation: ToolModelObservation.success(
      toolName: request.toolName,
      affectedPaths: [result.root],
      blocks: [
        .summary("Matched pattern \(result.pattern)."),
        .fileList(
          root: result.root,
          entries: Array(entries.prefix(policy.maxListObservationEntries)),
          totalCount: entries.count,
          truncated: result.truncated || entries.count > policy.maxListObservationEntries,
        ),
      ]
    )
  )
}

private func projectSearchFiles(
  _ result: SearchFilesResult,
  request: ToolCallRequest,
  policy: ToolResultProjectionPolicy
) -> ToolResultProjection {
  toolResultProjection(
    display: .searchResults(
      root: result.root,
      pattern: result.pattern,
      matches: result.matches,
      truncated: result.truncated
    ),
    observation: ToolModelObservation.success(
      toolName: request.toolName,
      affectedPaths: [result.root],
      blocks: [
        .searchSnippets(
          root: result.root,
          pattern: result.pattern,
          matches: Array(result.matches.prefix(policy.maxSearchObservationSnippets)),
          totalCount: result.matches.count,
          truncated: result.truncated
            || result.matches.count > policy.maxSearchObservationSnippets,
        )
      ]
    )
  )
}

private func projectWorkspaceDiff(
  _ result: WorkspaceDiffResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  switch result {
  case .success(let path, let content):
    let affectedPaths = [path ?? WorkspaceRelativePath(rawValue: ".")]
    return toolResultProjection(
      display: .workspaceDiff(path: path, content: content),
      observation: ToolModelObservation.success(
        toolName: request.toolName,
        affectedPaths: affectedPaths,
        blocks: [.summary(content.text)]
      ),
      kind: "workspace_diff",
      metadataFields: [
        ToolResultModelMetadataField(
          name: "path",
          value: path.map { .string($0.rawValue) } ?? .null
        ),
        ToolResultModelMetadataField(name: "truncated", value: .bool(content.truncated)),
        ToolResultModelMetadataField(name: "redacted", value: .bool(content.redacted)),
      ]
    )
  case .failed(let path, let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: path.map { [$0] } ?? []
    )
  }
}

private func projectWorkspaceDiagnostics(
  _ result: WorkspaceDiagnosticsResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  let affectedPaths = result.diagnostics.map(\.path)
  let text = renderedDiagnosticsText(result)
  return toolResultProjection(
    display: .summary(
      status: .success,
      text: text,
      affectedPaths: affectedPaths
    ),
    observation: ToolModelObservation.success(
      toolName: request.toolName,
      affectedPaths: affectedPaths,
      blocks: [.diagnostics(result)]
    )
  )
}

private func projectWriteFile(
  _ result: WriteFileResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  switch result {
  case .success(let path, let bytesWritten):
    return toolResultProjection(
      display: .summary(
        status: .success,
        text: "Wrote \(bytesWritten) bytes to \(path.rawValue).",
        affectedPaths: [path]
      ),
      observation: ToolModelObservation.success(
        toolName: request.toolName,
        affectedPaths: [path],
        blocks: [.summary("Wrote \(bytesWritten) bytes to \(path.rawValue).")]
      )
    )
  case .failed(let path, let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: path.map { [$0] } ?? []
    )
  }
}

private func projectEditFile(
  _ result: EditFileResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  switch result {
  case .success(let path, let diff, let matchStrategy):
    return toolResultProjection(
      display: .summary(
        status: .success,
        text: diff ?? "Edited \(path.rawValue).",
        affectedPaths: [path]
      ),
      observation: ToolModelObservation.success(
        toolName: request.toolName,
        affectedPaths: [path],
        blocks: [.editReceipt(path: path, diffSummary: diff, matchStrategy: matchStrategy)]
      )
    )
  case .oldTextNotFound(let path, let currentContent, let recovery):
    let text = editMismatchObservationText(
      path: path,
      currentContent: currentContent,
      recovery: recovery
    )
    let displayText =
      currentContent.map {
        "edit_file failed: old_text was not found in \(path.rawValue). \(recovery.message)\n\nCurrent file excerpt:\n\($0.text)"
      }
      ?? text
    return toolResultProjection(
      display: .summary(status: .failed, text: displayText, affectedPaths: [path]),
      observation: ToolModelObservation.failed(
        toolName: request.toolName,
        affectedPaths: [path],
        text: text
      )
    )
  case .multipleMatches(let path, let matchCount, let recovery):
    return summaryProjection(
      toolName: request.toolName,
      status: .failed,
      text:
        "edit_file failed: old_text matched more than once in \(path.rawValue) (\(matchCount) matches). \(recovery.message)",
      affectedPaths: [path]
    )
  case .unchanged(let path):
    return summaryProjection(
      toolName: request.toolName,
      status: .success,
      text: "No changes were needed for \(path.rawValue).",
      affectedPaths: [path]
    )
  case .failed(let path, let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: path.map { [$0] } ?? []
    )
  }
}

private func projectRunCommand(
  _ result: RunCommandResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  let status = result.outcomeStatus
  let affectedPaths = [WorkspaceRelativePath(rawValue: ".")]
  var blocks: [ToolObservationBlock] = [.commandResult(result)]
  if status == .failed {
    blocks.append(.failure(runCommandFailureGuidance(for: result)))
  }
  return toolResultProjection(
    display: .summary(
      status: status,
      text: result.previewText,
      affectedPaths: affectedPaths
    ),
    observation: ToolModelObservation.structured(
      toolName: request.toolName,
      status: status,
      affectedPaths: affectedPaths,
      blocks: blocks
    )
  )
}

private func runCommandFailureGuidance(for result: RunCommandResult) -> String {
  var lines = [
    "Command failed.",
    "Exit code: \(result.exitCode.map(String.init) ?? "none").",
    "The command did not complete successfully.",
  ]
  if result.timedOut {
    lines.append("The command timed out.")
  }
  if result.cancelled {
    lines.append("The command was cancelled.")
  }
  lines.append(
    "Do not report the requested task as complete based on this failed command."
  )
  lines.append(
    "Do not infer workspace state from this failure alone; verify with tools when state matters."
  )
  lines.append(
    "Next step: inspect the output, run workspace_diagnostics with the outputRef if useful, rerun a corrected command, or tell the user the command failed."
  )
  return lines.joined(separator: "\n")
}

private func projectTodoWrite(
  _ result: TodoWriteResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  switch result {
  case .success:
    return summaryProjection(
      toolName: request.toolName,
      status: .success,
      text: "Plan updated.",
      affectedPaths: [],
      kind: "plan_update"
    )
  case .failed(let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: []
    )
  }
}

private func projectAskUser(
  _ result: AskUserResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  summaryProjection(
    toolName: request.toolName,
    status: .success,
    text: "User answered: \(result.answer)",
    affectedPaths: []
  )
}

private func projectBrowserRefresh(
  _ result: BrowserRefreshResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  switch result {
  case .success(let path, let url, let hard):
    let affectedPaths = path.map { [$0] } ?? []
    let urlText = url.map { "\nURL: \($0)" } ?? ""
    return summaryProjection(
      toolName: request.toolName,
      status: .success,
      text: "Reloaded current preview.\nHard reload: \(hard)\(urlText)",
      affectedPaths: affectedPaths
    )
  case .failed(let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: []
    )
  }
}

private func projectBrowserInspect(
  _ result: BrowserInspectResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  switch result {
  case .success(let path, let title, let url, let selector, let text, let html):
    let affectedPaths = path.map { [$0] } ?? []
    var body = [
      "Title: \(title)",
      "URL: \(url)",
      "Scope: \(selector ?? "document.body")",
      "Text truncated: \(text.truncated)",
      "",
      "Text:",
      text.text,
    ]
    if let html {
      body.append("")
      body.append("HTML truncated: \(html.truncated)")
      body.append("")
      body.append("HTML:")
      body.append(html.text)
    }
    return summaryProjection(
      toolName: request.toolName,
      status: .success,
      text: body.joined(separator: "\n"),
      affectedPaths: affectedPaths
    )
  case .failed(let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: []
    )
  }
}

private func projectWebSearch(
  _ result: WebSearchToolResult,
  request: ToolCallRequest,
  policy: ToolResultProjectionPolicy
) -> ToolResultProjection {
  switch result {
  case .success(let query, let provider, let results, let truncated):
    let projectedResults = Array(results.prefix(WebAccessLimits.maxSearchObservationResults))
    return toolResultProjection(
      display: .summary(
        status: .success,
        text: webSearchDisplayText(query: query, provider: provider, results: results),
        affectedPaths: []
      ),
      observation: ToolModelObservation.success(
        toolName: request.toolName,
        affectedPaths: [],
        blocks: [
          .webSearch(
            query: query,
            provider: provider,
            results: projectedResults,
            truncated: truncated || results.count > projectedResults.count
              || results.count > policy.maxSearchObservationSnippets
          )
        ]
      )
    )
  case .failed(_, let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: reason.message,
      affectedPaths: []
    )
  }
}

private func projectWebFetch(
  _ result: WebFetchToolResult,
  request: ToolCallRequest
) -> ToolResultProjection {
  switch result {
  case .success(
    let url, let provider, let finalURL, let statusCode, let contentType, let content,
    let byteCount):
    return toolResultProjection(
      display: .summary(
        status: .success,
        text: webFetchDisplayText(
          url: url,
          provider: provider,
          finalURL: finalURL,
          statusCode: statusCode,
          contentType: contentType,
          content: content,
          byteCount: byteCount
        ),
        affectedPaths: []
      ),
      observation: ToolModelObservation.success(
        toolName: request.toolName,
        affectedPaths: [],
        blocks: [
          .webFetch(
            url: url,
            provider: provider,
            finalURL: finalURL,
            statusCode: statusCode,
            contentType: contentType,
            content: content,
            byteCount: byteCount
          )
        ]
      )
    )
  case .failed(_, let provider, _, let reason):
    return summaryProjection(
      toolName: request.toolName,
      status: reason.projectedStatus,
      text: "Fetch provider: \(webFetchProviderDisplayName(provider))\n\(reason.message)",
      affectedPaths: []
    )
  }
}

private func renderedDiagnosticsText(_ result: WorkspaceDiagnosticsResult) -> String {
  guard !result.diagnostics.isEmpty else {
    return "No diagnostics found for \(result.outputRef)."
  }

  return result.diagnostics.map { diagnostic in
    let column = diagnostic.column.map { ":\($0)" } ?? ""
    return
      "\(diagnostic.path.rawValue):\(diagnostic.line)\(column): \(diagnostic.severity.rawValue): \(diagnostic.message)"
  }.joined(separator: "\n")
}

private func editMismatchObservationText(
  path: WorkspaceRelativePath,
  currentContent: ToolTextOutput?,
  recovery: RecoveryHint
) -> String {
  var sections = [
    "edit_file failed: old_text was not found in \(path.rawValue).",
    """
    Do not retry edit_file from memory. First call read_file(path: "\(path.rawValue)"), then retry edit_file with the smallest exact current text span that appears once.
    """,
    recovery.message,
  ]

  if let currentContent {
    let limited = ProjectionLimiter.limit(
      currentContent.text,
      limit: ProjectionLimit(maxCharacters: 4_000, strategy: .headTail)
    )
    let truncatedText =
      currentContent.truncated || limited.wasLimited
      ? "Current file excerpt (truncated):"
      : "Current file excerpt:"
    sections.append("\(truncatedText)\n\(limited.text)")
  }

  return sections.joined(separator: "\n\n")
}

private func webSearchDisplayText(
  query: String,
  provider: WebSearchProvider,
  results: [WebSearchResult]
) -> String {
  let resultText =
    results.isEmpty
    ? "(no results)"
    : results.enumerated().map { index, result in
      let snippet = result.snippet.map { "\n\($0)" } ?? ""
      return "\(index + 1). \(result.title)\n\(result.url)\(snippet)"
    }.joined(separator: "\n\n")
  return "Search provider: \(provider.displayName)\nQuery: \(query)\n\n\(resultText)"
}

private func webFetchDisplayText(
  url: String,
  provider: WebFetchProvider?,
  finalURL: String,
  statusCode: Int,
  contentType: String?,
  content: ToolTextOutput,
  byteCount: Int
) -> String {
  let redirectText = url == finalURL ? "" : "\nFinal URL: \(finalURL)"
  return """
    URL: \(url)\(redirectText)
    Fetch provider: \(webFetchProviderDisplayName(provider))
    Status: \(statusCode)
    Content-Type: \(contentType ?? "unknown")
    Bytes: \(byteCount)

    \(content.text)
    """
}

private func webFetchProviderDisplayName(_ provider: WebFetchProvider?) -> String {
  provider?.displayName ?? "Unknown"
}

private func readRange(from request: ToolCallRequest) -> String? {
  switch request.payload {
  case .readFile(let input), .showFile(let input):
    let offset = input.offset ?? 1
    guard offset != 1 || input.limit != nil else {
      return nil
    }
    if let limit = input.limit {
      return "offset=\(offset),limit=\(limit)"
    }
    return "offset=\(offset)"
  default:
    return nil
  }
}

private func lineCount(_ text: String) -> Int {
  text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
}

nonisolated extension ToolFailure {
  var projectedText: String {
    message
  }
}

nonisolated extension ToolFailureReason {
  var projectedStatus: ToolResultStatus {
    switch self {
    case .permissionDenied, .pathOutsideWorkspace:
      .denied
    case .fileNotFound, .emptyPath, .unsupportedURLScheme, .finalModeToolAttempt,
      .toolBudgetExceeded, .unsupportedFileType, .invalidArguments, .executionError, .cancelled:
      .failed
    }
  }
}
