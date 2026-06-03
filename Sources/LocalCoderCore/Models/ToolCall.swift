import Foundation

public typealias ToolCallArguments = [String: ToolArgumentValue]

public struct ToolName: Codable, Equatable, Hashable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = Self.canonicalName(for: rawValue)
  }

  public init(canonicalizing name: String) {
    self.init(rawValue: name)
  }

  public static let listFiles = ToolName(rawValue: "list_files")
  public static let globFiles = ToolName(rawValue: "glob_files")
  public static let readFile = ToolName(rawValue: "read_file")
  public static let searchFiles = ToolName(rawValue: "search_files")
  public static let editFile = ToolName(rawValue: "edit_file")
  public static let writeFile = ToolName(rawValue: "write_file")
  public static let runCommand = ToolName(rawValue: "run_command")
  public static let invalid = ToolName(rawValue: "invalid")

  private static func canonicalName(for name: String) -> String {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
      .lowercased()
    switch normalized {
    case "read":
      return Self.readFile.rawValue
    case "list":
      return Self.listFiles.rawValue
    case "glob":
      return Self.globFiles.rawValue
    case "search":
      return Self.searchFiles.rawValue
    case "edit":
      return Self.editFile.rawValue
    case "write":
      return Self.writeFile.rawValue
    case "run", "command":
      return Self.runCommand.rawValue
    default:
      return normalized
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum ToolIntentHeuristics {
  public static func looksLikeNonTaggedToolIntent(_ content: String) -> Bool {
    let lowered = content.lowercased()
    let hasToolCallPhrase = lowered.contains("tool call")
    let indicatorCount = [
      "requested",
      "path:",
      "old text:",
      "new text:",
      "old_text",
      "new_text",
    ].filter { lowered.contains($0) }.count

    return (hasToolCallPhrase && indicatorCount > 0)
      || (lowered.contains("path:") && lowered.contains("old text:")
        && lowered.contains("new text:"))
  }

  public static func inferredToolName(from content: String) -> String {
    let lowered = content.lowercased()
    let knownToolNames = [
      ToolName.readFile.rawValue,
      ToolName.listFiles.rawValue,
      ToolName.globFiles.rawValue,
      ToolName.searchFiles.rawValue,
      ToolName.editFile.rawValue,
      ToolName.writeFile.rawValue,
      ToolName.runCommand.rawValue,
    ]

    for toolName in knownToolNames {
      if lowered.contains(toolName)
        || lowered.contains(toolName.replacingOccurrences(of: "_", with: " "))
      {
        return toolName
      }
    }

    guard let phraseRange = lowered.range(of: "tool call") else {
      return "unknown"
    }

    let remainder = content[phraseRange.upperBound...].trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard let token = remainder.split(whereSeparator: \.isWhitespace).first else {
      return "unknown"
    }

    let candidate = token.trimmingCharacters(
      in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted
    )
    return candidate.isEmpty ? "unknown" : ToolName(canonicalizing: candidate).rawValue
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
  public let sessionID: CodingSession.ID
  public var toolName: ToolName
  public var arguments: ToolCallArguments
  public var rawText: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID,
    toolName: ToolName,
    arguments: ToolCallArguments = [:],
    rawText: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.sessionID = sessionID
    self.toolName = toolName
    self.arguments = arguments
    self.rawText = rawText
    self.createdAt = createdAt
  }
}

public struct ToolCallRequest: Codable, Identifiable, Equatable, Sendable {
  public var raw: RawToolCallRequest
  public var payload: ToolCallPayload

  public var id: UUID { raw.id }
  public var workspaceID: Workspace.ID { raw.workspaceID }
  public var sessionID: CodingSession.ID { raw.sessionID }
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
  case listFiles(ListFilesInput)
  case globFiles(GlobFilesInput)
  case searchFiles(SearchFilesInput)
  case writeFile(WriteFileInput)
  case editFile(EditFileInput)
  case invalid(InvalidToolInput)
}

nonisolated extension ToolCallPayload {
  public var toolName: ToolName {
    switch self {
    case .readFile:
      .readFile
    case .listFiles:
      .listFiles
    case .globFiles:
      .globFiles
    case .searchFiles:
      .searchFiles
    case .writeFile:
      .writeFile
    case .editFile:
      .editFile
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
  case emptyOldText
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
    case .emptyOldText:
      "edit_file old_text must not be empty."
    case .parserError(let error):
      error
    }
  }
}

public struct ToolCallModelMessage: Codable, Equatable, Sendable {
  public var callID: UUID
  public var toolName: ToolName
  public var arguments: [ToolCallModelArgument]

  public init(callID: UUID, toolName: ToolName, arguments: [ToolCallModelArgument]) {
    self.callID = callID
    self.toolName = toolName
    self.arguments = arguments
  }

  public init(rawRequest: RawToolCallRequest) {
    self.init(
      callID: rawRequest.id,
      toolName: rawRequest.toolName,
      arguments: rawRequest.arguments.keys.sorted().map { key in
        ToolCallModelArgument(name: key, value: rawRequest.arguments[key]?.displayValue ?? "")
      }
    )
  }

  public init(request: ToolCallRequest) {
    self.init(
      rawRequest: request.raw
    )
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
      return arguments.filter { $0.name != "content" }
    case .editFile:
      return arguments.filter { $0.name != "old_text" && $0.name != "new_text" }
    default:
      return arguments
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
  public var status: ToolCallStatus
  public var evaluation: ToolPermissionEvaluation
  public var events: [ToolCallEvent]
  public var resultPreview: ToolResultPreview?

  public init(
    request: ToolCallRequest,
    status: ToolCallStatus,
    evaluation: ToolPermissionEvaluation,
    events: [ToolCallEvent] = [],
    resultPreview: ToolResultPreview? = nil
  ) {
    self.request = request
    self.status = status
    self.evaluation = evaluation
    self.events = events
    self.resultPreview = resultPreview
  }
}

public enum ToolCallStatus: String, Codable, Equatable, Sendable {
  case pending
  case awaitingApproval
  case approved
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
  case approved
  case denied
  case started
  case completed
  case failed
  case cancelled
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

  private enum CodingKeys: String, CodingKey {
    case status
    case text
    case truncated
    case redacted
    case affectedPaths
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decodeIfPresent(ToolResultStatus.self, forKey: .status) ?? .success
    text = try container.decode(String.self, forKey: .text)
    truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
    affectedPaths = try container.decodeIfPresent([String].self, forKey: .affectedPaths) ?? []
  }
}

public enum ToolResultStatus: String, Codable, Equatable, Sendable {
  case success
  case failed
  case denied
}

public struct ToolResultModelMessage: Codable, Equatable, Sendable {
  public var callID: UUID
  public var toolName: ToolName
  public var preview: ToolResultPreview
}

public struct ToolPermissionEvaluation: Codable, Equatable, Sendable {
  public var decision: ToolPermissionDecision
  public var reason: String
  public var riskLevel: ToolRiskLevel
  public var normalizedPaths: [String]

  public init(
    decision: ToolPermissionDecision,
    reason: String,
    riskLevel: ToolRiskLevel,
    normalizedPaths: [String] = []
  ) {
    self.decision = decision
    self.reason = reason
    self.riskLevel = riskLevel
    self.normalizedPaths = normalizedPaths
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
