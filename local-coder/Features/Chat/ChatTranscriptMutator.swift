import Foundation

nonisolated struct ChatTranscriptMutator: Sendable {
  func appendUserMessage(
    _ content: String,
    id: ChatMessage.ID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    attachments: [ChatAttachment],
    to state: inout ChatSessionState
  ) {
    state.messages.append(
      ChatMessage(id: id, kind: .user, content: content, attachments: attachments, turnID: turnID))
  }

  func appendAssistantPlaceholder(
    id: ChatMessage.ID,
    turnID: ChatTurnRecord.ID? = nil,
    to state: inout ChatSessionState
  ) {
    state.messages.append(
      ChatMessage(id: id, kind: .assistant, content: "", turnID: turnID, deliveryStatus: .streaming)
    )
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
        toolResult: message.toolResult,
        turnID: message.turnID,
        deliveryStatus: message.deliveryStatus
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
        toolResult: message.toolResult,
        turnID: message.turnID,
        deliveryStatus: message.deliveryStatus
      )
    }
  }

  func updateDeliveryStatus(
    _ status: ChatMessageDeliveryStatus,
    for messageID: ChatMessage.ID,
    in state: inout ChatSessionState
  ) {
    updateMessage(messageID, in: &state) { message in
      ChatMessage(
        id: message.id,
        kind: message.kind,
        content: message.content,
        attachments: message.attachments,
        generationMetrics: message.generationMetrics,
        toolCall: message.toolCall,
        toolResult: message.toolResult,
        turnID: message.turnID,
        deliveryStatus: status
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
        toolResult: nil,
        turnID: message.turnID,
        deliveryStatus: .complete
      )
    }
  }

  func appendToolResult(
    _ toolResult: ToolResultModelMessage,
    id: ChatMessage.ID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    to state: inout ChatSessionState
  ) {
    state.messages.append(
      ChatMessage(id: id, kind: .toolResult, content: "", toolResult: toolResult, turnID: turnID))
  }

  func removeMessage(id: UUID, from state: inout ChatSessionState) {
    state.messages.removeAll { $0.id == id }
  }

  func removeTransientAssistantPlaceholders(from state: inout ChatSessionState) {
    let removedMessageIDs = Set(
      state.messages.compactMap { message -> ChatMessage.ID? in
        guard
          message.kind == .assistant
            && message.content.isEmpty
            && message.deliveryStatus == .streaming
        else {
          return nil
        }
        return message.id
      }
    )

    guard !removedMessageIDs.isEmpty else {
      return
    }

    state.messages.removeAll { message in
      removedMessageIDs.contains(message.id)
    }

    for index in state.turns.indices {
      let messageIDs = state.turns[index].messageIDs.filter { !removedMessageIDs.contains($0) }
      guard messageIDs != state.turns[index].messageIDs else {
        continue
      }

      state.turns[index].messageIDs = messageIDs
      state.turns[index].updatedAt = Date()
    }
  }

  func markStreamingAssistantMessagesCancelled(
    inTurn turnID: ChatTurnRecord.ID,
    in state: inout ChatSessionState
  ) {
    let messageIDs = state.messages.compactMap { message -> ChatMessage.ID? in
      guard
        message.turnID == turnID
          && message.kind == .assistant
          && message.deliveryStatus == .streaming
          && !message.content.isEmpty
      else {
        return nil
      }
      return message.id
    }

    for messageID in messageIDs {
      updateDeliveryStatus(.cancelled, for: messageID, in: &state)
    }
  }

  func clearTranscript(in state: inout ChatSessionState) {
    state.messages.removeAll()
    state.toolCalls.removeAll()
    state.turns.removeAll()
    state.attachments.removeAll()
  }

  func appendTurn(_ turn: ChatTurnRecord, to state: inout ChatSessionState) {
    state.turns.append(turn)
  }

  func appendMessageID(
    _ messageID: ChatMessage.ID,
    toTurn turnID: ChatTurnRecord.ID,
    in state: inout ChatSessionState
  ) {
    updateTurn(turnID, in: &state) { turn in
      guard !turn.messageIDs.contains(messageID) else {
        return turn
      }
      var updatedTurn = turn
      updatedTurn.messageIDs.append(messageID)
      updatedTurn.updatedAt = Date()
      return updatedTurn
    }
  }

  func appendToolCallID(
    _ toolCallID: ToolCallRecord.ID,
    toTurn turnID: ChatTurnRecord.ID,
    in state: inout ChatSessionState
  ) {
    updateTurn(turnID, in: &state) { turn in
      guard !turn.toolCallIDs.contains(toolCallID) else {
        return turn
      }
      var updatedTurn = turn
      updatedTurn.toolCallIDs.append(toolCallID)
      updatedTurn.updatedAt = Date()
      return updatedTurn
    }
  }

  func updateTurnStatus(
    _ status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy? = nil,
    for turnID: ChatTurnRecord.ID,
    in state: inout ChatSessionState
  ) {
    updateTurn(turnID, in: &state) { turn in
      var updatedTurn = turn
      updatedTurn.status = status
      if let modelContextPolicy {
        updatedTurn.modelContextPolicy = modelContextPolicy
      }
      updatedTurn.updatedAt = Date()
      return updatedTurn
    }
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

  private func updateTurn(
    _ turnID: ChatTurnRecord.ID,
    in state: inout ChatSessionState,
    transform: (ChatTurnRecord) -> ChatTurnRecord
  ) {
    guard let index = state.turns.firstIndex(where: { $0.id == turnID }) else {
      return
    }

    state.turns[index] = transform(state.turns[index])
  }
}
