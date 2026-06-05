import Foundation

public struct ToolResultProjection: Equatable, Sendable {
  public let display: ToolDisplayPayload
  public let observation: ToolModelObservation
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

public struct ToolModelObservation: Equatable, Sendable {
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

public enum ToolObservationBlock: Equatable, Sendable {
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

  public init(
    maxListObservationEntries: Int = 40,
    maxSearchObservationSnippets: Int = 20,
    includeShowFileBodyInObservation: Bool = false,
    includeReadFileBodyInObservation: Bool = true
  ) {
    self.maxListObservationEntries = maxListObservationEntries
    self.maxSearchObservationSnippets = maxSearchObservationSnippets
    self.includeShowFileBodyInObservation = includeShowFileBodyInObservation
    self.includeReadFileBodyInObservation = includeReadFileBodyInObservation
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
      return ToolResultProjection(
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
    case .globFiles(let result):
      let entries = result.matches.map { WorkspaceFileEntry(path: $0, kind: .file) }
      return ToolResultProjection(
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
    case .searchFiles(let result):
      return ToolResultProjection(
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
    case .workspaceDiff(let result):
      return projectWorkspaceDiff(result, request: request)
    case .writeFile(let result):
      return projectWriteFile(result, request: request)
    case .editFile(let result):
      return projectEditFile(result, request: request)
    case .runCommand(let result):
      return projectRunCommand(result, request: request)
    case .todoWrite(let result):
      return projectTodoWrite(result, request: request)
    case .invalidTool(let result):
      let text = "The tool call was invalid: \(result.reason.message)"
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

  private static func projectReadFile(
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
      return ToolResultProjection(
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

  private static func projectWriteFile(
    _ result: WriteFileResult,
    request: ToolCallRequest
  ) -> ToolResultProjection {
    switch result {
    case .success(let path, let bytesWritten):
      return ToolResultProjection(
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

  private static func projectWorkspaceDiff(
    _ result: WorkspaceDiffResult,
    request: ToolCallRequest
  ) -> ToolResultProjection {
    switch result {
    case .success(let path, let content):
      let affectedPaths = [path ?? WorkspaceRelativePath(rawValue: ".")]
      return ToolResultProjection(
        display: .workspaceDiff(path: path, content: content),
        observation: ToolModelObservation.success(
          toolName: request.toolName,
          affectedPaths: affectedPaths,
          blocks: [.summary(content.text)]
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

  private static func projectEditFile(
    _ result: EditFileResult,
    request: ToolCallRequest
  ) -> ToolResultProjection {
    switch result {
    case .success(let path, let diff, let matchStrategy):
      return ToolResultProjection(
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
      let text =
        "edit_file failed: old_text was not found in \(path.rawValue). \(recovery.message)"
      let displayText =
        currentContent.map { "\(text)\n\nCurrent file excerpt:\n\($0.text)" } ?? text
      return ToolResultProjection(
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

  private static func projectRunCommand(
    _ result: RunCommandResult,
    request: ToolCallRequest
  ) -> ToolResultProjection {
    ToolResultProjection(
      display: .summary(
        status: .success,
        text: result.previewText,
        affectedPaths: [WorkspaceRelativePath(rawValue: ".")]
      ),
      observation: ToolModelObservation.success(
        toolName: request.toolName,
        affectedPaths: [WorkspaceRelativePath(rawValue: ".")],
        blocks: [.commandResult(result)]
      )
    )
  }

  private static func projectTodoWrite(
    _ result: TodoWriteResult,
    request: ToolCallRequest
  ) -> ToolResultProjection {
    switch result {
    case .success:
      return summaryProjection(
        toolName: request.toolName,
        status: .success,
        text: "Plan updated.",
        affectedPaths: []
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

  private static func summaryProjection(
    toolName: ToolName,
    status: ToolResultStatus,
    text: String,
    affectedPaths: [WorkspaceRelativePath]
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

    return ToolResultProjection(
      display: .summary(status: status, text: text, affectedPaths: affectedPaths),
      observation: observation
    )
  }

  private static func readRange(from request: ToolCallRequest) -> String? {
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

  private static func lineCount(_ text: String) -> Int {
    text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
  }
}

nonisolated extension ToolFailure {
  fileprivate var projectedText: String {
    message
  }
}

nonisolated extension ToolFailureReason {
  fileprivate var projectedStatus: ToolResultStatus {
    switch self {
    case .permissionDenied, .pathOutsideWorkspace:
      .denied
    case .fileNotFound, .emptyPath, .unsupportedURLScheme, .finalModeToolAttempt,
      .toolBudgetExceeded, .unsupportedFileType, .invalidArguments, .executionError, .cancelled:
      .failed
    }
  }
}
