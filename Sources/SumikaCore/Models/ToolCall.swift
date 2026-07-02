import Foundation

public typealias ToolCallArguments = [String: ToolArgumentValue]

public struct ToolName: Codable, Equatable, Hashable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let listFiles = ToolName(rawValue: "list_files")
  public static let globFiles = ToolName(rawValue: "glob_files")
  public static let readFile = ToolName(rawValue: "read_file")
  public static let showFile = ToolName(rawValue: "show_file")
  public static let searchFiles = ToolName(rawValue: "search_files")
  public static let workspaceDiff = ToolName(rawValue: "workspace_diff")
  public static let workspaceDiagnostics = ToolName(rawValue: "workspace_diagnostics")
  public static let editFile = ToolName(rawValue: "edit_file")
  public static let writeFile = ToolName(rawValue: "write_file")
  public static let runCommand = ToolName(rawValue: "run_command")
  public static let todoWrite = ToolName(rawValue: "todo_write")
  public static let askUser = ToolName(rawValue: "ask_user")
  public static let browserRefresh = ToolName(rawValue: "browser_refresh")
  public static let browserInspect = ToolName(rawValue: "browser_inspect")
  public static let webSearch = ToolName(rawValue: "web_search")
  public static let webFetch = ToolName(rawValue: "web_fetch")
  public static let invalid = ToolName(rawValue: "invalid")

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum ToolArgumentValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([ToolArgumentValue])
  case object([String: ToolArgumentValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([ToolArgumentValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: ToolArgumentValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}

public struct RawToolCallRequest: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let workspaceID: Workspace.ID
  public let sessionID: ChatSession.ID
  public var toolName: ToolName
  public var arguments: ToolCallArguments
  public var originalToolName: String?
  public var rawText: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID,
    toolName: ToolName,
    arguments: ToolCallArguments = [:],
    originalToolName: String? = nil,
    rawText: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.sessionID = sessionID
    self.toolName = toolName
    self.arguments = arguments
    self.originalToolName = originalToolName
    self.rawText = rawText
    self.createdAt = createdAt
  }
}

public struct ToolCallRequest: Codable, Identifiable, Equatable, Sendable {
  public var raw: RawToolCallRequest
  public var payload: ToolCallPayload

  public var id: UUID { raw.id }
  public var workspaceID: Workspace.ID { raw.workspaceID }
  public var sessionID: ChatSession.ID { raw.sessionID }
  public var toolName: ToolName { raw.toolName }
  public var createdAt: Date { raw.createdAt }
  public var rawArguments: ToolCallArguments { raw.arguments }

  private init(raw: RawToolCallRequest, payload: ToolCallPayload) {
    self.raw = raw
    self.payload = payload
  }

  public static func validated(
    raw: RawToolCallRequest,
    payload: ToolCallPayload
  ) -> ToolCallRequest {
    precondition(
      payload.matches(raw.toolName),
      "ToolCallRequest payload must match raw tool name."
    )
    return ToolCallRequest(raw: raw, payload: payload)
  }

  public static func invalid(
    raw: RawToolCallRequest,
    input: InvalidToolInput
  ) -> ToolCallRequest {
    ToolCallRequest(raw: raw, payload: .invalid(input))
  }
}

public enum ToolCallPayload: Codable, Equatable, Sendable {
  case readFile(ReadFileInput)
  case showFile(ReadFileInput)
  case listFiles(ListFilesInput)
  case globFiles(GlobFilesInput)
  case searchFiles(SearchFilesInput)
  case workspaceDiff(WorkspaceDiffInput)
  case workspaceDiagnostics(WorkspaceDiagnosticsInput)
  case writeFile(WriteFileInput)
  case editFile(EditFileInput)
  case runCommand(RunCommandInput)
  case todoWrite(TodoWriteInput)
  case askUser(AskUserInput)
  case browserRefresh(BrowserRefreshInput)
  case browserInspect(BrowserInspectInput)
  case webSearch(WebSearchInput)
  case webFetch(WebFetchInput)
  case invalid(InvalidToolInput)
}

nonisolated extension ToolCallPayload {
  public var toolName: ToolName {
    switch self {
    case .readFile:
      .readFile
    case .showFile:
      .showFile
    case .listFiles:
      .listFiles
    case .globFiles:
      .globFiles
    case .searchFiles:
      .searchFiles
    case .workspaceDiff:
      .workspaceDiff
    case .workspaceDiagnostics:
      .workspaceDiagnostics
    case .writeFile:
      .writeFile
    case .editFile:
      .editFile
    case .runCommand:
      .runCommand
    case .todoWrite:
      .todoWrite
    case .askUser:
      .askUser
    case .browserRefresh:
      .browserRefresh
    case .browserInspect:
      .browserInspect
    case .webSearch:
      .webSearch
    case .webFetch:
      .webFetch
    case .invalid:
      .invalid
    }
  }

  public func matches(_ toolName: ToolName) -> Bool {
    switch self {
    case .invalid:
      true
    default:
      self.toolName == toolName
    }
  }
}

public struct InvalidToolInput: Codable, Equatable, Sendable {
  public var originalName: String?
  public var rawArguments: ToolCallArguments
  public var reason: InvalidToolCallReason

  public init(
    originalName: String?,
    rawArguments: ToolCallArguments,
    reason: InvalidToolCallReason
  ) {
    self.originalName = originalName
    self.rawArguments = rawArguments
    self.reason = reason
  }
}

public enum InvalidToolCallReason: Error, Codable, Equatable, Sendable {
  case unknownToolName(String)
  case unavailableToolName(String)
  case unknownArguments([String])
  case missingRequiredArgument(String)
  case invalidArgumentType(name: String, expected: String)
  case emptyPath
  case invalidPagination(String)
  case invalidTimeout(String)
  case emptyOldText
  case invalidTodoItems(String)
  case parserError(String)
}

nonisolated extension InvalidToolCallReason {
  public var message: String {
    switch self {
    case .unknownToolName(let name):
      "Unknown tool: \(name)."
    case .unavailableToolName(let name):
      "Tool is not available in the active registry: \(name)."
    case .unknownArguments(let arguments):
      "Unknown argument(s): \(arguments.joined(separator: ", "))."
    case .missingRequiredArgument(let name):
      "Missing required argument: \(name)."
    case .invalidArgumentType(let name, let expected):
      "Invalid argument type for \(name). Expected \(expected)."
    case .emptyPath:
      "Tool path must not be empty."
    case .invalidPagination(let name):
      "\(name) must be greater than or equal to 1."
    case .invalidTimeout(let name):
      "\(name) must be an integer timeout in seconds."
    case .emptyOldText:
      "edit_file old_text must not be empty."
    case .invalidTodoItems(let message):
      "Invalid todo items: \(message)"
    case .parserError(let error):
      error
    }
  }
}

public struct ToolCallModelMessage: Codable, Equatable, Sendable {
  public var callID: UUID
  public var toolName: ToolName
  public var arguments: [ToolCallModelArgument]
  public var rawText: String?

  public init(
    callID: UUID,
    toolName: ToolName,
    arguments: [ToolCallModelArgument],
    rawText: String? = nil
  ) {
    self.callID = callID
    self.toolName = toolName
    self.arguments = arguments
    self.rawText = rawText
  }

  public init(rawRequest: RawToolCallRequest) {
    self.init(
      callID: rawRequest.id,
      toolName: rawRequest.toolName,
      arguments: rawRequest.arguments.keys.sorted().map { key in
        ToolCallModelArgument(name: key, value: rawRequest.arguments[key]?.displayValue ?? "")
      },
      rawText: rawRequest.rawText
    )
  }

  public init(request: ToolCallRequest) {
    self.init(
      rawRequest: request.raw
    )
  }
}

public struct ToolCallParseOutput: Equatable, Sendable {
  public var request: RawToolCallRequest
  public var modelMessage: ToolCallModelMessage

  public init(
    request: RawToolCallRequest,
    modelMessage: ToolCallModelMessage
  ) {
    self.request = request
    self.modelMessage = modelMessage
  }
}

nonisolated extension ToolCallModelMessage {
  public var modelContextContent: String {
    if isPayloadOmittedFromHistory {
      return terminalWriteModelContextContent
    }

    if let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return rawText
    }

    return NativeToolCallBoundaryRenderer.renderGemma4(
      toolName: toolName.rawValue,
      arguments: Dictionary(
        uniqueKeysWithValues: arguments.map { ($0.name, ToolArgumentValue.string($0.value)) }
      )
    )
  }

  public var modelContextRole: ModelContextRole {
    .assistant
  }

  private var isPayloadOmittedFromHistory: Bool {
    toolName == .writeFile || toolName == .editFile || toolName == .todoWrite
  }

  private var terminalWriteModelContextContent: String {
    if toolName == .todoWrite {
      return """
        Tool call todo_write requested.
        Payload omitted from history.
        """
    }

    let path = arguments.first { $0.name == "path" }?.value ?? "unknown"
    return """
      Tool call \(toolName.rawValue) requested.
      Path:
      \(path)
      Payload omitted from history.
      """
  }
}

