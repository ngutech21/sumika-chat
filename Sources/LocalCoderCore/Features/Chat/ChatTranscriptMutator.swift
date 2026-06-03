import Foundation

public struct ChatTranscriptMutator: Sendable {
  public init() {}

  public func appendUserMessage(
    _ content: String,
    id: ChatMessage.ID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    attachments: [ChatAttachment],
    to state: inout ChatSessionState
  ) {
    state.messages.append(
      ChatMessage(id: id, userContent: content, attachments: attachments, turnID: turnID))
  }

  public func appendAssistantPlaceholder(
    id: ChatMessage.ID,
    turnID: ChatTurnRecord.ID? = nil,
    to state: inout ChatSessionState
  ) {
    state.messages.append(
      ChatMessage(id: id, assistantContent: "", deliveryStatus: .streaming, turnID: turnID)
    )
  }

  public func appendChunk(_ chunk: String, to messageID: UUID, in state: inout ChatSessionState) {
    updateMessage(messageID, in: &state) { message in
      message.replacingContent(message.content + chunk)
    }
  }

  public func updateGenerationMetrics(
    _ metrics: ChatGenerationMetrics?,
    for messageID: UUID,
    in state: inout ChatSessionState
  ) {
    updateMessage(messageID, in: &state) { message in
      message.replacingGenerationMetrics(metrics)
    }
  }

  public func updateDeliveryStatus(
    _ status: ChatMessageDeliveryStatus,
    for messageID: ChatMessage.ID,
    in state: inout ChatSessionState
  ) {
    updateMessage(messageID, in: &state) { message in
      message.replacingDeliveryStatus(status)
    }
  }

  public func replaceAssistantContent(
    _ content: String,
    for messageID: ChatMessage.ID,
    in state: inout ChatSessionState
  ) {
    updateMessage(messageID, in: &state) { message in
      ChatMessage(
        id: message.id,
        assistantContent: content,
        attachments: message.attachments,
        generationMetrics: message.generationMetrics,
        deliveryStatus: .complete,
        turnID: message.turnID
      )
    }
  }

  public func annotateToolCall(
    _ toolCall: ToolCallModelMessage,
    for messageID: UUID,
    in state: inout ChatSessionState
  ) {
    updateMessage(messageID, in: &state) { message in
      ChatMessage(
        id: message.id,
        toolCall: toolCall,
        attachments: message.attachments,
        generationMetrics: message.generationMetrics,
        turnID: message.turnID
      )
    }
  }

  public func appendToolResult(
    _ toolResult: ToolResultModelMessage,
    id: ChatMessage.ID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    to state: inout ChatSessionState
  ) {
    state.messages.append(
      ChatMessage(id: id, toolResult: toolResult, turnID: turnID))
  }

  public func removeMessage(id: UUID, from state: inout ChatSessionState) {
    state.messages.removeAll { $0.id == id }
  }

  public func removeTransientAssistantPlaceholders(from state: inout ChatSessionState) {
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

  public func markStreamingAssistantMessagesCancelled(
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

  public func clearTranscript(in state: inout ChatSessionState) {
    state.messages.removeAll()
    state.toolCalls.removeAll()
    state.turns.removeAll()
    state.attachments.removeAll()
  }

  public func appendTurn(_ turn: ChatTurnRecord, to state: inout ChatSessionState) {
    state.turns.append(turn)
  }

  public func appendMessageID(
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

  public func appendToolCallID(
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

  public func updateTurnStatus(
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

nonisolated extension ChatMessage {
  fileprivate func replacingContent(_ content: String) -> ChatMessage {
    switch payload {
    case .user(let payload):
      ChatMessage(
        id: id,
        userContent: content,
        attachments: payload.attachments,
        turnID: turnID
      )
    case .assistant(let payload):
      ChatMessage(
        id: id,
        assistantContent: content,
        attachments: payload.attachments,
        generationMetrics: payload.generationMetrics,
        deliveryStatus: payload.deliveryStatus,
        turnID: turnID
      )
    case .system:
      ChatMessage(id: id, systemContent: content, turnID: turnID)
    case .toolCall, .toolResult:
      self
    }
  }

  fileprivate func replacingGenerationMetrics(_ metrics: ChatGenerationMetrics?) -> ChatMessage {
    switch payload {
    case .assistant(let payload):
      ChatMessage(
        id: id,
        assistantContent: payload.content,
        attachments: payload.attachments,
        generationMetrics: metrics,
        deliveryStatus: payload.deliveryStatus,
        turnID: turnID
      )
    case .toolCall(let payload):
      ChatMessage(
        id: id,
        toolCall: payload.toolCall,
        attachments: payload.attachments,
        generationMetrics: metrics,
        turnID: turnID
      )
    case .user, .system, .toolResult:
      self
    }
  }

  fileprivate func replacingDeliveryStatus(_ status: ChatMessageDeliveryStatus) -> ChatMessage {
    guard case .assistant(let payload) = payload else {
      return self
    }

    return ChatMessage(
      id: id,
      assistantContent: payload.content,
      attachments: payload.attachments,
      generationMetrics: payload.generationMetrics,
      deliveryStatus: status,
      turnID: turnID
    )
  }
}
