import Foundation

struct ChatTranscriptMutator: Sendable {
  func appendUserMessage(
    _ content: String,
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    attachments: [ChatAttachment],
    promptContext: CurrentPromptContext = .empty(.focusedFileDefault),
    to state: inout ChatSession
  ) {
    appendItem(
      .userMessage(
        UserTurnMessage(
          id: id,
          content: content,
          attachments: attachments,
          promptContext: promptContext
        )),
      toTurn: turnID,
      in: &state
    )
  }

  func appendAssistantPlaceholder(
    id: UUID,
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSession
  ) {
    appendItem(
      .assistantMessage(
        AssistantTurnMessage(id: id, content: "", deliveryStatus: .streaming)
      ),
      toTurn: turnID,
      in: &state
    )
  }

  func updateUserMessagePromptContext(
    _ promptContext: CurrentPromptContext,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.updateUserMessagePromptContext(promptContext, for: messageID)
    }
  }

  func appendAssistantMessage(
    _ content: String,
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    modelProjectionPolicy: AssistantModelProjectionPolicy = .visibleContent,
    to state: inout ChatSession
  ) {
    appendItem(
      .assistantMessage(
        AssistantTurnMessage(
          id: id,
          content: content,
          deliveryStatus: .complete,
          modelProjectionPolicy: modelProjectionPolicy
        )
      ),
      toTurn: turnID,
      in: &state
    )
  }

  func appendAssistantThinkingPlaceholder(
    id: UUID,
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSession
  ) {
    appendItem(
      .assistantThinking(
        AssistantThinkingMessage(id: id, content: "", deliveryStatus: .streaming)
      ),
      toTurn: turnID,
      in: &state
    )
  }

  func appendChunk(_ chunk: String, to messageID: UUID, in state: inout ChatSession) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.appendAssistantChunk(chunk, to: messageID)
    }
  }

  func appendThinkingChunk(
    _ chunk: String,
    to messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.appendAssistantThinkingChunk(chunk, to: messageID)
    }
  }

  func updateGenerationMetrics(
    _ metrics: ChatGenerationMetrics?,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.updateAssistantGenerationMetrics(metrics, for: messageID)
    }
  }

  func updateDeliveryStatus(
    _ status: AssistantTurnMessage.DeliveryStatus,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.updateAssistantDeliveryStatus(status, for: messageID)
    }
  }

  func updateThinkingDeliveryStatus(
    _ status: AssistantThinkingMessage.DeliveryStatus,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.updateAssistantThinkingDeliveryStatus(status, for: messageID)
    }
  }

  func annotateToolCall(
    _ toolCall: ToolCallModelMessage,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    guard let turnID = turnID(containingMessageID: messageID, in: state) else {
      return
    }
    let record =
      state.toolCallRecord(id: toolCall.callID)
      ?? syntheticToolCallRecord(for: toolCall)
    updateTurn(turnID, in: &state) { turn in
      turn.annotateAssistantMessageAsToolCall(messageID: messageID, record: record)
    }
  }

  func appendToolResult(
    _ toolResult: ToolResultModelMessage,
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSession
  ) {
    updateTurn(turnID, in: &state) { turn in
      turn.appendOrUpdateToolResult(
        toolResult,
        fallbackRecord: syntheticToolCallRecord(for: toolResult)
      )
    }
  }

  func recordToolCall(
    _ record: ToolCallRecord,
    turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    updateTurn(turnID, in: &state) { turn in
      turn.recordToolCall(record)
    }
  }

  func updateToolCallRecord(
    _ record: ToolCallRecord,
    in state: inout ChatSession
  ) {
    guard let turnID = state.turnID(containingToolCall: record.id) else {
      return
    }
    updateTurn(turnID, in: &state) { turn in
      turn.updateToolCallRecord(record)
    }
  }

  func removeTransientAssistantPlaceholders(from state: inout ChatSession) {
    for turnID in state.turns.map(\.id) {
      updateTurn(turnID, in: &state) { turn in
        turn.cancelEmptyStreamingAssistantPlaceholders()
      }
    }
  }

  func markStreamingAssistantMessagesCancelled(
    inTurn turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    updateTurn(turnID, in: &state) { turn in
      turn.markStreamingAssistantMessagesCancelled()
    }
  }

  func clearTranscript(in state: inout ChatSession) {
    state.turns.removeAll()
    state.pendingAttachments.removeAll()
    state.focusedFileState = .empty
    state.todoState = nil
  }

  func appendTurn(_ turn: ChatTurn, to state: inout ChatSession) {
    state.turns.append(turn)
  }

  func appendItem(
    _ item: ChatTurnItem,
    toTurn turnID: ChatTurn.ID?,
    in state: inout ChatSession
  ) {
    updateTurn(turnID, in: &state) { turn in
      turn.appendItem(item)
    }
  }

  func updateTurnStatus(
    _ status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy? = nil,
    for turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    updateTurn(turnID, status: status, modelContextPolicy: modelContextPolicy, in: &state) {
      turn in
      turn.updateStatus(status, modelContextPolicy: modelContextPolicy)
    }
  }

  private func updateTurn(
    _ turnID: ChatTurn.ID?,
    status: ChatTurnStatus = .completed,
    modelContextPolicy: ChatTurnModelContextPolicy? = nil,
    in state: inout ChatSession,
    update: (inout ChatTurn) -> Void
  ) {
    guard let turnID else {
      if state.turns.isEmpty {
        state.turns.append(
          ChatTurn(status: status, modelContextPolicy: modelContextPolicy ?? .included))
      }
      update(&state.turns[state.turns.count - 1])
      return
    }

    guard let index = state.turns.firstIndex(where: { $0.id == turnID }) else {
      state.turns.append(
        ChatTurn(id: turnID, status: status, modelContextPolicy: modelContextPolicy ?? .included))
      update(&state.turns[state.turns.count - 1])
      return
    }

    update(&state.turns[index])
  }

  private func updateTurn(
    containingMessageID messageID: UUID,
    in state: inout ChatSession,
    update: (inout ChatTurn) -> Void
  ) {
    guard let turnID = turnID(containingMessageID: messageID, in: state) else {
      return
    }
    updateTurn(turnID, in: &state, update: update)
  }

  private func turnID(
    containingMessageID messageID: UUID,
    in state: ChatSession
  ) -> ChatTurn.ID? {
    state.turns.first { turn in
      turn.containsMessage(id: messageID)
    }?.id
  }

  private func syntheticToolCallRecord(for toolResult: ToolResultModelMessage) -> ToolCallRecord {
    let raw = RawToolCallRequest(
      id: toolResult.callID,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolResult.toolName
    )
    let request = ToolCallRequest.invalid(
      raw: raw,
      input: InvalidToolInput(
        originalName: toolResult.toolName.rawValue,
        rawArguments: [:],
        reason: .parserError("Tool result was recorded without a matching tool call request.")
      )
    )
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Synthetic record for an already completed tool result.",
        riskLevel: .low
      ),
      state: toolResult.completedState
    )
  }

  private func syntheticToolCallRecord(for toolCall: ToolCallModelMessage) -> ToolCallRecord {
    let arguments = Dictionary(
      uniqueKeysWithValues: toolCall.arguments.map { argument in
        (argument.name, ToolArgumentValue.string(argument.value))
      }
    )
    let raw = RawToolCallRequest(
      id: toolCall.callID,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolCall.toolName,
      arguments: arguments
    )
    let request = ToolCallRequest.invalid(
      raw: raw,
      input: InvalidToolInput(
        originalName: toolCall.toolName.rawValue,
        rawArguments: arguments,
        reason: .parserError("Tool call was displayed without a matching validated request.")
      )
    )
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Synthetic record for an already parsed tool call.",
        riskLevel: .low
      ),
      state: .pending
    )
  }
}
