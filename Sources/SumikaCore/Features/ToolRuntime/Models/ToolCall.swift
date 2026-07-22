import Foundation

package typealias ToolCallArguments = [String: ToolArgumentValue]

package struct ToolName: Codable, Equatable, Hashable, Sendable, RawRepresentable {
  package let rawValue: String

  package init(rawValue: String) {
    self.rawValue = rawValue
  }

  package static let listFiles = ToolName(rawValue: "list_files")
  package static let globFiles = ToolName(rawValue: "glob_files")
  package static let readFile = ToolName(rawValue: "read_file")
  package static let showFile = ToolName(rawValue: "show_file")
  package static let searchFiles = ToolName(rawValue: "search_files")
  package static let workspaceDiff = ToolName(rawValue: "workspace_diff")
  package static let workspaceDiagnostics = ToolName(rawValue: "workspace_diagnostics")
  package static let editFile = ToolName(rawValue: "edit_file")
  package static let writeFile = ToolName(rawValue: "write_file")
  package static let runCommand = ToolName(rawValue: "run_command")
  package static let todoWrite = ToolName(rawValue: "todo_write")
  package static let askUser = ToolName(rawValue: "ask_user")
  package static let finishTask = ToolName(rawValue: "finish_task")
  package static let browserRefresh = ToolName(rawValue: "browser_refresh")
  package static let browserInspect = ToolName(rawValue: "browser_inspect")
  package static let webSearch = ToolName(rawValue: "web_search")
  package static let webFetch = ToolName(rawValue: "web_fetch")
  package static let invalid = ToolName(rawValue: "invalid")

  package init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

package enum ToolArgumentValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([ToolArgumentValue])
  case object([String: ToolArgumentValue])
  case null

  package init(from decoder: Decoder) throws {
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

  package func encode(to encoder: Encoder) throws {
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

package struct RawToolCallRequest: Codable, Identifiable, Equatable, Sendable {
  package let id: UUID
  package let workspaceID: Workspace.ID
  package let sessionID: ChatSession.ID
  package var toolName: ToolName
  package var arguments: ToolCallArguments
  package var originalToolName: String?
  package var createdAt: Date

  package init(
    id: UUID = UUID(),
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID,
    toolName: ToolName,
    arguments: ToolCallArguments = [:],
    originalToolName: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.sessionID = sessionID
    self.toolName = toolName
    self.arguments = arguments
    self.originalToolName = originalToolName
    self.createdAt = createdAt
  }
}

package enum RuntimeToolCallID {
  package static let prefix = "call_"

  package static func string(for uuid: UUID) -> String {
    prefix + uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  package static func uuid(from id: String?) -> UUID? {
    guard let id, id.hasPrefix(prefix) else {
      return nil
    }

    let hex = String(id.dropFirst(prefix.count))
    guard hex.count == 32, hex.unicodeScalars.allSatisfy(isHexDigit(_:)) else {
      return nil
    }

    let lowercased = hex.lowercased()
    let parts = [
      lowercased.prefix(8),
      lowercased.dropFirst(8).prefix(4),
      lowercased.dropFirst(12).prefix(4),
      lowercased.dropFirst(16).prefix(4),
      lowercased.dropFirst(20).prefix(12),
    ]
    return UUID(uuidString: parts.map(String.init).joined(separator: "-"))
  }

  package static func uniqueUUID(from id: String?, usedIDs: inout Set<UUID>) -> UUID {
    if let parsedID = uuid(from: id), !usedIDs.contains(parsedID) {
      usedIDs.insert(parsedID)
      return parsedID
    }

    var generatedID = UUID()
    while usedIDs.contains(generatedID) {
      generatedID = UUID()
    }
    usedIDs.insert(generatedID)
    return generatedID
  }

  package static func normalizedString(from id: String?, usedIDs: inout Set<UUID>) -> String {
    string(for: uniqueUUID(from: id, usedIDs: &usedIDs))
  }

  private static func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...70, 97...102:
      return true
    default:
      return false
    }
  }
}

package struct ToolCallRequest: Codable, Identifiable, Equatable, Sendable {
  package var raw: RawToolCallRequest
  package var payload: ToolCallPayload

  package var id: UUID { raw.id }
  package var workspaceID: Workspace.ID { raw.workspaceID }
  package var sessionID: ChatSession.ID { raw.sessionID }
  package var toolName: ToolName { raw.toolName }
  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var createdAt: Date { raw.createdAt }
  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var rawArguments: ToolCallArguments { raw.arguments }

  private init(raw: RawToolCallRequest, payload: ToolCallPayload) {
    self.raw = raw
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case raw
    case payload
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decode(RawToolCallRequest.self, forKey: .raw)
    let payload = try container.decode(ToolCallPayload.self, forKey: .payload)
    // The memberwise path guards this invariant with a precondition; decoded
    // data must fail recoverably instead of crashing the app.
    guard payload.matches(raw.toolName) else {
      throw DecodingError.dataCorruptedError(
        forKey: .payload,
        in: container,
        debugDescription:
          "Tool call payload \(payload.toolName.rawValue) does not match raw tool name \(raw.toolName.rawValue)."
      )
    }
    self.raw = raw
    self.payload = payload
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(raw, forKey: .raw)
    try container.encode(payload, forKey: .payload)
  }

  package static func validated(
    raw: RawToolCallRequest,
    payload: ToolCallPayload
  ) -> ToolCallRequest {
    precondition(
      payload.matches(raw.toolName),
      "ToolCallRequest payload must match raw tool name."
    )
    return ToolCallRequest(raw: raw, payload: payload)
  }

  package static func invalid(
    raw: RawToolCallRequest,
    input: InvalidToolInput
  ) -> ToolCallRequest {
    ToolCallRequest(raw: raw, payload: .invalid(input))
  }
}

package enum ToolCallPayload: Codable, Equatable, Sendable {
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
  case finishTask(FinishTaskInput)
  case browserRefresh(BrowserRefreshInput)
  case browserInspect(BrowserInspectInput)
  case webSearch(WebSearchInput)
  case webFetch(WebFetchInput)
  case mcp(MCPToolInput)
  case invalid(InvalidToolInput)

  private enum CodingKeys: String, CodingKey {
    case kind
    case payload
  }

  private enum Kind: String, Codable {
    case readFile
    case showFile
    case listFiles
    case globFiles
    case searchFiles
    case workspaceDiff
    case workspaceDiagnostics
    case writeFile
    case editFile
    case runCommand
    case todoWrite
    case askUser
    case finishTask
    case browserRefresh
    case browserInspect
    case webSearch
    case webFetch
    case mcp
    case invalid
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .readFile:
      self = .readFile(try container.decode(ReadFileInput.self, forKey: .payload))
    case .showFile:
      self = .showFile(try container.decode(ReadFileInput.self, forKey: .payload))
    case .listFiles:
      self = .listFiles(try container.decode(ListFilesInput.self, forKey: .payload))
    case .globFiles:
      self = .globFiles(try container.decode(GlobFilesInput.self, forKey: .payload))
    case .searchFiles:
      self = .searchFiles(try container.decode(SearchFilesInput.self, forKey: .payload))
    case .workspaceDiff:
      self = .workspaceDiff(try container.decode(WorkspaceDiffInput.self, forKey: .payload))
    case .workspaceDiagnostics:
      self = .workspaceDiagnostics(
        try container.decode(WorkspaceDiagnosticsInput.self, forKey: .payload)
      )
    case .writeFile:
      self = .writeFile(try container.decode(WriteFileInput.self, forKey: .payload))
    case .editFile:
      self = .editFile(try container.decode(EditFileInput.self, forKey: .payload))
    case .runCommand:
      self = .runCommand(try container.decode(RunCommandInput.self, forKey: .payload))
    case .todoWrite:
      self = .todoWrite(try container.decode(TodoWriteInput.self, forKey: .payload))
    case .askUser:
      self = .askUser(try container.decode(AskUserInput.self, forKey: .payload))
    case .finishTask:
      self = .finishTask(try container.decode(FinishTaskInput.self, forKey: .payload))
    case .browserRefresh:
      self = .browserRefresh(try container.decode(BrowserRefreshInput.self, forKey: .payload))
    case .browserInspect:
      self = .browserInspect(try container.decode(BrowserInspectInput.self, forKey: .payload))
    case .webSearch:
      self = .webSearch(try container.decode(WebSearchInput.self, forKey: .payload))
    case .webFetch:
      self = .webFetch(try container.decode(WebFetchInput.self, forKey: .payload))
    case .mcp:
      self = .mcp(try container.decode(MCPToolInput.self, forKey: .payload))
    case .invalid:
      self = .invalid(try container.decode(InvalidToolInput.self, forKey: .payload))
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .readFile(let input):
      try container.encode(input, forKey: .payload)
    case .showFile(let input):
      try container.encode(input, forKey: .payload)
    case .listFiles(let input):
      try container.encode(input, forKey: .payload)
    case .globFiles(let input):
      try container.encode(input, forKey: .payload)
    case .searchFiles(let input):
      try container.encode(input, forKey: .payload)
    case .workspaceDiff(let input):
      try container.encode(input, forKey: .payload)
    case .workspaceDiagnostics(let input):
      try container.encode(input, forKey: .payload)
    case .writeFile(let input):
      try container.encode(input, forKey: .payload)
    case .editFile(let input):
      try container.encode(input, forKey: .payload)
    case .runCommand(let input):
      try container.encode(input, forKey: .payload)
    case .todoWrite(let input):
      try container.encode(input, forKey: .payload)
    case .askUser(let input):
      try container.encode(input, forKey: .payload)
    case .finishTask(let input):
      try container.encode(input, forKey: .payload)
    case .browserRefresh(let input):
      try container.encode(input, forKey: .payload)
    case .browserInspect(let input):
      try container.encode(input, forKey: .payload)
    case .webSearch(let input):
      try container.encode(input, forKey: .payload)
    case .webFetch(let input):
      try container.encode(input, forKey: .payload)
    case .mcp(let input):
      try container.encode(input, forKey: .payload)
    case .invalid(let input):
      try container.encode(input, forKey: .payload)
    }
  }

  private var kind: Kind {
    switch self {
    case .readFile: .readFile
    case .showFile: .showFile
    case .listFiles: .listFiles
    case .globFiles: .globFiles
    case .searchFiles: .searchFiles
    case .workspaceDiff: .workspaceDiff
    case .workspaceDiagnostics: .workspaceDiagnostics
    case .writeFile: .writeFile
    case .editFile: .editFile
    case .runCommand: .runCommand
    case .todoWrite: .todoWrite
    case .askUser: .askUser
    case .finishTask: .finishTask
    case .browserRefresh: .browserRefresh
    case .browserInspect: .browserInspect
    case .webSearch: .webSearch
    case .webFetch: .webFetch
    case .mcp: .mcp
    case .invalid: .invalid
    }
  }
}

nonisolated extension ToolCallPayload {
  package var toolName: ToolName {
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
    case .finishTask:
      .finishTask
    case .browserRefresh:
      .browserRefresh
    case .browserInspect:
      .browserInspect
    case .webSearch:
      .webSearch
    case .webFetch:
      .webFetch
    case .mcp(let input):
      input.qualifiedName
    case .invalid:
      .invalid
    }
  }

  package func matches(_ toolName: ToolName) -> Bool {
    switch self {
    case .invalid:
      true
    default:
      self.toolName == toolName
    }
  }
}

