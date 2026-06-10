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
  public var events: [ToolCallEvent]
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
    events: [ToolCallEvent] = [],
    state: ToolCallState
  ) {
    self.request = request
    self.evaluation = evaluation
    self.events = events
    self.state = state
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

public struct ToolCallEvent: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var timestamp: Date
  public var actor: ToolCallActor
  public var kind: ToolCallEventKind
  public var message: String

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    actor: ToolCallActor,
    kind: ToolCallEventKind,
    message: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.actor = actor
    self.kind = kind
    self.message = message
  }
}

public enum ToolCallActor: String, Codable, Equatable, Sendable {
  case assistant
  case user
  case system
  case tool
}

public enum ToolCallEventKind: String, Codable, Equatable, Sendable {
  case requested
  case awaitingApproval
  case awaitingUserAnswer
  case answered
  case approved
  case denied
  case started
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
  case webSearch(WebSearchToolResult)
  case webFetch(WebFetchToolResult)
  case invalidTool(InvalidToolResult)
  case failure(ToolFailure)
}

public struct WebSearchInput: Codable, Equatable, Sendable {
  public var query: String
  public var maxResults: Int?

  public init(query: String, maxResults: Int? = nil) {
    self.query = query
    self.maxResults = maxResults
  }
}

public struct WebFetchInput: Codable, Equatable, Sendable {
  public var url: String
  public var maxBytes: Int?

  public init(url: String, maxBytes: Int? = nil) {
    self.url = url
    self.maxBytes = maxBytes
  }
}

public struct WebSearchResult: Codable, Equatable, Sendable {
  public var title: String
  public var url: String
  public var snippet: String?

  public init(title: String, url: String, snippet: String? = nil) {
    self.title = title
    self.url = url
    self.snippet = snippet
  }
}

public enum WebSearchToolResult: Codable, Equatable, Sendable {
  case success(
    query: String, provider: WebSearchProvider, results: [WebSearchResult], truncated: Bool)
  case failed(query: String, reason: ToolFailureReason)

  public init(
    query: String,
    provider: WebSearchProvider,
    results: [WebSearchResult],
    truncated: Bool = false
  ) {
    self = .success(query: query, provider: provider, results: results, truncated: truncated)
  }
}

public enum WebFetchToolResult: Codable, Equatable, Sendable {
  case success(
    url: String,
    finalURL: String,
    statusCode: Int,
    contentType: String?,
    content: ToolTextOutput,
    byteCount: Int
  )
  case failed(url: String, finalURL: String?, reason: ToolFailureReason)

  public init(
    url: String,
    finalURL: String,
    statusCode: Int,
    contentType: String?,
    content: ToolTextOutput,
    byteCount: Int
  ) {
    self = .success(
      url: url,
      finalURL: finalURL,
      statusCode: statusCode,
      contentType: contentType,
      content: content,
      byteCount: byteCount
    )
  }
}

public enum TodoWriteResult: Codable, Equatable, Sendable {
  case success
  case failed(reason: ToolFailureReason)
}

public struct AskUserInput: Codable, Equatable, Sendable {
  public let question: String
  public let options: [String]

  public init(question: String, options: [String]) {
    self.question = question
    self.options = options
  }
}

public struct AskUserResult: Codable, Equatable, Sendable {
  public let answer: String

  public init(answer: String) {
    self.answer = answer
  }
}

public enum ReadFileResult: Codable, Equatable, Sendable {
  case success(path: WorkspaceRelativePath, content: ToolTextOutput)
  case unchanged(path: WorkspaceRelativePath, readKey: ReadKey)
  case repeatedReadWarning(path: WorkspaceRelativePath, count: Int)
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)
}

public struct ListFilesResult: Codable, Equatable, Sendable {
  public var root: WorkspaceRelativePath
  public var entries: [WorkspaceFileEntry]
  public var truncated: Bool

  public init(
    root: WorkspaceRelativePath,
    entries: [WorkspaceFileEntry],
    truncated: Bool = false
  ) {
    self.root = root
    self.entries = entries
    self.truncated = truncated
  }
}

public struct GlobFilesResult: Codable, Equatable, Sendable {
  public var root: WorkspaceRelativePath
  public var pattern: String
  public var matches: [WorkspaceRelativePath]
  public var truncated: Bool