public struct ToolCallModelArgument: Codable, Identifiable, Equatable, Sendable {
  public var id: String { name }

  public var name: String
  public var value: String
}

nonisolated extension ToolCallModelMessage {
  public var transcriptArguments: [ToolCallModelArgument] {
    switch toolName {
    case .writeFile:
      return arguments.filter {
        !Self.hiddenTranscriptArgumentNames(for: toolName).contains($0.name)
      }
    case .editFile:
      return arguments.filter {
        !Self.hiddenTranscriptArgumentNames(for: toolName).contains($0.name)
      }
    case .runCommand:
      return arguments.filter {
        !Self.hiddenTranscriptArgumentNames(for: toolName).contains($0.name)
      }
    case .todoWrite:
      return []
    default:
      return arguments
    }
  }

  private static func hiddenTranscriptArgumentNames(for toolName: ToolName) -> Set<String> {
    switch toolName {
    case .writeFile:
      ["content"]
    case .editFile:
      ["old_text", "new_text"]
    case .runCommand:
      ["cwd", "working_directory", "workingDirectory"]
    default:
      []
    }
  }
}

nonisolated extension ToolArgumentValue {
  public var displayValue: String {
    switch self {
    case .string(let value):
      value
    case .number(let value):
      value.formatted()
    case .bool(let value):
      value ? "true" : "false"
    case .array(let values):
      values.map(\.displayValue).joined(separator: ", ")
    case .object:
      "{...}"
    case .null:
      "null"
    }
  }
}

