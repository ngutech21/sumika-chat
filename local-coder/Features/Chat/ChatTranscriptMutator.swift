import Foundation

nonisolated struct ChatTranscriptMutator: Sendable {
  func appendUserMessage(
    _ content: String,
    attachments: [ChatAttachment],
    to state: inout ChatSessionState
  ) {
    state.messages.append(
      ChatMessage(kind: .user, content: content, attachments: attachments))
  }

  func appendAssistantPlaceholder(id: UUID, to state: inout ChatSessionState) {
    state.messages.append(ChatMessage(id: id, kind: .assistant, content: ""))
  }

  func appendChunk(_ chunk: String, to messageID: UUID, in state: inout ChatSessionState) {
    updateMessage(messageID, in: &state) { message in
      ChatMessage(
        id: message.id,
        kind: message.kind,
        content: message.content + chunk,
        attachments: message.attachments,
        generationMetrics: message.generationMetrics,
        toolCall: message.toolCall,
        toolResult: message.toolResult
      )
    }
  }

  func updateGenerationMetrics(
    _ metrics: ChatGenerationMetrics?,
    for messageID: UUID,
    in state: inout ChatSessionState
  ) {
    updateMessage(messageID, in: &state) { message in
      ChatMessage(
        id: message.id,
        kind: message.kind,
        content: message.content,
        attachments: message.attachments,
        generationMetrics: metrics,
        toolCall: message.toolCall,
        toolResult: message.toolResult
      )
    }
  }

  func annotateToolCall(
    _ toolCall: ToolCallModelMessage,
    for messageID: UUID,
    in state: inout ChatSessionState
  ) {
    updateMessage(messageID, in: &state) { message in
      ChatMessage(
        id: message.id,
        kind: .toolCall,
        content: "",
        attachments: message.attachments,
        generationMetrics: message.generationMetrics,
        toolCall: toolCall,
        toolResult: nil
      )
    }
  }

  func appendToolResult(_ toolResult: ToolResultModelMessage, to state: inout ChatSessionState) {
    state.messages.append(ChatMessage(kind: .toolResult, content: "", toolResult: toolResult))
  }

  func removeMessage(id: UUID, from state: inout ChatSessionState) {
    state.messages.removeAll { $0.id == id }
  }

  func removeTransientAssistantPlaceholders(from state: inout ChatSessionState) {
    state.messages.removeAll { message in
      message.kind == .assistant
        && message.content.isEmpty
    }
  }

  func clearTranscript(in state: inout ChatSessionState) {
    state.messages.removeAll()
    state.attachments.removeAll()
  }

  private func updateMessage(
    _ messageID: UUID,
    in state: inout ChatSessionState,
    transform: (ChatMessage) -> ChatMessage
  ) {
    guard let index = state.messages.firstIndex(where: { $0.id == messageID }) else {
      return
    }

    state.messages[index] = transform(state.messages[index])
  }
}