  public init(
    root: WorkspaceRelativePath,
    pattern: String,
    matches: [WorkspaceRelativePath],
    truncated: Bool = false
  ) {
    self.root = root
    self.pattern = pattern
    self.matches = matches
    self.truncated = truncated
  }
}

public struct SearchFilesResult: Codable, Equatable, Sendable {
  public var root: WorkspaceRelativePath
  public var pattern: String
  public var matches: [SearchFileMatch]
  public var truncated: Bool

  public init(
    root: WorkspaceRelativePath,
    pattern: String,
    matches: [SearchFileMatch],
    truncated: Bool = false
  ) {
    self.root = root
    self.pattern = pattern
    self.matches = matches
    self.truncated = truncated
  }
}

public enum WorkspaceDiffResult: Codable, Equatable, Sendable {
  case success(path: WorkspaceRelativePath?, content: ToolTextOutput)
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)
}

public struct WorkspaceDiagnosticsInput: Codable, Equatable, Sendable {
  public var outputRef: String

  public init(outputRef: String) {
    self.outputRef = outputRef
  }
}

public struct WorkspaceDiagnosticsResult: Codable, Equatable, Sendable {
  public var outputRef: String
  public var diagnostics: [WorkspaceDiagnostic]

  public init(outputRef: String, diagnostics: [WorkspaceDiagnostic]) {
    self.outputRef = outputRef
    self.diagnostics = diagnostics
  }
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

public enum WriteFileResult: Codable, Equatable, Sendable {
  case success(path: WorkspaceRelativePath, bytesWritten: Int)
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)
}

public enum EditFileResult: Codable, Equatable, Sendable {
  case success(path: WorkspaceRelativePath, diff: String?, matchStrategy: EditMatchStrategy)
  case oldTextNotFound(
    path: WorkspaceRelativePath,
    currentContent: ToolTextOutput?,
    recovery: RecoveryHint
  )
  case multipleMatches(path: WorkspaceRelativePath, matchCount: Int, recovery: RecoveryHint)
  case unchanged(path: WorkspaceRelativePath)
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)
}

public struct RunCommandResult: Codable, Equatable, Sendable {
  public var command: String
  public var timeoutSeconds: Int
  public var exitCode: Int32?
  public var durationMs: Int
  public var stdout: ToolTextOutput
  public var stderr: ToolTextOutput
  public var outputRef: String?
  public var stdoutOmittedChars: Int
  public var stderrOmittedChars: Int
  public var timedOut: Bool
  public var cancelled: Bool

  private enum CodingKeys: String, CodingKey {
    case command
    case timeoutSeconds
    case exitCode
    case durationMs
    case stdout
    case stderr
    case outputRef
    case stdoutOmittedChars
    case stderrOmittedChars
    case timedOut
    case cancelled
  }

  public init(
    command: String,
    timeoutSeconds: Int,
    exitCode: Int32?,
    durationMs: Int,
    stdout: ToolTextOutput,
    stderr: ToolTextOutput,
    outputRef: String? = nil,
    stdoutOmittedChars: Int = 0,
    stderrOmittedChars: Int = 0,
    timedOut: Bool = false,
    cancelled: Bool = false
  ) {
    self.command = command
    self.timeoutSeconds = timeoutSeconds
    self.exitCode = exitCode
    self.durationMs = durationMs
    self.stdout = stdout
    self.stderr = stderr
    self.outputRef = outputRef
    self.stdoutOmittedChars = stdoutOmittedChars
    self.stderrOmittedChars = stderrOmittedChars
    self.timedOut = timedOut
    self.cancelled = cancelled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    command = try container.decode(String.self, forKey: .command)
    timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
    exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
    durationMs = try container.decode(Int.self, forKey: .durationMs)
    stdout = try container.decode(ToolTextOutput.self, forKey: .stdout)
    stderr = try container.decode(ToolTextOutput.self, forKey: .stderr)
    outputRef = try container.decodeIfPresent(String.self, forKey: .outputRef)
    stdoutOmittedChars = try container.decodeIfPresent(Int.self, forKey: .stdoutOmittedChars) ?? 0
    stderrOmittedChars = try container.decodeIfPresent(Int.self, forKey: .stderrOmittedChars) ?? 0
    timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
    cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
  }

  public var outputTruncated: Bool {
    stdout.truncated || stderr.truncated
  }
}

public enum EditMatchStrategy: String, Codable, Equatable, Sendable {
  case exact
  case normalizedLineEndings
  case trimTrailingWhitespace
  case indentationFlexible
  case lineTrimmedBlock
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

