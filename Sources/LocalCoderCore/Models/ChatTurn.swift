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
  case userMessage(ChatMessage)
  case assistantMessage(ChatMessage)
  case toolCall(ToolCallRecord.ID)
  case toolResult(ToolCallRecord.ID)
}

public enum ChatTurnStatus: String, Codable, Equatable, Sendable {
  case running
  case awaitingApproval
  case completed
  case cancelled
  case failed
}

public enum ChatTurnModelContextPolicy: String, Codable, Equatable, Sendable {
  case included
  case excluded
}
