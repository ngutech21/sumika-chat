import Foundation

public struct ChatTranscriptMutator: Sendable {
  public init() {}

  public func appendUserMessage(
    _ content: String,
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    attachments: [ChatAttachment],
    to state: inout ChatSession
  ) {
    appendItem(
      .userMessage(UserTurnMessage(id: id, content: content, attachments: attachments)),
      toTurn: turnID,
      in: &state
    )
  }

  public func appendModelContextEntry(
    _ entry: ModelContextEntry,
    to state: inout ChatSession
  ) {
    state.modelContextSnapshot.entries.append(entry)
  }

  public func appendFinalToolResultFollowUpBoundary(
    _ content: String,
    turnID: ChatTurn.ID,
    to state: inout ChatSession
  ) {
    guard
      let terminalIndex = state.modelContextSnapshot.entries.lastIndex(where: { entry in
        guard entry.turnID == turnID else {
          return false
        }
        if case .terminalToolResult = entry.body {
          return true
        }
        return false
      })
    else {
      if let entry = try? ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: content
      ) {
        appendModelContextEntry(entry, to: &state)
      }
      return
    }

    let terminalEntry = state.modelContextSnapshot.entries[terminalIndex]
    guard case .terminalToolResult(let context) = terminalEntry.body,
      let followUpEntry = try? ModelFacingPromptRenderer.finalToolResultPromptEntry(
        id: terminalEntry.id,
        turnID: terminalEntry.turnID,
        sourceMessageID: terminalEntry.sourceMessageID,
        terminalToolResult: context,
        followUpInstruction: content,
        originalUserRequest: terminalEntry.turnID.flatMap {
          state.modelContextSnapshot.originalUserPromptText(forTurn: $0)
        }
      )
    else {
      return
    }

    state.modelContextSnapshot.entries[terminalIndex] = followUpEntry
  }

  public func appendAssistantPlaceholder(
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

  public func appendAssistantMessage(
    _ content: String,
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSession
  ) {
    appendItem(
      .assistantMessage(
        AssistantTurnMessage(id: id, content: content, deliveryStatus: .complete)
      ),
      toTurn: turnID,
      in: &state
    )
  }

  public func appendAssistantThinkingPlaceholder(
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

  public func appendChunk(_ chunk: String, to messageID: UUID, in state: inout ChatSession) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.appendAssistantChunk(chunk, to: messageID)
    }
  }

  public func appendThinkingChunk(
    _ chunk: String,
    to messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.appendAssistantThinkingChunk(chunk, to: messageID)
    }
  }

  public func updateGenerationMetrics(
    _ metrics: ChatGenerationMetrics?,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.updateAssistantGenerationMetrics(metrics, for: messageID)
    }
  }

  public func updateDeliveryStatus(
    _ status: AssistantTurnMessage.DeliveryStatus,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.updateAssistantDeliveryStatus(status, for: messageID)
    }
  }

  public func updateThinkingDeliveryStatus(
    _ status: AssistantThinkingMessage.DeliveryStatus,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateTurn(containingMessageID: messageID, in: &state) { turn in
      turn.updateAssistantThinkingDeliveryStatus(status, for: messageID)
    }
  }

  public func annotateToolCall(
    _ toolCall: ToolCallModelMessage,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    redactModelFacingToolCallPayloadIfNeeded(toolCall, sourceMessageID: messageID, in: &state)
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

  public func appendToolResult(
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

  public func recordToolCall(
    _ record: ToolCallRecord,
    turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    updateTurn(turnID, in: &state) { turn in
      turn.recordToolCall(record)
    }
  }

  public func updateToolCallRecord(
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

  public func removeMessage(id _: UUID, from _: inout ChatSession) {
    // Transcript items are append-only. Empty cancelled assistant placeholders
    // are filtered by read models instead of being deleted from persisted turns.
  }

  public func removeTransientAssistantPlaceholders(from state: inout ChatSession) {
    for turnID in state.turns.map(\.id) {
      updateTurn(turnID, in: &state) { turn in
        turn.cancelEmptyStreamingAssistantPlaceholders()
      }
    }
  }

  public func markStreamingAssistantMessagesCancelled(
    inTurn turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    updateTurn(turnID, in: &state) { turn in
      turn.markStreamingAssistantMessagesCancelled()
    }
  }

  public func clearTranscript(in state: inout ChatSession) {
    state.modelContextSnapshot.entries.removeAll()
    state.turns.removeAll()
    state.pendingAttachments.removeAll()
    state.focusedFileState = .empty
    state.todoState = nil
  }

  public func appendTurn(_ turn: ChatTurn, to state: inout ChatSession) {
    state.turns.append(turn)
  }

  public func appendItem(
    _ item: ChatTurnItem,
    toTurn turnID: ChatTurn.ID?,
    in state: inout ChatSession
  ) {
    updateTurn(turnID, in: &state) { turn in
      turn.appendItem(item)
    }
  }

  public func updateTurnStatus(
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
      arguments: arguments,
      rawText: toolCall.rawText
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

  private func redactModelFacingToolCallPayloadIfNeeded(
    _ toolCall: ToolCallModelMessage,
    sourceMessageID: UUID,
    in state: inout ChatSession
  ) {
    guard toolCall.shouldRedactPayloadInModelHistory else {
      return
    }

    for index in state.modelContextSnapshot.entries.indices {
      let entry = state.modelContextSnapshot.entries[index]
      guard entry.sourceMessageID == sourceMessageID,
        case .assistantOutput(let context) = entry.body
      else {
        continue
      }

      let redactedContent = redactedAssistantOutputContent(context.content, using: toolCall)
      guard redactedContent != context.content,
        let redactedEntry = try? ModelFacingPromptRenderer.assistantOutputEntry(
          id: entry.id,
          turnID: entry.turnID,
          sourceMessageID: entry.sourceMessageID,
          content: redactedContent
        )
      else {
        continue
      }

      state.modelContextSnapshot.entries[index] = redactedEntry
    }
  }

  private func redactedAssistantOutputContent(
    _ content: String,
    using toolCall: ToolCallModelMessage
  ) -> String {
    let redactedToolCall = toolCall.modelContextContent
    guard let rawText = toolCall.rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawText.isEmpty
    else {
      return redactedToolCall
    }

    if content.contains(rawText) {
      return content.replacingOccurrences(of: rawText, with: redactedToolCall)
    }

    return redactedToolCall
  }
}

nonisolated extension ToolCallModelMessage {
  fileprivate var shouldRedactPayloadInModelHistory: Bool {
    toolName == .writeFile || toolName == .editFile
  }
}
