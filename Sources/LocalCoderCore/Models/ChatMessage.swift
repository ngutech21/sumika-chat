import Foundation

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let payload: ChatMessagePayload

  public init(
    id: UUID = UUID(),
    payload: ChatMessagePayload,
    turnID _: ChatTurnRecord.ID? = nil
  ) {
    self.id = id
    self.payload = payload
  }

  public init(
    id: UUID = UUID(),
    userContent content: String,
    attachments: [ChatAttachment] = [],
    turnID _: ChatTurnRecord.ID? = nil
  ) {
    self.init(
      id: id,
      payload: .user(UserMessagePayload(content: content, attachments: attachments))
    )
  }

  public init(
    id: UUID = UUID(),
    assistantContent content: String,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    deliveryStatus: ChatMessageDeliveryStatus = .complete,
    turnID _: ChatTurnRecord.ID? = nil
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
      )
    )
  }

  public init(
    id: UUID = UUID(),
    systemContent content: String,
    turnID _: ChatTurnRecord.ID? = nil
  ) {
    self.init(id: id, payload: .system(SystemMessagePayload(content: content)))
  }

  public init(
    id: UUID = UUID(),
    toolCall: ToolCallModelMessage,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    turnID _: ChatTurnRecord.ID? = nil
  ) {
    self.init(
      id: id,
      payload: .toolCall(
        ToolCallMessagePayload(
          toolCall: toolCall,
          attachments: attachments,
          generationMetrics: generationMetrics
        )
      )
    )
  }

  public init(
    id: UUID = UUID(),
    toolResult: ToolResultModelMessage,
    turnID _: ChatTurnRecord.ID? = nil
  ) {
    self.init(id: id, payload: .toolResult(toolResult))
  }
}

public enum ChatMessagePayload: Equatable, Sendable {
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

  public init(from decoder: Decoder) throws {
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

  public func encode(to encoder: Encoder) throws {
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

public struct UserMessagePayload: Codable, Equatable, Sendable {
  public let content: String
  public let attachments: [ChatAttachment]

  public init(content: String, attachments: [ChatAttachment] = []) {
    self.content = content
    self.attachments = attachments
  }
}

public struct AssistantMessagePayload: Codable, Equatable, Sendable {
  public let content: String
  public let attachments: [ChatAttachment]
  public let generationMetrics: ChatGenerationMetrics?
  public let deliveryStatus: ChatMessageDeliveryStatus

  public init(
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

public struct SystemMessagePayload: Codable, Equatable, Sendable {
  public let content: String
}

public struct ToolCallMessagePayload: Codable, Equatable, Sendable {
  public let toolCall: ToolCallModelMessage
  public let attachments: [ChatAttachment]
  public let generationMetrics: ChatGenerationMetrics?

  public init(
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
  public var kind: MessageKind {
    payload.kind
  }

  public var content: String {
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

  public var attachments: [ChatAttachment] {
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

  public var generationMetrics: ChatGenerationMetrics? {
    switch payload {
    case .assistant(let payload):
      payload.generationMetrics
    case .toolCall(let payload):
      payload.generationMetrics
    case .user, .system, .toolResult:
      nil
    }
  }

  public var toolCall: ToolCallModelMessage? {
    if case .toolCall(let payload) = payload {
      return payload.toolCall
    }
    return nil
  }

  public var toolResult: ToolResultModelMessage? {
    if case .toolResult(let payload) = payload {
      return payload
    }
    return nil
  }

  public var deliveryStatus: ChatMessageDeliveryStatus {
    if case .assistant(let payload) = payload {
      return payload.deliveryStatus
    }
    return .complete
  }
}

nonisolated extension ChatMessagePayload {
  public var kind: MessageKind {
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

public struct ChatGenerationMetrics: Codable, Equatable, Sendable {
  public let generatedTokenCount: Int
  public let tokensPerSecond: Double
  public let durationMs: Double?

  public init(generatedTokenCount: Int, tokensPerSecond: Double, durationMs: Double? = nil) {
    self.generatedTokenCount = generatedTokenCount
    self.tokensPerSecond = tokensPerSecond
    self.durationMs = durationMs
  }
}

public enum ChatMessageDeliveryStatus: String, Codable, Equatable, Sendable {
  case complete
  case streaming
  case cancelled
}

nonisolated extension ChatMessage {
  public var containsStreamingToolCallMarkup: Bool {
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

public enum MessageKind: String, Codable, Equatable, Sendable {
  case user
  case assistant
  case toolCall
  case toolResult
  case system

  public var title: String {
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

  public var systemImage: String {
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
