import Foundation

public struct ChatModelContextMessage: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let turnID: ChatTurnRecord.ID?
  public let sourceMessageID: ChatMessage.ID?
  public let role: ChatModelContextRole
  public let content: String
  public let attachments: [ChatAttachment]
  public let systemPromptSnapshot: String?

  public init(
    id: UUID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    sourceMessageID: ChatMessage.ID? = nil,
    role: ChatModelContextRole,
    content: String,
    attachments: [ChatAttachment] = [],
    systemPromptSnapshot: String? = nil
  ) {
    self.id = id
    self.turnID = turnID
    self.sourceMessageID = sourceMessageID
    self.role = role
    self.content = content
    self.attachments = attachments
    self.systemPromptSnapshot = systemPromptSnapshot
  }

  public func replacingSystemPromptSnapshot(_ systemPromptSnapshot: String?) -> Self {
    ChatModelContextMessage(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      role: role,
      content: content,
      attachments: attachments,
      systemPromptSnapshot: systemPromptSnapshot
    )
  }
}

public enum ChatModelContextRole: String, Codable, Equatable, Sendable {
  case system
  case user
  case assistant
}
