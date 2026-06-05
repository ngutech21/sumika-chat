import Foundation

public struct ModelFacingTranscript: Codable, Equatable, Sendable {
  public var entries: [ModelContextEntry]

  public init(entries: [ModelContextEntry] = []) {
    self.entries = entries
  }

  public func projectedEntries(
    mode: ModelContextProjectionMode = .fullHistory
  ) -> [ProjectedModelContextEntry] {
    let currentPromptIndex = entries.lastIndex { $0.frozenContent.role == .user }
    return entries.indices.map { index in
      entries[index].projectedEntry(
        mode: mode,
        keepFullContent: index == currentPromptIndex
      )
    }
  }
}

public enum ModelContextProjectionMode: String, Equatable, Sendable {
  case fullHistory = "full_history"
  case compactedHistoryForLaterTurns = "compacted_history_for_later_turns"

  public var signatureComponent: String {
    rawValue
  }
}

public struct ProjectedModelContextEntry: Equatable, Sendable {
  public let role: ModelContextRole
  public let content: String
}

public struct ModelContextEntry: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let turnID: ChatTurnRecord.ID?
  public let sourceMessageID: ChatMessage.ID?
  public let body: ModelContextEntryBody
  public let frozenContent: FrozenModelContent

  public init(
    id: UUID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    sourceMessageID: ChatMessage.ID? = nil,
    body: ModelContextEntryBody,
    frozenContent: FrozenModelContent
  ) throws {
    guard frozenContent.role == body.modelRole else {
      throw ModelContextEntryError.roleMismatch(
        expected: body.modelRole,
        actual: frozenContent.role
      )
    }
    self.id = id
    self.turnID = turnID
    self.sourceMessageID = sourceMessageID
    self.body = body
    self.frozenContent = frozenContent
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case turnID
    case sourceMessageID
    case body
    case frozenContent
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(UUID.self, forKey: .id)
    let turnID = try container.decodeIfPresent(ChatTurnRecord.ID.self, forKey: .turnID)
    let sourceMessageID = try container.decodeIfPresent(
      ChatMessage.ID.self, forKey: .sourceMessageID)
    let body = try container.decode(ModelContextEntryBody.self, forKey: .body)
    let frozenContent = try container.decode(FrozenModelContent.self, forKey: .frozenContent)
    try self.init(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: body,
      frozenContent: frozenContent
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(turnID, forKey: .turnID)
    try container.encodeIfPresent(sourceMessageID, forKey: .sourceMessageID)
    try container.encode(body, forKey: .body)
    try container.encode(frozenContent, forKey: .frozenContent)
  }
}

public enum ModelContextEntryError: LocalizedError, Equatable, Sendable {
  case roleMismatch(expected: ModelContextRole, actual: ModelContextRole)

  public var errorDescription: String? {
    switch self {
    case .roleMismatch(let expected, let actual):
      "Model context entry role mismatch. Expected \(expected.rawValue), got \(actual.rawValue)."
    }
  }
}

public enum ModelContextEntryBody: Codable, Equatable, Sendable {
  case userPrompt(UserPromptContext)
  case assistantOutput(AssistantOutputContext)
  case toolObservation(ToolObservationContext)
  case terminalToolResult(TerminalToolResultContext)

  public var modelRole: ModelContextRole {
    switch self {
    case .userPrompt, .toolObservation:
      return .user
    case .assistantOutput, .terminalToolResult:
      return .assistant
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case userPrompt
    case assistantOutput
    case toolObservation
    case terminalToolResult
  }

  private enum Kind: String, Codable {
    case userPrompt
    case assistantOutput
    case toolObservation
    case terminalToolResult
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .userPrompt:
      self = .userPrompt(try container.decode(UserPromptContext.self, forKey: .userPrompt))
    case .assistantOutput:
      self = .assistantOutput(
        try container.decode(AssistantOutputContext.self, forKey: .assistantOutput)
      )
    case .toolObservation:
      self = .toolObservation(
        try container.decode(ToolObservationContext.self, forKey: .toolObservation)
      )
    case .terminalToolResult:
      self = .terminalToolResult(
        try container.decode(TerminalToolResultContext.self, forKey: .terminalToolResult)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .userPrompt(let context):
      try container.encode(Kind.userPrompt, forKey: .kind)
      try container.encode(context, forKey: .userPrompt)
    case .assistantOutput(let context):
      try container.encode(Kind.assistantOutput, forKey: .kind)
      try container.encode(context, forKey: .assistantOutput)
    case .toolObservation(let context):
      try container.encode(Kind.toolObservation, forKey: .kind)
      try container.encode(context, forKey: .toolObservation)
    case .terminalToolResult(let context):
      try container.encode(Kind.terminalToolResult, forKey: .kind)
      try container.encode(context, forKey: .terminalToolResult)
    }
  }
}

public struct UserPromptContext: Codable, Equatable, Sendable {
  public let prompt: String
  public let attachmentNames: [String]
  public let systemContext: [String]
  public let currentPromptContext: ConsumedCurrentPromptContext?

