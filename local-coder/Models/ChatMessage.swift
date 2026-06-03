import Foundation

nonisolated struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let payload: ChatMessagePayload
  let turnID: ChatTurnRecord.ID?

  init(
    id: UUID = UUID(),
    payload: ChatMessagePayload,
    turnID: ChatTurnRecord.ID? = nil
  ) {
    self.id = id
    self.payload = payload
    self.turnID = turnID
  }

  init(
    id: UUID = UUID(),
    userContent content: String,
    attachments: [ChatAttachment] = [],
    turnID: ChatTurnRecord.ID? = nil
  ) {
    self.init(
      id: id,
      payload: .user(UserMessagePayload(content: content, attachments: attachments)),
      turnID: turnID
    )
  }

  init(
    id: UUID = UUID(),
    assistantContent content: String,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    deliveryStatus: ChatMessageDeliveryStatus = .complete,
    turnID: ChatTurnRecord.ID? = nil
  ) {
    self.init(
      id: id,
      payload: .assistant(
        AssistantMessagePayload(
          content: content,
          attachments: attachments,
          generationMetrics: generationMetrics,
          deliveryStatus: deliveryStatus
        )
      ),
      turnID: turnID
    )
  }

  init(
    id: UUID = UUID(),
    systemContent content: String,
    turnID: ChatTurnRecord.ID? = nil
  ) {
    self.init(id: id, payload: .system(SystemMessagePayload(content: content)), turnID: turnID)
  }

  init(
    id: UUID = UUID(),
    toolCall: ToolCallModelMessage,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    turnID: ChatTurnRecord.ID? = nil
  ) {
    self.init(
      id: id,
      payload: .toolCall(
        ToolCallMessagePayload(
          toolCall: toolCall,
          attachments: attachments,
          generationMetrics: generationMetrics
        )
      ),
      turnID: turnID
    )
  }

  init(
    id: UUID = UUID(),
    toolResult: ToolResultModelMessage,
    turnID: ChatTurnRecord.ID? = nil
  ) {
    self.init(id: id, payload: .toolResult(toolResult), turnID: turnID)
  }
}

nonisolated enum ChatMessagePayload: Equatable, Sendable {
  case user(UserMessagePayload)
  case assistant(AssistantMessagePayload)
  case system(SystemMessagePayload)
  case toolCall(ToolCallMessagePayload)
  case toolResult(ToolResultModelMessage)
}

extension ChatMessagePayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case user
    case assistant
    case system
    case toolCall
    case toolResult
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(MessageKind.self, forKey: .kind)

    switch kind {
    case .user:
      self = .user(try container.decode(UserMessagePayload.self, forKey: .user))
    case .assistant:
      self = .assistant(
        try container.decode(AssistantMessagePayload.self, forKey: .assistant)
      )
    case .system:
      self = .system(try container.decode(SystemMessagePayload.self, forKey: .system))
    case .toolCall:
      self = .toolCall(try container.decode(ToolCallMessagePayload.self, forKey: .toolCall))
    case .toolResult:
      self = .toolResult(try container.decode(ToolResultModelMessage.self, forKey: .toolResult))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)

    switch self {
    case .user(let payload):
      try container.encode(payload, forKey: .user)
    case .assistant(let payload):
      try container.encode(payload, forKey: .assistant)
    case .system(let payload):
      try container.encode(payload, forKey: .system)
    case .toolCall(let payload):
      try container.encode(payload, forKey: .toolCall)
    case .toolResult(let payload):
      try container.encode(payload, forKey: .toolResult)
    }
  }
}

nonisolated struct UserMessagePayload: Codable, Equatable, Sendable {
  let content: String
  let attachments: [ChatAttachment]

  init(content: String, attachments: [ChatAttachment] = []) {
    self.content = content
    self.attachments = attachments
  }
}

nonisolated struct AssistantMessagePayload: Codable, Equatable, Sendable {
  let content: String
  let attachments: [ChatAttachment]
  let generationMetrics: ChatGenerationMetrics?
  let deliveryStatus: ChatMessageDeliveryStatus

  init(
    content: String,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    deliveryStatus: ChatMessageDeliveryStatus = .complete
  ) {
    self.content = content
    self.attachments = attachments
    self.generationMetrics = generationMetrics
    self.deliveryStatus = deliveryStatus
  }
}

nonisolated struct SystemMessagePayload: Codable, Equatable, Sendable {
  let content: String
}

nonisolated struct ToolCallMessagePayload: Codable, Equatable, Sendable {
  let toolCall: ToolCallModelMessage
  let attachments: [ChatAttachment]
  let generationMetrics: ChatGenerationMetrics?

  init(
    toolCall: ToolCallModelMessage,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil
  ) {
    self.toolCall = toolCall
    self.attachments = attachments
    self.generationMetrics = generationMetrics
  }
}

nonisolated extension ChatMessage {
  var kind: MessageKind {
    payload.kind
  }

  var content: String {
    switch payload {
    case .user(let payload):
      payload.content
    case .assistant(let payload):
      payload.content
    case .system(let payload):
      payload.content
    case .toolCall, .toolResult:
      ""
    }
  }

  var attachments: [ChatAttachment] {
    switch payload {
    case .user(let payload):
      payload.attachments
    case .assistant(let payload):
      payload.attachments
    case .toolCall(let payload):
      payload.attachments
    case .system, .toolResult:
      []
    }
  }

  var generationMetrics: ChatGenerationMetrics? {
    switch payload {
    case .assistant(let payload):
      payload.generationMetrics
    case .toolCall(let payload):
      payload.generationMetrics
    case .user, .system, .toolResult:
      nil
    }
  }

  var toolCall: ToolCallModelMessage? {
    if case .toolCall(let payload) = payload {
      return payload.toolCall
    }
    return nil
  }

  var toolResult: ToolResultModelMessage? {
    if case .toolResult(let payload) = payload {
      return payload
    }
    return nil
  }

  var deliveryStatus: ChatMessageDeliveryStatus {
    if case .assistant(let payload) = payload {
      return payload.deliveryStatus
    }
    return .complete
  }
}

nonisolated extension ChatMessagePayload {
  var kind: MessageKind {
    switch self {
    case .user:
      .user
    case .assistant:
      .assistant
    case .system:
      .system
    case .toolCall:
      .toolCall
    case .toolResult:
      .toolResult
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

}
