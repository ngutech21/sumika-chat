import Foundation

public enum ChatModelContextBackfill {
  public static func messages(from transcriptMessages: [ChatMessage]) -> [ChatModelContextMessage] {
    transcriptMessages.compactMap { message in
      switch message.payload {
      case .user(let payload):
        guard !payload.content.isEmpty else { return nil }
        return ChatModelContextMessage(
          turnID: message.turnID,
          sourceMessageID: message.id,
          role: .user,
          content: payload.content,
          attachments: payload.attachments
        )
      case .assistant(let payload):
        guard !payload.content.isEmpty else { return nil }
        return ChatModelContextMessage(
          turnID: message.turnID,
          sourceMessageID: message.id,
          role: .assistant,
          content: payload.content,
          attachments: payload.attachments
        )
      case .system(let payload):
        guard !payload.content.isEmpty else { return nil }
        return ChatModelContextMessage(
          turnID: message.turnID,
          sourceMessageID: message.id,
          role: .system,
          content: payload.content
        )
      case .toolCall(let payload):
        guard payload.toolCall.toolName != .invalid else { return nil }
        return ChatModelContextMessage(
          turnID: message.turnID,
          sourceMessageID: message.id,
          role: payload.toolCall.modelContextRole,
          content: payload.toolCall.modelContextContent,
          attachments: payload.attachments
        )
      case .toolResult(let payload):
        return ChatModelContextMessage(
          turnID: message.turnID,
          sourceMessageID: message.id,
          role: payload.modelContextRole,
          content: payload.modelContextContent
        )
      }
    }
  }
}