public struct ToolCallRecord: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID { request.id }

  public var request: ToolCallRequest
  public var evaluation: ToolPermissionEvaluation
  public var state: ToolCallState

  public var status: ToolCallStatus {
    state.status
  }

  public var resultPayload: ToolResultPayload? {
    state.resultPayload
  }

  public var approvalPreview: ToolResultPreview? {
    state.approvalPreview
  }

  public var resultPreview: ToolResultPreview? {
    state.preview
  }

  public init(
    request: ToolCallRequest,
    evaluation: ToolPermissionEvaluation,
    state: ToolCallState
  ) {
    self.request = request
    self.evaluation = evaluation
    self.state = state
  }

  private enum CodingKeys: String, CodingKey {
    case request
    case evaluation
    case state
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    request = try container.decode(ToolCallRequest.self, forKey: .request)
    evaluation = try container.decodeIfPresent(
      ToolPermissionEvaluation.self,
      forKey: .evaluation,
      default: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Loaded from a record without stored permission metadata.",
        riskLevel: .low
      )
    )
    state = try container.decodeIfPresent(ToolCallState.self, forKey: .state, default: .pending)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(request, forKey: .request)
    try container.encode(evaluation, forKey: .evaluation)
    try container.encode(state, forKey: .state)
  }
}