package struct InvalidToolInput: Codable, Equatable, Sendable {
  package var originalName: String?
  package var rawArguments: ToolCallArguments
  package var reason: InvalidToolCallReason

  package init(
    originalName: String?,
    rawArguments: ToolCallArguments,
    reason: InvalidToolCallReason
  ) {
    self.originalName = originalName
    self.rawArguments = rawArguments
    self.reason = reason
  }
}

package enum InvalidToolCallReason: Error, Codable, Equatable, Sendable {
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
  package var message: String {
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

package struct ToolCallModelMessage: Codable, Equatable, Sendable {
  package var callID: UUID
  package var toolName: ToolName
  package var arguments: [ToolCallModelArgument]
  package var rawArguments: ToolCallArguments

  package init(
    callID: UUID,
    toolName: ToolName,
    arguments: [ToolCallModelArgument],
    rawArguments: ToolCallArguments? = nil
  ) {
    self.callID = callID
    self.toolName = toolName
    self.arguments = arguments
    self.rawArguments =
      rawArguments
      ?? Dictionary(
        uniqueKeysWithValues: arguments.map { ($0.name, ToolArgumentValue.string($0.value)) }
      )
  }

  package init(rawRequest: RawToolCallRequest) {
    self.init(
      callID: rawRequest.id,
      toolName: rawRequest.toolName,
      arguments: rawRequest.arguments.keys.sorted().map { key in
        ToolCallModelArgument(name: key, value: rawRequest.arguments[key]?.displayValue ?? "")
      },
      rawArguments: rawRequest.arguments
    )
  }

  package init(request: ToolCallRequest) {
    self.init(
      rawRequest: request.raw
    )
  }
}

package struct ToolCallParseOutput: Equatable, Sendable {
  package var request: RawToolCallRequest
  package var modelMessage: ToolCallModelMessage

  package init(
    request: RawToolCallRequest,
    modelMessage: ToolCallModelMessage
  ) {
    self.request = request
    self.modelMessage = modelMessage
  }
}

nonisolated extension ToolCallModelMessage {
  package var modelContextContent: String {
    if isPayloadOmittedFromHistory {
      return payloadOmittedModelContextContent
    }

    guard !arguments.isEmpty else {
      return """
        Tool call \(toolName.rawValue) requested.
        Arguments: none.
        """
    }

    let renderedArguments =
      arguments
      .map { "\($0.name): \($0.value)" }
      .joined(separator: "\n")

    return """
      Tool call \(toolName.rawValue) requested.
      Arguments:
      \(renderedArguments)
      """
  }

  // Test-only projection; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var modelContextRole: ModelContextRole {
    .assistant
  }

  private var isPayloadOmittedFromHistory: Bool {
    toolName == .writeFile || toolName == .editFile || toolName == .todoWrite
  }

  private var payloadOmittedModelContextContent: String {
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

package struct ToolCallModelArgument: Codable, Identifiable, Equatable, Sendable {
  package var id: String { name }

  package var name: String
  package var value: String
}

nonisolated extension ToolCallModelMessage {
  package var transcriptArguments: [ToolCallModelArgument] {
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
  package var displayValue: String {
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

package struct ToolCallRecord: Codable, Identifiable, Equatable, Sendable {
  package var id: UUID { request.id }

  package var request: ToolCallRequest
  package var evaluation: ToolPermissionEvaluation
  package var state: ToolCallState
  package var approvalSource: ToolApprovalSource?
  package var modelFollowUpNotice: String?

  package var status: ToolCallStatus {
    state.status
  }

  package var resultPayload: ToolResultPayload? {
    state.resultPayload
  }

  package var approvalPreview: ToolResultPreview? {
    state.approvalPreview
  }

  // Test-only projection; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var resultPreview: ToolResultPreview? {
    state.preview
  }

  package init(
    request: ToolCallRequest,
    evaluation: ToolPermissionEvaluation,
    state: ToolCallState,
    approvalSource: ToolApprovalSource? = nil,
    modelFollowUpNotice: String? = nil
  ) {
    self.request = request
    self.evaluation = evaluation
    self.state = state
    self.approvalSource = approvalSource
    self.modelFollowUpNotice = modelFollowUpNotice
  }

  private enum CodingKeys: String, CodingKey {
    case request
    case evaluation
    case state
    case approvalSource
    case modelFollowUpNotice
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    request = try container.decode(ToolCallRequest.self, forKey: .request)
    evaluation = try container.decode(ToolPermissionEvaluation.self, forKey: .evaluation)
    state = try container.decode(ToolCallState.self, forKey: .state)
    approvalSource = try container.decodeIfPresent(
      ToolApprovalSource.self,
      forKey: .approvalSource
    )
    modelFollowUpNotice = try container.decodeIfPresent(String.self, forKey: .modelFollowUpNotice)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(request, forKey: .request)
    try container.encode(evaluation, forKey: .evaluation)
    try container.encode(state, forKey: .state)
    try container.encodeIfPresent(approvalSource, forKey: .approvalSource)
    try container.encodeIfPresent(modelFollowUpNotice, forKey: .modelFollowUpNotice)
  }
}

package enum ToolCallState: Codable, Equatable, Sendable {
  case pending
  case awaitingApproval(preview: ToolResultPreview?)
  case awaitingUserAnswer
  case running
  case completed(ToolResultPayload)
  case denied(ToolResultPayload)
  case failed(ToolResultPayload)
  case cancelled

  private enum CodingKeys: String, CodingKey {
    case kind
    case preview
    case payload
  }

  private enum Kind: String, Codable {
    case pending
    case awaitingApproval
    case awaitingUserAnswer
    case running
    case completed
    case denied
    case failed
    case cancelled
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .pending:
      self = .pending
    case .awaitingApproval:
      self = .awaitingApproval(
        preview: try container.decodeIfPresent(ToolResultPreview.self, forKey: .preview)
      )
    case .awaitingUserAnswer:
      self = .awaitingUserAnswer
    case .running:
      self = .running
    case .completed:
      self = .completed(try container.decode(ToolResultPayload.self, forKey: .payload))
    case .denied:
      self = .denied(try container.decode(ToolResultPayload.self, forKey: .payload))
    case .failed:
      self = .failed(try container.decode(ToolResultPayload.self, forKey: .payload))
    case .cancelled:
      self = .cancelled
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pending:
      try container.encode(Kind.pending, forKey: .kind)
    case .awaitingApproval(let preview):
      try container.encode(Kind.awaitingApproval, forKey: .kind)
      try container.encodeIfPresent(preview, forKey: .preview)
    case .awaitingUserAnswer:
      try container.encode(Kind.awaitingUserAnswer, forKey: .kind)
    case .running:
      try container.encode(Kind.running, forKey: .kind)
    case .completed(let payload):
      try container.encode(Kind.completed, forKey: .kind)
      try container.encode(payload, forKey: .payload)
    case .denied(let payload):
      try container.encode(Kind.denied, forKey: .kind)
      try container.encode(payload, forKey: .payload)
    case .failed(let payload):
      try container.encode(Kind.failed, forKey: .kind)
      try container.encode(payload, forKey: .payload)
    case .cancelled:
      try container.encode(Kind.cancelled, forKey: .kind)
    }
  }
}

nonisolated extension ToolCallState {
  package var status: ToolCallStatus {
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

  package var resultPayload: ToolResultPayload? {
    switch self {
    case .completed(let payload), .denied(let payload), .failed(let payload):
      payload
    case .pending, .awaitingApproval, .awaitingUserAnswer, .running, .cancelled:
      nil
    }
  }

  package var approvalPreview: ToolResultPreview? {
    switch self {
    case .awaitingApproval(let preview):
      preview
    case .pending, .awaitingUserAnswer, .running, .completed, .denied, .failed, .cancelled:
      nil
    }
  }

  package var preview: ToolResultPreview? {
    resultPayload?.preview ?? approvalPreview
  }
}

package enum ToolCallStatus: String, Codable, Equatable, Sendable {
  case pending
  case awaitingApproval
  case awaitingUserAnswer
  case denied
  case running
  case completed
  case failed
  case cancelled
}

package struct WorkspaceRelativePath: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  package var rawValue: String

  package init(rawValue: String) {
    self.rawValue = rawValue
  }
}

package enum ToolResultPayload: Codable, Equatable, Sendable {
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
  case finishTask(FinishTaskResult)
  case browserRefresh(BrowserRefreshResult)
  case browserInspect(BrowserInspectResult)
  case webSearch(WebSearchToolResult)
  case webFetch(WebFetchToolResult)
  case mcp(MCPToolResult)
  case duplicateToolCall(DuplicateToolCallResult)
  case invalidTool(InvalidToolResult)
  case failure(ToolFailure)

  private enum CodingKeys: String, CodingKey {
    case kind
    case payload
  }

  private enum Kind: String, Codable {
    case readFile
    case listFiles
    case globFiles
    case searchFiles
    case workspaceDiff
    case workspaceDiagnostics
    case writeFile
    case editFile
    case runCommand
    case todoWrite
    case askUser
    case finishTask
    case browserRefresh
    case browserInspect
    case webSearch
    case webFetch
    case mcp
    case duplicateToolCall
    case invalidTool
    case failure
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .readFile:
      self = .readFile(try container.decode(ReadFileResult.self, forKey: .payload))
    case .listFiles:
      self = .listFiles(try container.decode(ListFilesResult.self, forKey: .payload))
    case .globFiles:
      self = .globFiles(try container.decode(GlobFilesResult.self, forKey: .payload))
    case .searchFiles:
      self = .searchFiles(try container.decode(SearchFilesResult.self, forKey: .payload))
    case .workspaceDiff:
      self = .workspaceDiff(try container.decode(WorkspaceDiffResult.self, forKey: .payload))
    case .workspaceDiagnostics:
      self = .workspaceDiagnostics(
        try container.decode(WorkspaceDiagnosticsResult.self, forKey: .payload)
      )
    case .writeFile:
      self = .writeFile(try container.decode(WriteFileResult.self, forKey: .payload))
    case .editFile:
      self = .editFile(try container.decode(EditFileResult.self, forKey: .payload))
    case .runCommand:
      self = .runCommand(try container.decode(RunCommandResult.self, forKey: .payload))
    case .todoWrite:
      self = .todoWrite(try container.decode(TodoWriteResult.self, forKey: .payload))
    case .askUser:
      self = .askUser(try container.decode(AskUserResult.self, forKey: .payload))
    case .finishTask:
      self = .finishTask(try container.decode(FinishTaskResult.self, forKey: .payload))
    case .browserRefresh:
      self = .browserRefresh(try container.decode(BrowserRefreshResult.self, forKey: .payload))
    case .browserInspect:
      self = .browserInspect(try container.decode(BrowserInspectResult.self, forKey: .payload))
    case .webSearch:
      self = .webSearch(try container.decode(WebSearchToolResult.self, forKey: .payload))
    case .webFetch:
      self = .webFetch(try container.decode(WebFetchToolResult.self, forKey: .payload))
    case .mcp:
      self = .mcp(try container.decode(MCPToolResult.self, forKey: .payload))
    case .duplicateToolCall:
      self = .duplicateToolCall(
        try container.decode(DuplicateToolCallResult.self, forKey: .payload)
      )
    case .invalidTool:
      self = .invalidTool(try container.decode(InvalidToolResult.self, forKey: .payload))
    case .failure:
      self = .failure(try container.decode(ToolFailure.self, forKey: .payload))
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .readFile(let result):
      try container.encode(result, forKey: .payload)
    case .listFiles(let result):
      try container.encode(result, forKey: .payload)
    case .globFiles(let result):
      try container.encode(result, forKey: .payload)
    case .searchFiles(let result):
      try container.encode(result, forKey: .payload)
    case .workspaceDiff(let result):
      try container.encode(result, forKey: .payload)
    case .workspaceDiagnostics(let result):
      try container.encode(result, forKey: .payload)
    case .writeFile(let result):
      try container.encode(result, forKey: .payload)
    case .editFile(let result):
      try container.encode(result, forKey: .payload)
    case .runCommand(let result):
      try container.encode(result, forKey: .payload)
    case .todoWrite(let result):
      try container.encode(result, forKey: .payload)
    case .askUser(let result):
      try container.encode(result, forKey: .payload)
    case .finishTask(let result):
      try container.encode(result, forKey: .payload)
    case .browserRefresh(let result):
      try container.encode(result, forKey: .payload)
    case .browserInspect(let result):
      try container.encode(result, forKey: .payload)
    case .webSearch(let result):
      try container.encode(result, forKey: .payload)
    case .webFetch(let result):
      try container.encode(result, forKey: .payload)
    case .mcp(let result):
      try container.encode(result, forKey: .payload)
    case .duplicateToolCall(let result):
      try container.encode(result, forKey: .payload)
    case .invalidTool(let result):
      try container.encode(result, forKey: .payload)
    case .failure(let failure):
      try container.encode(failure, forKey: .payload)
    }
  }

  private var kind: Kind {
    switch self {
    case .readFile: .readFile
    case .listFiles: .listFiles
    case .globFiles: .globFiles
    case .searchFiles: .searchFiles
    case .workspaceDiff: .workspaceDiff
    case .workspaceDiagnostics: .workspaceDiagnostics
    case .writeFile: .writeFile
    case .editFile: .editFile
    case .runCommand: .runCommand
    case .todoWrite: .todoWrite
    case .askUser: .askUser
    case .finishTask: .finishTask
    case .browserRefresh: .browserRefresh
    case .browserInspect: .browserInspect
    case .webSearch: .webSearch
    case .webFetch: .webFetch
    case .mcp: .mcp
    case .duplicateToolCall: .duplicateToolCall
    case .invalidTool: .invalidTool
    case .failure: .failure
    }
  }
}

package struct DuplicateToolCallResult: Codable, Equatable, Sendable {
  package var previousCallID: UUID
  package var message: String
  package var affectedPaths: [WorkspaceRelativePath]
  package var replayedObservation: ToolModelObservation?
  /// True from the 2nd consecutive identical duplicate: the replayed content is
  /// withheld and the model-facing observation is framed as non-success to break
  /// the loop. The persisted/UI preview stays a benign "duplicate replay".
  package var blocked: Bool

  package init(
    previousCallID: UUID,
    message: String,
    affectedPaths: [WorkspaceRelativePath] = [],
    replayedObservation: ToolModelObservation? = nil,
    blocked: Bool = false
  ) {
    self.previousCallID = previousCallID
    self.message = message
    self.affectedPaths = affectedPaths
    self.replayedObservation = replayedObservation
    self.blocked = blocked
  }
}

package struct WorkspaceDiagnostic: Codable, Equatable, Sendable {
  package var path: WorkspaceRelativePath
  package var line: Int
  package var column: Int?
  package var severity: WorkspaceDiagnosticSeverity
  package var message: String
  package var source: WorkspaceDiagnosticSource

  package init(
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

package enum WorkspaceDiagnosticSeverity: String, Codable, Equatable, Sendable {
  case error
  case warning
  case note
}

package enum WorkspaceDiagnosticSource: String, Codable, Equatable, Sendable {
  case lastCommandOutput
}

package struct InvalidToolResult: Codable, Equatable, Sendable {
  package var originalName: String?
  package var reason: InvalidToolCallReason

  package init(originalName: String?, reason: InvalidToolCallReason) {
    self.originalName = originalName
    self.reason = reason
  }
}

package struct ToolFailure: Codable, Equatable, Sendable {
  package var toolName: ToolName
  package var path: WorkspaceRelativePath?
  package var reason: ToolFailureReason
  package var recovery: RecoveryHint?

  package init(
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

package enum ToolFailureReason: Codable, Equatable, Sendable {
  case fileNotFound(path: WorkspaceRelativePath?, suggestions: [MissingPathSuggestion])
  case pathOutsideWorkspace
  case emptyPath
  case unsupportedURLScheme(String)
  case permissionDenied
  case userDenied
  case finalModeToolAttempt(requestedTool: ToolName?)
  case toolBudgetExceeded(requestedTool: ToolName?, iterationLimit: Int)
  case unsupportedFileType(String)
  case invalidArguments(InvalidToolCallReason)
  case executionError(String)
  case cancelled
}

package enum RecoveryHint: Codable, Equatable, Sendable {
  case readFile(path: WorkspaceRelativePath)
  case retryWithMoreContext(path: WorkspaceRelativePath)
  case chooseOneOf(paths: [WorkspaceRelativePath])
  case askUser(message: String)
  case stop
}

package struct MissingPathSuggestion: Codable, Equatable, Sendable {
  package var path: WorkspaceRelativePath
  package var reason: String
  package var confidence: Double

  package init(path: WorkspaceRelativePath, reason: String, confidence: Double) {
    self.path = path
    self.reason = reason
    self.confidence = confidence
  }
}

package struct ToolTextOutput: Codable, Equatable, Sendable {
  package var text: String
  package var truncated: Bool
  package var redacted: Bool

  package init(text: String, truncated: Bool = false, redacted: Bool = false) {
    self.text = text
    self.truncated = truncated
    self.redacted = redacted
  }
}

package struct ReadKey: Codable, Equatable, Hashable, Sendable {
  package var path: WorkspaceRelativePath
  package var range: String?

  package init(path: WorkspaceRelativePath, range: String? = nil) {
    self.path = path
    self.range = range
  }
}

package struct WorkspaceFileEntry: Codable, Equatable, Sendable {
  package var path: WorkspaceRelativePath
  package var kind: WorkspaceFileKind

  package init(path: WorkspaceRelativePath, kind: WorkspaceFileKind) {
    self.path = path
    self.kind = kind
  }
}

package enum WorkspaceFileKind: String, Codable, Equatable, Sendable {
  case file
  case directory
}

package struct SearchFileMatch: Codable, Equatable, Sendable {
  package var path: WorkspaceRelativePath
  package var line: Int
  package var snippet: String

  package init(path: WorkspaceRelativePath, line: Int, snippet: String) {
    self.path = path
    self.line = line
    self.snippet = snippet
  }
}

package struct ToolResultPreview: Codable, Equatable, Sendable {
  package var status: ToolResultStatus
  package var text: String
  package var truncated: Bool
  package var redacted: Bool
  package var affectedPaths: [String]
  package var resultPayload: ToolResultPayload?

  package init(
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

  package init(from decoder: Decoder) throws {
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

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(text, forKey: .text)
    try container.encode(truncated, forKey: .truncated)
    try container.encode(redacted, forKey: .redacted)
    try container.encode(affectedPaths, forKey: .affectedPaths)
    try container.encodeIfPresent(resultPayload, forKey: .resultPayload)
  }
}

package enum ToolResultStatus: String, Codable, Equatable, Sendable {
  case success
  case failed
  case denied
}

nonisolated extension ToolResultPayload {
  package var status: ToolResultStatus {
    preview.status
  }

  // Test-only projection; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var text: String {
    preview.text
  }

  // Test-only projection; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var truncated: Bool {
    preview.truncated
  }

  // Test-only projection; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var redacted: Bool {
    preview.redacted
  }

  package var affectedPaths: [String] {
    preview.affectedPaths
  }

  package var preview: ToolResultPreview {
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
    case .finishTask(let result):
      return result.preview
    case .browserRefresh(let result):
      return result.preview
    case .browserInspect(let result):
      return result.preview
    case .webSearch(let result):
      return result.preview
    case .webFetch(let result):
      return result.preview
    case .mcp(let result):
      return result.preview
    case .duplicateToolCall(let result):
      return ToolResultPreview(
        status: .success,
        text: result.message,
        affectedPaths: result.affectedPaths.map(\.rawValue)
      )
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
  package var message: String {
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
    case .permissionDenied, .userDenied, .pathOutsideWorkspace:
      .denied
    case .fileNotFound, .emptyPath, .unsupportedURLScheme, .finalModeToolAttempt,
      .toolBudgetExceeded, .unsupportedFileType,
      .invalidArguments, .executionError, .cancelled:
      .failed
    }
  }

  package var message: String {
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
    case .userDenied:
      return "Tool call denied by user."
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
  package var message: String {
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

package struct ToolResultModelMessage: Codable, Equatable, Sendable {
  package var callID: UUID
  package var toolName: ToolName
  package var payload: ToolResultPayload

  package init(
    callID: UUID,
    toolName: ToolName,
    payload: ToolResultPayload
  ) {
    self.callID = callID
    self.toolName = toolName
    self.payload = payload
  }
}

nonisolated extension ToolResultModelMessage {
  package var preview: ToolResultPreview {
    payload.preview
  }
}

package struct ToolPermissionEvaluation: Codable, Equatable, Sendable {
  package var decision: ToolPermissionDecision
  package var reason: String
  package var riskLevel: ToolRiskLevel
  package var normalizedPaths: [String]
  package var workspaceRelativePaths: [WorkspaceRelativePath]

  package init(
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

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    decision = try container.decode(ToolPermissionDecision.self, forKey: .decision)
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

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(decision, forKey: .decision)
    try container.encode(reason, forKey: .reason)
    try container.encode(riskLevel, forKey: .riskLevel)
    try container.encode(normalizedPaths, forKey: .normalizedPaths)
    try container.encode(workspaceRelativePaths, forKey: .workspaceRelativePaths)
  }

  // Test-only projection; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var modelFacingPaths: [String] {
    let relativePaths = workspaceRelativePaths.map(\.rawValue)
    return relativePaths.isEmpty ? normalizedPaths : relativePaths
  }

  package var firstModelFacingPath: WorkspaceRelativePath? {
    workspaceRelativePaths.first ?? normalizedPaths.first.map(WorkspaceRelativePath.init(rawValue:))
  }
}

package enum ToolPermissionDecision: String, Codable, Equatable, Sendable {
  case allowed
  case requiresApproval
  case denied
}

package enum ToolRiskLevel: String, Codable, Equatable, Sendable {
  case low
  case medium
  case high
}