  public init(
    prompt: String,
    attachmentNames: [String] = [],
    systemContext: [String] = [],
    currentPromptContext: ConsumedCurrentPromptContext? = nil
  ) {
    self.prompt = prompt
    self.attachmentNames = attachmentNames
    self.systemContext = systemContext
    self.currentPromptContext = currentPromptContext
  }
}

public struct AssistantOutputContext: Codable, Equatable, Sendable {
  public let content: String

  public init(content: String) {
    self.content = content
  }
}

public struct ToolObservationContext: Codable, Equatable, Sendable {
  public let callID: UUID
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let content: String
  public let toolReceipt: ToolReceipt?

  public init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    content: String,
    toolReceipt: ToolReceipt? = nil
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.content = content
    self.toolReceipt = toolReceipt
  }
}

public struct TerminalToolResultContext: Codable, Equatable, Sendable {
  public let callID: UUID
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let content: String
  public let toolReceipt: ToolReceipt?

  public init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    content: String,
    toolReceipt: ToolReceipt? = nil
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.content = content
    self.toolReceipt = toolReceipt
  }
}

public struct ToolReceipt: Codable, Equatable, Sendable {
  public let callID: UUID
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let affectedPaths: [WorkspaceRelativePath]
  public let summary: ToolReceiptSummary
  public let outputTruncated: Bool
  public let outputRedacted: Bool

  private init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    affectedPaths: [WorkspaceRelativePath],
    summary: ToolReceiptSummary,
    outputTruncated: Bool,
    outputRedacted: Bool
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.affectedPaths = affectedPaths
    self.summary = summary
    self.outputTruncated = outputTruncated
    self.outputRedacted = outputRedacted
  }

  static func make(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    affectedPaths: [WorkspaceRelativePath],
    summary: ToolReceiptSummary,
    outputTruncated: Bool,
    outputRedacted: Bool
  ) -> ToolReceipt {
    ToolReceipt(
      callID: callID,
      toolName: toolName,
      status: status,
      affectedPaths: affectedPaths,
      summary: summary,
      outputTruncated: outputTruncated,
      outputRedacted: outputRedacted
    )
  }
}

public struct ToolReceiptSummary: Codable, Equatable, Sendable {
  public let text: String
  public let truncated: Bool

  private init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }

  public static func checked(text: String, maxCharacters: Int = 600) -> ToolReceiptSummary? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, maxCharacters > 0 else {
      return nil
    }

    guard trimmed.count > maxCharacters else {
      return ToolReceiptSummary(text: trimmed, truncated: false)
    }

    return ToolReceiptSummary(
      text: String(trimmed.prefix(maxCharacters)),
      truncated: true
    )
  }
}

public struct FrozenModelContent: Codable, Equatable, Sendable {
  public let role: ModelContextRole
  public let content: String
  public let signature: String

  public init(
    role: ModelContextRole,
    content: String
  ) {
    self.role = role
    self.content = content
    self.signature = Self.signature(role: role, content: content)
  }

  private enum CodingKeys: String, CodingKey {
    case role
    case content
    case signature
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let role = try container.decode(ModelContextRole.self, forKey: .role)
    let content = try container.decode(String.self, forKey: .content)
    let signature = try container.decode(String.self, forKey: .signature)
    let expectedSignature = Self.signature(role: role, content: content)
    guard signature == expectedSignature else {
      throw DecodingError.dataCorruptedError(
        forKey: .signature,
        in: container,
        debugDescription: "Frozen model content signature does not match role and content."
      )
    }

    self.role = role
    self.content = content
    self.signature = expectedSignature
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    try container.encode(content, forKey: .content)
    try container.encode(Self.signature(role: role, content: content), forKey: .signature)
  }

  public static func signature(role: ModelContextRole, content: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func update(_ byte: UInt8) {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }

    for byte in role.rawValue.utf8 {
      update(byte)
    }
    update(0)
    for byte in content.utf8 {
      update(byte)
    }

    return String(format: "%016llx", hash)
  }
}

public enum ModelContextRole: String, Codable, Equatable, Sendable {
  case user
  case assistant
}

extension ModelContextEntry {
  fileprivate func projectedEntry(
    mode: ModelContextProjectionMode,
    keepFullContent: Bool
  ) -> ProjectedModelContextEntry {
    guard mode == .compactedHistoryForLaterTurns, !keepFullContent else {
      return ProjectedModelContextEntry(
        role: frozenContent.role,
        content: frozenContent.content
      )
    }

    switch body {
    case .toolObservation(let context):
      guard let toolReceipt = context.toolReceipt else {
        return ProjectedModelContextEntry(
          role: frozenContent.role,
          content: frozenContent.content
        )
      }
      return ProjectedModelContextEntry(
        role: .user,
        content: ToolReceiptRenderer.render(toolReceipt)
      )
    case .terminalToolResult(let context):
      guard let toolReceipt = context.toolReceipt else {
        return ProjectedModelContextEntry(
          role: frozenContent.role,
          content: frozenContent.content
        )
      }
      return ProjectedModelContextEntry(
        role: .assistant,
        content: ToolReceiptRenderer.render(toolReceipt)
      )
    case .userPrompt, .assistantOutput:
      return ProjectedModelContextEntry(
        role: frozenContent.role,
        content: frozenContent.content
      )
    }
  }
}
