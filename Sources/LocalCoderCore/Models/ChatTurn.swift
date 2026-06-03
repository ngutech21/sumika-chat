import Foundation

public struct ChatTurnRecord: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var status: ChatTurnStatus
  public var modelContextPolicy: ChatTurnModelContextPolicy
  public var messageIDs: [ChatMessage.ID]
  public var toolCallIDs: [ToolCallRecord.ID]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy = .included,
    messageIDs: [ChatMessage.ID] = [],
    toolCallIDs: [ToolCallRecord.ID] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.status = status
    self.modelContextPolicy = modelContextPolicy
    self.messageIDs = messageIDs
    self.toolCallIDs = toolCallIDs
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
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
