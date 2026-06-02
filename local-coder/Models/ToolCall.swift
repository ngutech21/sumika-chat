import Foundation

typealias ToolCallArguments = [String: ToolArgumentValue]

nonisolated struct ToolName: Codable, Equatable, Hashable, Sendable, RawRepresentable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = Self.canonicalName(for: rawValue)
  }

  init(canonicalizing name: String) {
    self.init(rawValue: name)
  }

  static let listFiles = ToolName(rawValue: "list_files")
  static let globFiles = ToolName(rawValue: "glob_files")
  static let readFile = ToolName(rawValue: "read_file")
  static let searchFiles = ToolName(rawValue: "search_files")
  static let editFile = ToolName(rawValue: "edit_file")
  static let writeFile = ToolName(rawValue: "write_file")
  static let applyPatch = ToolName(rawValue: "apply_patch")
  static let runCommand = ToolName(rawValue: "run_command")

  private static func canonicalName(for name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
      .lowercased()
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

nonisolated enum ToolArgumentValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([ToolArgumentValue])
  case object([String: ToolArgumentValue])
  case null

  init(from decoder: Decoder) throws {
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

  func encode(to encoder: Encoder) throws {
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

nonisolated struct ToolCallRequest: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let workspaceID: Workspace.ID
  let sessionID: CodingSession.ID
  var toolName: ToolName
  var arguments: ToolCallArguments
  var createdAt: Date

  init(
    id: UUID = UUID(),
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID,
    toolName: ToolName,
    arguments: ToolCallArguments = [:],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.sessionID = sessionID
    self.toolName = toolName
    self.arguments = arguments
    self.createdAt = createdAt
  }
}

nonisolated struct ToolCallModelMessage: Codable, Equatable, Sendable {
  var callID: UUID
  var toolName: ToolName
  var arguments: [ToolCallModelArgument]

  init(callID: UUID, toolName: ToolName, arguments: [ToolCallModelArgument]) {
    self.callID = callID
    self.toolName = toolName
    self.arguments = arguments
  }

  init(request: ToolCallRequest) {
    self.init(
      callID: request.id,
      toolName: request.toolName,
      arguments: request.arguments.keys.sorted().map { key in
        ToolCallModelArgument(name: key, value: request.arguments[key]?.displayValue ?? "")
      }
    )
  }
}

nonisolated struct ToolCallModelArgument: Codable, Identifiable, Equatable, Sendable {
  var id: String { name }

  var name: String
  var value: String
}

nonisolated extension ToolCallModelMessage {
  var transcriptArguments: [ToolCallModelArgument] {
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
  var displayValue: String {
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

nonisolated struct ToolCallRecord: Codable, Identifiable, Equatable, Sendable {
  var id: UUID { request.id }

  var request: ToolCallRequest
  var status: ToolCallStatus
  var evaluation: ToolPermissionEvaluation
  var events: [ToolCallEvent]
  var resultPreview: ToolResultPreview?

  init(
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

nonisolated enum ToolCallStatus: String, Codable, Equatable, Sendable {
  case pending
  case awaitingApproval
  case approved
  case denied
  case running
  case completed
  case failed
  case cancelled
}

nonisolated struct ToolCallEvent: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var timestamp: Date
  var actor: ToolCallActor
  var kind: ToolCallEventKind
  var message: String

  init(
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

nonisolated enum ToolCallActor: String, Codable, Equatable, Sendable {
  case assistant
  case user
  case system
  case tool
}

nonisolated enum ToolCallEventKind: String, Codable, Equatable, Sendable {
  case requested
  case awaitingApproval
  case approved
  case denied
  case started
  case completed
  case failed
  case cancelled
}

nonisolated struct ToolResultPreview: Codable, Equatable, Sendable {
  var status: ToolResultStatus
  var text: String
  var truncated: Bool
  var redacted: Bool
  var affectedPaths: [String]

  init(
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

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decodeIfPresent(ToolResultStatus.self, forKey: .status) ?? .success
    text = try container.decode(String.self, forKey: .text)
    truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
    affectedPaths = try container.decodeIfPresent([String].self, forKey: .affectedPaths) ?? []
  }
}

nonisolated enum ToolResultStatus: String, Codable, Equatable, Sendable {
  case success
  case failed
  case denied
}

nonisolated struct ToolResultModelMessage: Codable, Equatable, Sendable {
  var callID: UUID
  var toolName: ToolName
  var preview: ToolResultPreview
}

nonisolated struct ToolPermissionEvaluation: Codable, Equatable, Sendable {
  var decision: ToolPermissionDecision
  var reason: String
  var riskLevel: ToolRiskLevel
  var normalizedPaths: [String]

  init(
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

nonisolated enum ToolPermissionDecision: String, Codable, Equatable, Sendable {
  case allowed
  case requiresApproval
  case denied
}

nonisolated enum ToolRiskLevel: String, Codable, Equatable, Sendable {
  case low
  case medium
  case high
}
