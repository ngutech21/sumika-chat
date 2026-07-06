import Foundation

public struct ModelPromptProjection: Codable, Equatable, Sendable {
  public var entries: [ModelContextEntry]

  public init(entries: [ModelContextEntry] = []) {
    self.entries = entries
  }

  private enum CodingKeys: String, CodingKey {
    case entries
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entries = try container.decodeLossyArray([ModelContextEntry].self, forKey: .entries)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entries, forKey: .entries)
  }

  public func projectedEntries(
    mode: ModelContextProjectionMode = .fullHistory
  ) -> [ProjectedModelContextEntry] {
    let currentPromptIndex = entries.lastIndex { entry in
      entry.body.isPromptInput
    }
    return entries.indices.map { index in
      entries[index].projectedEntry(
        mode: mode,
        keepFullContent: index == currentPromptIndex
      )
    }
  }

  /// The raw prompt text of the original user prompt in the given turn.
  public func originalUserPromptText(forTurn turnID: ChatTurn.ID) -> String? {
    for entry in entries {
      guard entry.turnID == turnID, case .userPrompt(let context) = entry.body else {
        continue
      }
      return context.prompt
    }
    return nil
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
  /// Identities of the images that were consumed with this entry's prompt.
  /// Never sent to the model; lets the runtime cache distinguish prefixes
  /// whose rendered text is identical but whose prefilled images differ.
  public let imageSignatures: [String]

  public init(
    role: ModelContextRole,
    content: String,
    imageSignatures: [String] = []
  ) {
    self.role = role
    self.content = content
    self.imageSignatures = imageSignatures
  }
}