  public init(
    status: ToolResultStatus = .success,
    text: String,
    truncated: Bool = false,
    redacted: Bool = false,
    affectedPaths: [String] = []
  ) {
    self.status = status
    self.text = text
    self.truncated = truncated
    self.redacted = redacted
    self.affectedPaths = affectedPaths
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
      return ToolResultPreview(
        text: result.entries.isEmpty
          ? "(empty)"
          : result.entries.map { entry in
            entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
          }.joined(separator: "\n"),
        truncated: result.truncated,
        affectedPaths: [result.root.rawValue]
      )
    case .globFiles(let result):
      return ToolResultPreview(
        text: result.matches.isEmpty
          ? "(no matches)"
          : result.matches.map(\.rawValue).joined(separator: "\n"),
        truncated: result.truncated,
        affectedPaths: [result.root.rawValue]
      )
    case .searchFiles(let result):
      return ToolResultPreview(
        text: result.matches.isEmpty
          ? "(no matches)"
          : result.matches.map { "\($0.path.rawValue):\($0.line): \($0.snippet)" }
            .joined(separator: "\n"),
        truncated: result.truncated,
        affectedPaths: [result.root.rawValue]
      )
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

nonisolated extension WebSearchToolResult {
  fileprivate var preview: ToolResultPreview {
    switch self {
    case .success(let query, let provider, let results, let truncated):
      let resultText =
        results.isEmpty
        ? "(no results)"
        : results.enumerated().map { index, result in
          let snippet = result.snippet.map { "\n\($0)" } ?? ""
          return "\(index + 1). \(result.title)\n\(result.url)\(snippet)"
        }.joined(separator: "\n\n")
      return ToolResultPreview(
        text: "Search provider: \(provider.displayName)\nQuery: \(query)\n\n\(resultText)",
        truncated: truncated
      )
    case .failed(_, let reason):
      return ToolResultPreview(status: reason.previewStatus, text: reason.message)
    }
  }
}

nonisolated extension WebFetchToolResult {
  fileprivate var preview: ToolResultPreview {
    switch self {
    case .success(
      let url, let finalURL, let statusCode, let contentType, let content, let byteCount):
      let redirectText = url == finalURL ? "" : "\nFinal URL: \(finalURL)"
      return ToolResultPreview(
        text: """
          URL: \(url)\(redirectText)
          Status: \(statusCode)
          Content-Type: \(contentType ?? "unknown")
          Bytes: \(byteCount)

          \(content.text)
          """,
        truncated: content.truncated,
        redacted: content.redacted
      )
    case .failed(let url, let finalURL, let reason):
      let finalURLText = finalURL.map { "\nFinal URL: \($0)" } ?? ""
      return ToolResultPreview(
        status: reason.previewStatus,
        text: "URL: \(url)\(finalURLText)\n\(reason.message)"
      )
    }
  }
}

nonisolated extension TodoWriteResult {
  fileprivate var preview: ToolResultPreview {
    switch self {
    case .success:
      ToolResultPreview(text: "Plan updated.")
    case .failed(let reason):
      ToolResultPreview(status: reason.previewStatus, text: reason.message)
    }
  }
}

nonisolated extension AskUserResult {
  fileprivate var preview: ToolResultPreview {
    ToolResultPreview(text: "User answered: \(answer)")
  }
}

nonisolated extension ReadFileResult {
  fileprivate var preview: ToolResultPreview {
    switch self {
    case .success(let path, let content):
      return ToolResultPreview(
        text: content.text,
        truncated: content.truncated,
        redacted: content.redacted,
        affectedPaths: [path.rawValue]
      )
    case .unchanged(let path, let readKey):
      let rangeText = readKey.range.map { " for \($0)" } ?? ""
      return ToolResultPreview(
        text:
          "File unchanged since previous read: \(path.rawValue)\(rangeText). Use the existing context instead of reading it again.",
        affectedPaths: [path.rawValue]
      )
    case .repeatedReadWarning(let path, let count):
      return ToolResultPreview(
        text:
          "Repeated read_file loop detected for \(path.rawValue) after \(count) reads. Stop reading this file again unless it changed or you need a different range.",
        affectedPaths: [path.rawValue]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus,
        text: reason.message,
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension WorkspaceDiffResult {
  fileprivate var preview: ToolResultPreview {
    switch self {
    case .success(let path, let content):
      return ToolResultPreview(
        text: content.text,
        truncated: content.truncated,
        redacted: content.redacted,
        affectedPaths: [path?.rawValue ?? "."]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus,
        text: reason.message,
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension WorkspaceDiagnosticsResult {
  fileprivate var preview: ToolResultPreview {
    guard !diagnostics.isEmpty else {
      return ToolResultPreview(text: "No diagnostics found for \(outputRef).")
    }

    let lines = diagnostics.map { diagnostic in
      let column = diagnostic.column.map { ":\($0)" } ?? ""
      return
        "\(diagnostic.path.rawValue):\(diagnostic.line)\(column): \(diagnostic.severity.rawValue): \(diagnostic.message)"
    }
    return ToolResultPreview(
      text: lines.joined(separator: "\n"),
      affectedPaths: diagnostics.map(\.path.rawValue)
    )
  }
}

nonisolated extension WriteFileResult {
  fileprivate var preview: ToolResultPreview {
    switch self {
    case .success(let path, let bytesWritten):
      return ToolResultPreview(
        text: "Wrote \(bytesWritten) bytes to \(path.rawValue).",
        affectedPaths: [path.rawValue]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus,
        text: reason.message,
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension EditFileResult {
  fileprivate var preview: ToolResultPreview {
    switch self {
    case .success(let path, let diff, let matchStrategy):
      let strategyText =
        matchStrategy == .exact ? "" : " using \(matchStrategy.rawValue) match strategy"
      return ToolResultPreview(
        text: diff ?? "Edited \(path.rawValue)\(strategyText).",
        affectedPaths: [path.rawValue]
      )
    case .oldTextNotFound(let path, let currentContent, let recovery):
      let contentText =
        currentContent.map { output in
          "\n\nCurrent file excerpt:\n\(output.text)"
        } ?? ""
      return ToolResultPreview(
        status: .failed,
        text:
          "edit_file failed: old_text was not found in \(path.rawValue).\(contentText)\n\n\(recovery.message)",
        truncated: currentContent?.truncated ?? false,
        redacted: currentContent?.redacted ?? false,
        affectedPaths: [path.rawValue]
      )
    case .multipleMatches(let path, let matchCount, let recovery):
      return ToolResultPreview(
        status: .failed,
        text:
          "edit_file failed: old_text matched more than once in \(path.rawValue) (\(matchCount) matches). \(recovery.message)",
        affectedPaths: [path.rawValue]
      )
    case .unchanged(let path):
      return ToolResultPreview(
        text: "No changes were needed for \(path.rawValue).",
        affectedPaths: [path.rawValue]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus,
        text: reason.message,
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension RunCommandResult {
  fileprivate var preview: ToolResultPreview {
    ToolResultPreview(
      text: previewText,
      truncated: outputTruncated,
      affectedPaths: ["."]
    )
  }

  public var previewText: String {
    var lines: [String] = [
      "Command: \(command)",
      "Exit code: \(exitCode.map(String.init) ?? "none")",
      "Duration: \(durationMs) ms",
      "Timed out: \(timedOut)",
      "Cancelled: \(cancelled)",
    ]
    if let outputRef {
      lines.append("Output ref: \(outputRef)")
    }
    if outputTruncated {
      lines.append("Output truncated: true")
    }
    if stdoutOmittedChars > 0 {
      lines.append("Stdout omitted chars: \(stdoutOmittedChars)")
    }
    if stderrOmittedChars > 0 {
      lines.append("Stderr omitted chars: \(stderrOmittedChars)")
    }
    if !stdout.text.isEmpty {
      lines.append("stdout:\n\(stdout.text)")
    }
    if !stderr.text.isEmpty {
      lines.append("stderr:\n\(stderr.text)")
    }
    if let outputRef {
      lines.append(
        "Hint: Run workspace_diagnostics(outputRef: \(outputRef)) for structured errors.")
    }
    return lines.joined(separator: "\n")
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
  fileprivate var previewStatus: ToolResultStatus {
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
    decision = try container.decode(ToolPermissionDecision.self, forKey: .decision)
    reason = try container.decode(String.self, forKey: .reason)
    riskLevel = try container.decode(ToolRiskLevel.self, forKey: .riskLevel)
    normalizedPaths = try container.decode([String].self, forKey: .normalizedPaths)
    workspaceRelativePaths =
      try container.decode([WorkspaceRelativePath].self, forKey: .workspaceRelativePaths)
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