public enum ToolCallState: Codable, Equatable, Sendable {
  case pending
  case awaitingApproval(preview: ToolResultPreview?)
  case awaitingUserAnswer
  case running
  case completed(ToolResultPayload)
  case denied(ToolResultPayload)
  case failed(ToolResultPayload)
  case cancelled
}

nonisolated extension ToolCallState {
  public var status: ToolCallStatus {
    switch self {
    case .pending:
      .pending
    case .awaitingApproval:
      .awaitingApproval
    case .awaitingUserAnswer:
      .awaitingUserAnswer
    case .running:
      .running
    case .completed:
      .completed
    case .denied:
      .denied
    case .failed:
      .failed
    case .cancelled:
      .cancelled
    }
  }

  public var resultPayload: ToolResultPayload? {
    switch self {
    case .completed(let payload), .denied(let payload), .failed(let payload):
      payload
    case .pending, .awaitingApproval, .awaitingUserAnswer, .running, .cancelled:
      nil
    }
  }

  public var approvalPreview: ToolResultPreview? {
    switch self {
    case .awaitingApproval(let preview):
      preview
    case .pending, .awaitingUserAnswer, .running, .completed, .denied, .failed, .cancelled:
      nil
    }
  }

  public var preview: ToolResultPreview? {
    resultPayload?.preview ?? approvalPreview
  }
}

public enum ToolCallStatus: String, Codable, Equatable, Sendable {
  case pending
  case awaitingApproval
  case awaitingUserAnswer
  case denied
  case running
  case completed
  case failed
  case cancelled
}

public struct WorkspaceRelativePath: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum ToolResultPayload: Codable, Equatable, Sendable {
  case readFile(ReadFileResult)
  case listFiles(ListFilesResult)
  case globFiles(GlobFilesResult)
  case searchFiles(SearchFilesResult)
  case workspaceDiff(WorkspaceDiffResult)
  case workspaceDiagnostics(WorkspaceDiagnosticsResult)
  case writeFile(WriteFileResult)
  case editFile(EditFileResult)
  case runCommand(RunCommandResult)
  case todoWrite(TodoWriteResult)
  case askUser(AskUserResult)
  case browserRefresh(BrowserRefreshResult)
  case browserInspect(BrowserInspectResult)
  case webSearch(WebSearchToolResult)
  case webFetch(WebFetchToolResult)
  case invalidTool(InvalidToolResult)
  case failure(ToolFailure)
}

public struct WorkspaceDiagnostic: Codable, Equatable, Sendable {
  public var path: WorkspaceRelativePath
  public var line: Int
  public var column: Int?
  public var severity: WorkspaceDiagnosticSeverity
  public var message: String
  public var source: WorkspaceDiagnosticSource

  public init(
    path: WorkspaceRelativePath,
    line: Int,
    column: Int?,
    severity: WorkspaceDiagnosticSeverity,
    message: String,
    source: WorkspaceDiagnosticSource = .lastCommandOutput
  ) {
    self.path = path
    self.line = line
    self.column = column
    self.severity = severity
    self.message = message
    self.source = source
  }
}

public enum WorkspaceDiagnosticSeverity: String, Codable, Equatable, Sendable {
  case error
  case warning
  case note
}

public enum WorkspaceDiagnosticSource: String, Codable, Equatable, Sendable {
  case lastCommandOutput
}

public struct InvalidToolResult: Codable, Equatable, Sendable {
  public var originalName: String?
  public var reason: InvalidToolCallReason

  public init(originalName: String?, reason: InvalidToolCallReason) {
    self.originalName = originalName
    self.reason = reason
  }
}

public struct ToolFailure: Codable, Equatable, Sendable {
  public var toolName: ToolName
  public var path: WorkspaceRelativePath?
  public var reason: ToolFailureReason
  public var recovery: RecoveryHint?

  public init(
    toolName: ToolName,
    path: WorkspaceRelativePath?,
    reason: ToolFailureReason,
    recovery: RecoveryHint? = nil
  ) {
    self.toolName = toolName
    self.path = path
    self.reason = reason
    self.recovery = recovery
  }
}

