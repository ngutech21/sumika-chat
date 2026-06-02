import Foundation

nonisolated struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: MessageKind
  let content: String
  let attachments: [ChatAttachment]
  let generationMetrics: ChatGenerationMetrics?
  let toolCall: ToolCallModelMessage?
  let toolResult: ToolResultModelMessage?
  let turnID: ChatTurnRecord.ID?
  let deliveryStatus: ChatMessageDeliveryStatus

  init(
    id: UUID = UUID(),
    kind: MessageKind,
    content: String,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    toolCall: ToolCallModelMessage? = nil,
    toolResult: ToolResultModelMessage? = nil,
    turnID: ChatTurnRecord.ID? = nil,
    deliveryStatus: ChatMessageDeliveryStatus = .complete
  ) {
    precondition(kind.allows(content: content, toolCall: toolCall, toolResult: toolResult))
    self.id = id
    self.kind = kind
    self.content = content
    self.attachments = attachments
    self.generationMetrics = generationMetrics
    self.toolCall = toolCall
    self.toolResult = toolResult
    self.turnID = turnID
    self.deliveryStatus = deliveryStatus
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case content
    case attachments
    case generationMetrics
    case toolCall
    case toolResult
    case turnID
    case deliveryStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(MessageKind.self, forKey: .kind)
    content = try container.decode(String.self, forKey: .content)
    attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    generationMetrics = try container.decodeIfPresent(
      ChatGenerationMetrics.self, forKey: .generationMetrics)
    toolCall = try container.decodeIfPresent(ToolCallModelMessage.self, forKey: .toolCall)
    toolResult = try container.decodeIfPresent(ToolResultModelMessage.self, forKey: .toolResult)
    turnID = try container.decodeIfPresent(ChatTurnRecord.ID.self, forKey: .turnID)
    deliveryStatus =
      try container.decodeIfPresent(ChatMessageDeliveryStatus.self, forKey: .deliveryStatus)
      ?? .complete

    guard kind.allows(content: content, toolCall: toolCall, toolResult: toolResult) else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Message kind does not match message payload."
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(content, forKey: .content)
    try container.encode(attachments, forKey: .attachments)
    try container.encodeIfPresent(generationMetrics, forKey: .generationMetrics)
    try container.encodeIfPresent(toolCall, forKey: .toolCall)
    try container.encodeIfPresent(toolResult, forKey: .toolResult)
    try container.encodeIfPresent(turnID, forKey: .turnID)
    if deliveryStatus != .complete {
      try container.encode(deliveryStatus, forKey: .deliveryStatus)
    }
  }
}

nonisolated struct ChatGenerationMetrics: Codable, Equatable, Sendable {
  let generatedTokenCount: Int
  let tokensPerSecond: Double
}

nonisolated enum ChatMessageDeliveryStatus: String, Codable, Equatable, Sendable {
  case complete
  case streaming
  case cancelled
}

nonisolated extension ChatMessage {
  var containsStreamingToolCallMarkup: Bool {
    guard kind == .assistant else {
      return false
    }

    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      return false
    }

    return "<action".hasPrefix(trimmedContent) || trimmedContent.hasPrefix("<action")
  }
}

nonisolated enum MessageKind: String, Codable, Equatable, Sendable {
  case user
  case assistant
  case toolCall
  case toolResult
  case system

  var title: String {
    switch self {
    case .user:
      "You"
    case .assistant:
      "Local Coder"
    case .toolCall, .toolResult:
      "Local Coder"
    case .system:
      "System"
    }
  }

  var systemImage: String {
    switch self {
    case .user:
      "person.crop.circle"
    case .assistant:
      "cpu"
    case .toolCall:
      "wrench.and.screwdriver"
    case .toolResult:
      "checkmark.circle"
    case .system:
      "gearshape"
    }
  }

  fileprivate func allows(
    content: String,
    toolCall: ToolCallModelMessage?,
    toolResult: ToolResultModelMessage?
  ) -> Bool {
    switch self {
    case .user, .assistant, .system:
      return toolCall == nil && toolResult == nil
    case .toolCall:
      return content.isEmpty && toolCall != nil && toolResult == nil
    case .toolResult:
      return content.isEmpty && toolCall == nil && toolResult != nil
    }
  }
}
