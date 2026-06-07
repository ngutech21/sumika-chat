import Foundation

public struct ChatTurn: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var status: ChatTurnStatus
  public var modelContextPolicy: ChatTurnModelContextPolicy
  public var items: [ChatTurnItem]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy = .included,
    items: [ChatTurnItem] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.status = status
    self.modelContextPolicy = modelContextPolicy
    self.items = items
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum ChatTurnItem: Codable, Equatable, Sendable {
  case userMessage(UserTurnMessage)
  case assistantMessage(AssistantTurnMessage)
  case toolCall(ToolCallRecord.ID)
  case toolResult(ToolCallRecord.ID)
}

public struct UserTurnMessage: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var attachments: [ChatAttachment]

  public init(
    id: UUID = UUID(),
    content: String,
    attachments: [ChatAttachment] = []
  ) {
    self.id = id
    self.content = content
    self.attachments = attachments
  }
}

public struct AssistantTurnMessage: Codable, Identifiable, Equatable, Sendable {
  public enum DeliveryStatus: String, Codable, Equatable, Sendable {
    case complete
    case streaming
    case cancelled
  }

  public let id: UUID
  public var content: String
  public var attachments: [ChatAttachment]
  public var generationMetrics: ChatGenerationMetrics?
  public var deliveryStatus: DeliveryStatus

  public init(
    id: UUID = UUID(),
    content: String,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    deliveryStatus: DeliveryStatus = .complete
  ) {
    self.id = id
    self.content = content
    self.attachments = attachments
    self.generationMetrics = generationMetrics
    self.deliveryStatus = deliveryStatus
  }
}

public enum ChatTurnStatus: String, Codable, Equatable, Sendable {
  case running
  case awaitingApproval
  case awaitingUserAnswer
  case completed
  case cancelled
  case failed
}

public enum ChatTurnModelContextPolicy: String, Codable, Equatable, Sendable {
  case included
  case excluded
}

nonisolated extension ChatTurnItem {
  public var messageID: UUID? {
    switch self {
    case .userMessage(let message):
      message.id
    case .assistantMessage(let message):
      message.id
    case .toolCall(let id), .toolResult(let id):
      id
    }
  }

  public var userContent: String? {
    guard case .userMessage(let message) = self else {
      return nil
    }
    return message.content
  }
}