public enum ToolFailureReason: Codable, Equatable, Sendable {
  case fileNotFound(path: WorkspaceRelativePath?, suggestions: [MissingPathSuggestion])
  case pathOutsideWorkspace
  case emptyPath
  case unsupportedURLScheme(String)
  case permissionDenied
  case finalModeToolAttempt(requestedTool: ToolName?)
  case toolBudgetExceeded(requestedTool: ToolName?, iterationLimit: Int)
  case unsupportedFileType(String)
  case invalidArguments(InvalidToolCallReason)
  case executionError(String)
  case cancelled
}

public enum RecoveryHint: Codable, Equatable, Sendable {
  case readFile(path: WorkspaceRelativePath)
  case retryWithMoreContext(path: WorkspaceRelativePath)
  case chooseOneOf(paths: [WorkspaceRelativePath])
  case askUser(message: String)
  case stop
}

public struct MissingPathSuggestion: Codable, Equatable, Sendable {
  public var path: WorkspaceRelativePath
  public var reason: String
  public var confidence: Double

  public init(path: WorkspaceRelativePath, reason: String, confidence: Double) {
    self.path = path
    self.reason = reason
    self.confidence = confidence
  }
}

public struct ToolTextOutput: Codable, Equatable, Sendable {
  public var text: String
  public var truncated: Bool
  public var redacted: Bool

  public init(text: String, truncated: Bool = false, redacted: Bool = false) {
    self.text = text
    self.truncated = truncated
    self.redacted = redacted
  }
}

public struct ReadKey: Codable, Equatable, Hashable, Sendable {
  public var path: WorkspaceRelativePath
  public var range: String?

  public init(path: WorkspaceRelativePath, range: String? = nil) {
    self.path = path
    self.range = range
  }
}

public struct WorkspaceFileEntry: Codable, Equatable, Sendable {
  public var path: WorkspaceRelativePath
  public var kind: WorkspaceFileKind

  public init(path: WorkspaceRelativePath, kind: WorkspaceFileKind) {
    self.path = path
    self.kind = kind
  }
}

public enum WorkspaceFileKind: String, Codable, Equatable, Sendable {
  case file
  case directory
}

public struct SearchFileMatch: Codable, Equatable, Sendable {
  public var path: WorkspaceRelativePath
  public var line: Int
  public var snippet: String

  public init(path: WorkspaceRelativePath, line: Int, snippet: String) {
    self.path = path
    self.line = line
    self.snippet = snippet
  }
}

public struct ToolResultPreview: Codable, Equatable, Sendable {
  public var status: ToolResultStatus
  public var text: String
  public var truncated: Bool
  public var redacted: Bool
  public var affectedPaths: [String]
  public var resultPayload: ToolResultPayload?

  public init(
    status: ToolResultStatus = .success,
    text: String,
    truncated: Bool = false,
    redacted: Bool = false,
    affectedPaths: [String] = [],
    resultPayload: ToolResultPayload? = nil
  ) {
    self.status = status
    self.text = text
    self.truncated = truncated
    self.redacted = redacted
    self.affectedPaths = affectedPaths
    self.resultPayload = resultPayload
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case text
    case truncated
    case redacted
    case affectedPaths
    case resultPayload
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decodeIfPresent(
      ToolResultStatus.self, forKey: .status, default: .success)
    text = try container.decodeIfPresent(String.self, forKey: .text, default: "")
    truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated, default: false)
    redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted, default: false)
    affectedPaths = try container.decodeIfPresent(
      [String].self, forKey: .affectedPaths, default: [])
    resultPayload = try container.decodeIfPresent(ToolResultPayload.self, forKey: .resultPayload)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(text, forKey: .text)
    try container.encode(truncated, forKey: .truncated)
    try container.encode(redacted, forKey: .redacted)
    try container.encode(affectedPaths, forKey: .affectedPaths)
    try container.encodeIfPresent(resultPayload, forKey: .resultPayload)
  }
}

public enum ToolResultStatus: String, Codable, Equatable, Sendable {
  case success
  case failed
  case denied
}