public struct ModelContextEntry: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let turnID: ChatTurn.ID?
  public let sourceMessageID: UUID?
  public let body: ModelContextEntryBody
  public let frozenContent: FrozenModelContent

  public init(
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    sourceMessageID: UUID? = nil,
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
    let turnID = try container.decodeIfPresent(ChatTurn.ID.self, forKey: .turnID)
    let sourceMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceMessageID)
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
    case .userPrompt:
      return .user
    case .assistantOutput:
      return .assistant
    case .toolObservation, .terminalToolResult:
      return .tool
    }
  }

  public var isPromptInput: Bool {
    switch self {
    case .userPrompt, .toolObservation, .terminalToolResult:
      return true
    case .assistantOutput:
      return false
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
  /// Content signatures of the image attachments consumed with this prompt.
  /// Part of the persisted entry so later history renderings reproduce the
  /// exact identity of what was prefilled into the runtime KV cache.
  public let imageSignatures: [String]
  public let systemContext: [String]
  public let currentPromptContext: CurrentPromptContext?

  public init(
    prompt: String,
    attachmentNames: [String] = [],
    imageSignatures: [String] = [],
    systemContext: [String] = [],
    currentPromptContext: CurrentPromptContext? = nil
  ) {
    self.prompt = prompt
    self.attachmentNames = attachmentNames
    self.imageSignatures = imageSignatures
    self.systemContext = systemContext
    self.currentPromptContext = currentPromptContext
  }

  private enum CodingKeys: String, CodingKey {
    case prompt
    case attachmentNames
    case imageSignatures
    case systemContext
    case currentPromptContext
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt, default: "")
    attachmentNames = try container.decodeIfPresent(
      [String].self,
      forKey: .attachmentNames,
      default: []
    )
    imageSignatures = try container.decodeIfPresent(
      [String].self,
      forKey: .imageSignatures,
      default: []
    )
    systemContext = try container.decodeIfPresent(
      [String].self,
      forKey: .systemContext,
      default: []
    )
    currentPromptContext = try container.decodeIfPresent(
      CurrentPromptContext.self,
      forKey: .currentPromptContext
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(prompt, forKey: .prompt)
    try container.encode(attachmentNames, forKey: .attachmentNames)
    try container.encode(imageSignatures, forKey: .imageSignatures)
    try container.encode(systemContext, forKey: .systemContext)
    try container.encodeIfPresent(currentPromptContext, forKey: .currentPromptContext)
  }
}

public struct AssistantOutputContext: Codable, Equatable, Sendable {
  public let content: String

  public init(content: String) {
    self.content = content
  }

  private enum CodingKeys: String, CodingKey {
    case content
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(content, forKey: .content)
  }
}

public struct ToolObservationContext: Codable, Equatable, Sendable {
  public let callID: UUID
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let content: String
  public let toolReceipt: ToolReceipt?
  public let toolCall: ToolCallModelMessage?
  public let systemContext: [String]

  public init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    content: String,
    toolReceipt: ToolReceipt? = nil,
    toolCall: ToolCallModelMessage? = nil,
    systemContext: [String] = []
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.content = content
    self.toolReceipt = toolReceipt
    self.toolCall = toolCall
    self.systemContext = systemContext
  }

  private enum CodingKeys: String, CodingKey {
    case callID
    case toolName
    case status
    case content
    case toolReceipt
    case toolCall
    case systemContext
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    callID = try container.decodeIfPresent(UUID.self, forKey: .callID, default: UUID())
    toolName = try container.decodeIfPresent(ToolName.self, forKey: .toolName, default: .invalid)
    status = try container.decodeIfPresent(ToolResultStatus.self, forKey: .status, default: .failed)
    content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
    toolReceipt = try container.decodeIfPresent(ToolReceipt.self, forKey: .toolReceipt)
    toolCall = try container.decodeIfPresent(ToolCallModelMessage.self, forKey: .toolCall)
    systemContext = try container.decodeIfPresent(
      [String].self,
      forKey: .systemContext,
      default: []
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(callID, forKey: .callID)
    try container.encode(toolName, forKey: .toolName)
    try container.encode(status, forKey: .status)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(toolReceipt, forKey: .toolReceipt)
    try container.encodeIfPresent(toolCall, forKey: .toolCall)
    try container.encode(systemContext, forKey: .systemContext)
  }
}

public struct TerminalToolResultContext: Codable, Equatable, Sendable {
  public let callID: UUID
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let content: String
  public let toolReceipt: ToolReceipt?
  public let toolCall: ToolCallModelMessage?

  public init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    content: String,
    toolReceipt: ToolReceipt? = nil,
    toolCall: ToolCallModelMessage? = nil
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.content = content
    self.toolReceipt = toolReceipt
    self.toolCall = toolCall
  }

  private enum CodingKeys: String, CodingKey {
    case callID
    case toolName
    case status
    case content
    case toolReceipt
    case toolCall
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    callID = try container.decodeIfPresent(UUID.self, forKey: .callID, default: UUID())
    toolName = try container.decodeIfPresent(ToolName.self, forKey: .toolName, default: .invalid)
    status = try container.decodeIfPresent(ToolResultStatus.self, forKey: .status, default: .failed)
    content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
    toolReceipt = try container.decodeIfPresent(ToolReceipt.self, forKey: .toolReceipt)
    toolCall = try container.decodeIfPresent(ToolCallModelMessage.self, forKey: .toolCall)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(callID, forKey: .callID)
    try container.encode(toolName, forKey: .toolName)
    try container.encode(status, forKey: .status)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(toolReceipt, forKey: .toolReceipt)
    try container.encodeIfPresent(toolCall, forKey: .toolCall)
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

  private enum CodingKeys: String, CodingKey {
    case callID
    case toolName
    case status
    case affectedPaths
    case summary
    case outputTruncated
    case outputRedacted
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      callID: try container.decodeIfPresent(UUID.self, forKey: .callID, default: UUID()),
      toolName: try container.decodeIfPresent(ToolName.self, forKey: .toolName, default: .invalid),
      status: try container.decodeIfPresent(
        ToolResultStatus.self, forKey: .status, default: .failed),
      affectedPaths: try container.decodeIfPresent(
        [WorkspaceRelativePath].self,
        forKey: .affectedPaths,
        default: []
      ),
      summary: try container.decodeIfPresent(
        ToolReceiptSummary.self,
        forKey: .summary,
        default: ToolReceiptSummary(text: "", truncated: false)
      ),
      outputTruncated: try container.decodeIfPresent(
        Bool.self,
        forKey: .outputTruncated,
        default: false
      ),
      outputRedacted: try container.decodeIfPresent(
        Bool.self,
        forKey: .outputRedacted,
        default: false
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(callID, forKey: .callID)
    try container.encode(toolName, forKey: .toolName)
    try container.encode(status, forKey: .status)
    try container.encode(affectedPaths, forKey: .affectedPaths)
    try container.encode(summary, forKey: .summary)
    try container.encode(outputTruncated, forKey: .outputTruncated)
    try container.encode(outputRedacted, forKey: .outputRedacted)
  }
}

public struct ToolReceiptSummary: Codable, Equatable, Sendable {
  public let text: String
  public let truncated: Bool

  fileprivate init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }

  private enum CodingKeys: String, CodingKey {
    case text
    case truncated
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      text: try container.decodeIfPresent(String.self, forKey: .text, default: ""),
      truncated: try container.decodeIfPresent(Bool.self, forKey: .truncated, default: false)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encode(truncated, forKey: .truncated)
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
    let role = try container.decodeIfPresent(ModelContextRole.self, forKey: .role, default: .user)
    let content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
    let signature = try container.decodeIfPresent(
      String.self,
      forKey: .signature,
      default: Self.signature(role: role, content: content)
    )
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
  case tool
}

extension ModelContextEntry {
  fileprivate var imageSignatures: [String] {
    guard case .userPrompt(let context) = body else {
      return []
    }
    return context.imageSignatures
  }

  fileprivate func projectedEntry(
    mode: ModelContextProjectionMode,
    keepFullContent: Bool
  ) -> ProjectedModelContextEntry {
    guard mode == .compactedHistoryForLaterTurns, !keepFullContent else {
      return ProjectedModelContextEntry(
        role: frozenContent.role,
        content: frozenContent.content,
        imageSignatures: imageSignatures
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
        role: .tool,
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
        role: .tool,
        content: ToolReceiptRenderer.render(toolReceipt)
      )
    case .userPrompt, .assistantOutput:
      return ProjectedModelContextEntry(
        role: frozenContent.role,
        content: frozenContent.content,
        imageSignatures: imageSignatures
      )
    }
  }
}
