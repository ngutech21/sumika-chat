import Foundation

nonisolated struct ChatTurnRecord: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var status: ChatTurnStatus
  var modelContextPolicy: ChatTurnModelContextPolicy
  var messageIDs: [ChatMessage.ID]
  var toolCallIDs: [ToolCallRecord.ID]
  var createdAt: Date
  var updatedAt: Date

  init(
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

nonisolated enum ChatTurnStatus: String, Codable, Equatable, Sendable {
  case running
  case awaitingApproval
  case completed
  case cancelled
  case failed
}

nonisolated enum ChatTurnModelContextPolicy: String, Codable, Equatable, Sendable {
  case included
  case excluded
}