nonisolated extension ToolResultPayload {
  public var status: ToolResultStatus {
    preview.status
  }

  public var text: String {
    preview.text
  }

  public var truncated: Bool {
    preview.truncated
  }

  public var redacted: Bool {
    preview.redacted
  }

  public var affectedPaths: [String] {
    preview.affectedPaths
  }

  public var preview: ToolResultPreview {
    switch self {
    case .readFile(let result):
      return result.preview
    case .listFiles(let result):
      return result.preview
    case .globFiles(let result):
      return result.preview
    case .searchFiles(let result):
      return result.preview
    case .workspaceDiff(let result):
      return result.preview
    case .workspaceDiagnostics(let result):
      return result.preview
    case .writeFile(let result):
      return result.preview
    case .editFile(let result):
      return result.preview
    case .runCommand(let result):
      return result.preview
    case .todoWrite(let result):
      return result.preview
    case .askUser(let result):
      return result.preview
    case .browserRefresh(let result):
      return result.preview
    case .browserInspect(let result):
      return result.preview
    case .webSearch(let result):
      return result.preview
    case .webFetch(let result):
      return result.preview
    case .invalidTool(let result):
      return ToolResultPreview(
        status: .failed,
        text: "The tool call was invalid: \(result.reason.message)"
      )
    case .failure(let failure):
      return ToolResultPreview(
        status: failure.reason.previewStatus,
        text: failure.previewText,
        affectedPaths: failure.path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension ToolFailure {
  public var message: String {
    let prefix = "\(toolName.rawValue) failed"
    let text: String
    guard let path else {
      text = "\(prefix): \(reason.message)"
      return text.appendingRecovery(recovery)
    }
    text = "\(prefix) for \(path.rawValue): \(reason.message)"
    return text.appendingRecovery(recovery)
  }

  fileprivate var previewText: String {
    message
  }
}

nonisolated extension String {
  fileprivate func appendingRecovery(_ recovery: RecoveryHint?) -> String {
    guard let recovery else {
      return self
    }
    let recoveryMessage = recovery.message
    guard !recoveryMessage.isEmpty else {
      return self
    }
    return "\(self) \(recoveryMessage)"
  }
}

nonisolated extension ToolFailureReason {
  var previewStatus: ToolResultStatus {
    switch self {
    case .permissionDenied, .pathOutsideWorkspace:
      .denied
    case .fileNotFound, .emptyPath, .unsupportedURLScheme, .finalModeToolAttempt,
      .toolBudgetExceeded, .unsupportedFileType,
      .invalidArguments, .executionError, .cancelled:
      .failed
    }
  }

  public var message: String {
    switch self {
    case .fileNotFound(let path, let suggestions):
      var text = "File not found"
      if let path {
        text += ": \(path.rawValue)"
      }
      guard !suggestions.isEmpty else {
        return text + "."
      }
      let suggestionText = suggestions.map { "- \($0.path.rawValue) (\($0.reason))" }
        .joined(separator: "\n")
      return "\(text).\n\nDid you mean one of these?\n\(suggestionText)"
    case .pathOutsideWorkspace:
      return "Path is outside the workspace."
    case .emptyPath:
      return "Path is empty."
    case .unsupportedURLScheme(let scheme):
      return "Unsupported URL scheme: \(scheme)."
    case .permissionDenied:
      return "Permission denied."
    case .finalModeToolAttempt(let requestedTool):
      let toolText = requestedTool.map { " for \($0.rawValue)" } ?? ""
      return
        "Tool attempt ignored\(toolText). This response is final for the current turn, so no further tools may run until the user sends another message."
    case .toolBudgetExceeded(let requestedTool, let iterationLimit):
      let toolText = requestedTool.map { " for \($0.rawValue)" } ?? ""
      return
        "Tool budget exceeded\(toolText). The limit for this request is \(iterationLimit) tool iterations. No further tools may run until the user sends another message."
    case .unsupportedFileType(let fileType):
      return "Unsupported file type: \(fileType)."
    case .invalidArguments(let reason):
      return reason.message
    case .executionError(let message):
      return message
    case .cancelled:
      return "Tool execution was cancelled."
    }
  }
}

nonisolated extension RecoveryHint {
  public var message: String {
    switch self {
    case .readFile(let path):
      return
        "Read \(path.rawValue), then retry using exact text from the current content as old_text."
    case .retryWithMoreContext(let path):
      return "Retry with a larger exact old_text block from \(path.rawValue)."
    case .chooseOneOf(let paths):
      return
        "Choose one of these paths before retrying: \(paths.map(\.rawValue).joined(separator: ", "))."
    case .askUser(let message):
      return message
    case .stop:
      return "Stop and ask the user before trying another tool call."
    }
  }
}

public struct ToolResultModelMessage: Codable, Equatable, Sendable {
  public var callID: UUID
  public var toolName: ToolName
  public var payload: ToolResultPayload

  public init(
    callID: UUID,
    toolName: ToolName,
    payload: ToolResultPayload
  ) {
    self.callID = callID
    self.toolName = toolName
    self.payload = payload
  }

  public init(record: ToolCallRecord) {
    self.init(
      callID: record.id,
      toolName: record.request.toolName,
      payload: record.resultPayload
        ?? .failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: nil,
            reason: .executionError(
              "Tool result unavailable for \(record.request.toolName.rawValue)."
            )
          ))
    )
  }
}

nonisolated extension ToolResultModelMessage {
  public var preview: ToolResultPreview {
    payload.preview
  }
}

public struct ToolPermissionEvaluation: Codable, Equatable, Sendable {
  public var decision: ToolPermissionDecision
  public var reason: String
  public var riskLevel: ToolRiskLevel
  public var normalizedPaths: [String]
  public var workspaceRelativePaths: [WorkspaceRelativePath]

  public init(
    decision: ToolPermissionDecision,
    reason: String,
    riskLevel: ToolRiskLevel,
    normalizedPaths: [String] = [],
    workspaceRelativePaths: [WorkspaceRelativePath] = []
  ) {
    self.decision = decision
    self.reason = reason
    self.riskLevel = riskLevel
    self.normalizedPaths = normalizedPaths
    self.workspaceRelativePaths = workspaceRelativePaths
  }

  private enum CodingKeys: String, CodingKey {
    case decision
    case reason
    case riskLevel
    case normalizedPaths
    case workspaceRelativePaths
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    decision = try container.decodeIfPresent(
      ToolPermissionDecision.self,
      forKey: .decision,
      default: .allowed
    )
    reason = try container.decodeIfPresent(String.self, forKey: .reason, default: "")
    riskLevel = try container.decodeIfPresent(ToolRiskLevel.self, forKey: .riskLevel, default: .low)
    normalizedPaths = try container.decodeIfPresent(
      [String].self, forKey: .normalizedPaths, default: [])
    workspaceRelativePaths = try container.decodeIfPresent(
      [WorkspaceRelativePath].self,
      forKey: .workspaceRelativePaths,
      default: []
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(decision, forKey: .decision)
    try container.encode(reason, forKey: .reason)
    try container.encode(riskLevel, forKey: .riskLevel)
    try container.encode(normalizedPaths, forKey: .normalizedPaths)
    try container.encode(workspaceRelativePaths, forKey: .workspaceRelativePaths)
  }

  public var modelFacingPaths: [String] {
    let relativePaths = workspaceRelativePaths.map(\.rawValue)
    return relativePaths.isEmpty ? normalizedPaths : relativePaths
  }

  public var firstModelFacingPath: WorkspaceRelativePath? {
    workspaceRelativePaths.first ?? normalizedPaths.first.map(WorkspaceRelativePath.init(rawValue:))
  }
}

public enum ToolPermissionDecision: String, Codable, Equatable, Sendable {
  case allowed
  case requiresApproval
  case denied
}

public enum ToolRiskLevel: String, Codable, Equatable, Sendable {
  case low
  case medium
  case high
}
