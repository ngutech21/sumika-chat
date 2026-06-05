import Foundation

public struct ChatTranscriptMutator: Sendable {
  public init() {}

  public func appendUserMessage(
    _ content: String,
    id: ChatMessage.ID = UUID(),
    turnID: ChatTurn.ID? = nil,
    attachments: [ChatAttachment],
    to state: inout ChatSessionState
  ) {
    appendItem(
      .userMessage(ChatMessage(id: id, userContent: content, attachments: attachments)),
      toTurn: turnID,
      in: &state
    )
  }

  public func appendModelFacingEntry(
    _ entry: ModelContextEntry,
    to state: inout ChatSessionState
  ) {
    state.modelFacingTranscript.entries.append(entry)
  }

  public func appendModelContextUserBoundary(
    _ content: String,
    turnID: ChatTurn.ID,
    systemPromptSnapshot: String,
    to state: inout ChatSessionState
  ) {
    if let entry = try? ModelFacingPromptRenderer.userPromptEntry(
      turnID: turnID,
      prompt: content,
      systemContext: [systemPromptSnapshot]
    ) {
      appendModelFacingEntry(entry, to: &state)
    }
  }

  public func appendFinalToolResultFollowUpBoundary(
    _ content: String,
    turnID: ChatTurn.ID,
    systemPromptSnapshot: String,
    to state: inout ChatSessionState
  ) {
    guard
      let terminalIndex = state.modelFacingTranscript.entries.lastIndex(where: { entry in
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
        prompt: content,
        systemContext: [systemPromptSnapshot]
      ) {
        appendModelFacingEntry(entry, to: &state)
      }
      return
    }

    let terminalEntry = state.modelFacingTranscript.entries[terminalIndex]
    guard case .terminalToolResult(let context) = terminalEntry.body,
      let followUpEntry = try? ModelFacingPromptRenderer.finalToolResultPromptEntry(
        id: terminalEntry.id,
        turnID: terminalEntry.turnID,
        sourceMessageID: terminalEntry.sourceMessageID,
        terminalToolResult: context,
        followUpInstruction: content,
        systemContext: [systemPromptSnapshot]
      )
    else {
      return
    }

    state.modelFacingTranscript.entries[terminalIndex] = followUpEntry
  }

  public func updateLastUserModelContextSystemPromptSnapshot(
    _ systemPromptSnapshot: String,
    turnID: ChatTurn.ID,
    in state: inout ChatSessionState
  ) {
    updateLastUserModelFacingEntrySystemPromptSnapshot(
      systemPromptSnapshot,
      turnID: turnID,
      in: &state
    )
  }

  public func appendAssistantPlaceholder(
    id: ChatMessage.ID,
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSessionState
  ) {
    appendItem(
      .assistantMessage(
        ChatMessage(id: id, assistantContent: "", deliveryStatus: .streaming)
      ),
      toTurn: turnID,
      in: &state
    )
  }

  public func appendAssistantMessage(
    _ content: String,
    id: ChatMessage.ID = UUID(),
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSessionState
  ) {
    appendItem(
      .assistantMessage(
        ChatMessage(id: id, assistantContent: content, deliveryStatus: .complete)
      ),
      toTurn: turnID,
      in: &state
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
        deliveryStatus: .complete
      )
    }
  }

  public func annotateToolCall(
    _ toolCall: ToolCallModelMessage,
    for messageID: UUID,
    in state: inout ChatSessionState
  ) {
    ensureToolCallRecord(for: toolCall, in: &state)
    updateMessage(messageID, in: &state) { message in
      _ = message
      return ChatMessage(id: toolCall.callID, toolCall: toolCall)
    }
  }

  public func appendToolResult(
    _ toolResult: ToolResultModelMessage,
    id: ChatMessage.ID = UUID(),
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSessionState
  ) {
    _ = id
    ensureToolCallRecord(for: toolResult, in: &state)
    appendItem(.toolResult(toolResult.callID), toTurn: turnID, in: &state)
  }

  public func removeMessage(id: UUID, from state: inout ChatSessionState) {
    removeItems(matchingMessageID: id, from: &state)
  }

  public func removeTransientAssistantPlaceholders(from state: inout ChatSessionState) {
    for index in state.turns.indices {
      let originalCount = state.turns[index].items.count
      state.turns[index].items.removeAll { item in
        guard case .assistantMessage(let message) = item else {
          return false
        }
        return message.content.isEmpty && message.deliveryStatus == .streaming
      }
      if state.turns[index].items.count != originalCount {
        state.turns[index].updatedAt = Date()
      }
    }
  }

  public func markStreamingAssistantMessagesCancelled(
    inTurn turnID: ChatTurn.ID,
    in state: inout ChatSessionState
  ) {
    updateTurn(turnID, in: &state) { turn in
      var updatedTurn = turn
      updatedTurn.items = turn.items.map { item in
        guard case .assistantMessage(let message) = item,
          message.deliveryStatus == .streaming,
          !message.content.isEmpty
        else {
          return item
        }
        return .assistantMessage(message.replacingDeliveryStatus(.cancelled))
      }
      updatedTurn.updatedAt = Date()
      return updatedTurn
    }
  }

  public func clearTranscript(in state: inout ChatSessionState) {
    state.modelFacingTranscript.entries.removeAll()
    state.toolCalls.removeAll()
    state.turns.removeAll()
    state.pendingAttachments.removeAll()
    state.focusedFileState = .empty
  }

  public func appendTurn(_ turn: ChatTurn, to state: inout ChatSessionState) {
    state.turns.append(turn)
  }

  public func appendItem(
    _ item: ChatTurnItem,
    toTurn turnID: ChatTurn.ID?,
    in state: inout ChatSessionState
  ) {
    guard let turnID else {
      if state.turns.isEmpty {
        state.turns.append(ChatTurn(status: .completed, items: [item]))
      } else {
        state.turns[state.turns.count - 1].items.append(item)
      }
      return
    }

    guard state.turns.contains(where: { $0.id == turnID }) else {
      state.turns.append(ChatTurn(id: turnID, status: .completed, items: [item]))
      return
    }

    updateTurn(turnID, in: &state) { turn in
      var updatedTurn = turn
      updatedTurn.items.append(item)
      updatedTurn.updatedAt = Date()
      return updatedTurn
    }
  }

  public func updateTurnStatus(
    _ status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy? = nil,
    for turnID: ChatTurn.ID,
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
    for turnIndex in state.turns.indices {
      for itemIndex in state.turns[turnIndex].items.indices {
        switch state.turns[turnIndex].items[itemIndex] {
        case .userMessage(let message) where message.id == messageID:
          state.turns[turnIndex].items[itemIndex] = .userMessage(transform(message))
          state.turns[turnIndex].updatedAt = Date()
          return
        case .assistantMessage(let message) where message.id == messageID:
          let updatedMessage = transform(message)
          if updatedMessage.kind == .toolCall, let toolCall = updatedMessage.toolCall {
            state.turns[turnIndex].items[itemIndex] = .toolCall(toolCall.callID)
          } else {
            state.turns[turnIndex].items[itemIndex] = .assistantMessage(updatedMessage)
          }
          state.turns[turnIndex].updatedAt = Date()
          return
        case .toolCall, .toolResult, .userMessage, .assistantMessage:
          continue
        }
      }
    }
  }

  private func removeItems(matchingMessageID messageID: UUID, from state: inout ChatSessionState) {
    for turnIndex in state.turns.indices {
      let originalCount = state.turns[turnIndex].items.count
      state.turns[turnIndex].items.removeAll { item in
        switch item {
        case .userMessage(let message), .assistantMessage(let message):
          message.id == messageID
        case .toolCall(let id), .toolResult(let id):
          id == messageID
        }
      }
      if state.turns[turnIndex].items.count != originalCount {
        state.turns[turnIndex].updatedAt = Date()
      }
    }
  }

  private func ensureToolCallRecord(
    for toolResult: ToolResultModelMessage,
    in state: inout ChatSessionState
  ) {
    guard !state.toolCalls.contains(where: { $0.id == toolResult.callID }) else {
      return
    }
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
    state.toolCalls.append(
      ToolCallRecord(
        request: request,
        evaluation: ToolPermissionEvaluation(
          decision: .allowed,
          reason: "Synthetic record for an already completed tool result.",
          riskLevel: .low
        ),
        state: .completed(toolResult.payload)
      )
    )
  }

  private func ensureToolCallRecord(
    for toolCall: ToolCallModelMessage,
    in state: inout ChatSessionState
  ) {
    guard !state.toolCalls.contains(where: { $0.id == toolCall.callID }) else {
      return
    }
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
    state.toolCalls.append(
      ToolCallRecord(
        request: request,
        evaluation: ToolPermissionEvaluation(
          decision: .allowed,
          reason: "Synthetic record for an already parsed tool call.",
          riskLevel: .low
        ),
        state: .pending
      )
    )
  }

  private func updateTurn(
    _ turnID: ChatTurn.ID,
    in state: inout ChatSessionState,
    transform: (ChatTurn) -> ChatTurn
  ) {
    guard let index = state.turns.firstIndex(where: { $0.id == turnID }) else {
      return
    }

    state.turns[index] = transform(state.turns[index])
  }

  private func updateLastUserModelFacingEntrySystemPromptSnapshot(
    _ systemPromptSnapshot: String,
    turnID: ChatTurn.ID,
    in state: inout ChatSessionState
  ) {
    guard
      let index = state.modelFacingTranscript.entries.lastIndex(where: { entry in
        entry.turnID == turnID && entry.body.modelRole == .user
      })
    else {
      return
    }

    let entry = state.modelFacingTranscript.entries[index]
    let updatedEntry: ModelContextEntry?
    switch entry.body {
    case .userPrompt(let context):
      guard context.systemContext.isEmpty else {
        return
      }
      updatedEntry = try? ModelFacingPromptRenderer.userPromptEntry(
        id: entry.id,
        turnID: entry.turnID,
        sourceMessageID: entry.sourceMessageID,
        prompt: context.prompt,
        systemContext: [systemPromptSnapshot],
        currentPromptContext: context.currentPromptContext
      )
    case .toolObservation(let context):
      updatedEntry = try? ModelContextEntry(
        id: entry.id,
        turnID: entry.turnID,
        sourceMessageID: entry.sourceMessageID,
        body: entry.body,
        frozenContent: FrozenModelContent(
          role: .user,
          content: ModelFacingPromptRenderer.userContent(
            context.content,
            systemContext: [systemPromptSnapshot]
          )
        )
      )
    case .assistantOutput, .terminalToolResult:
      return
    }

    if let updatedEntry {
      state.modelFacingTranscript.entries[index] = updatedEntry
    }
  }
}

nonisolated extension ChatMessage {
  fileprivate func replacingContent(_ content: String) -> ChatMessage {
    switch payload {
    case .user(let payload):
      ChatMessage(
        id: id,
        userContent: content,
        attachments: payload.attachments
      )
    case .assistant(let payload):
      ChatMessage(
        id: id,
        assistantContent: content,
        attachments: payload.attachments,
        generationMetrics: payload.generationMetrics,
        deliveryStatus: payload.deliveryStatus
      )
    case .system:
      ChatMessage(id: id, systemContent: content)
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
        deliveryStatus: payload.deliveryStatus
      )
    case .toolCall(let payload):
      ChatMessage(
        id: id,
        toolCall: payload.toolCall,
        attachments: payload.attachments,
        generationMetrics: metrics
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
      deliveryStatus: status
    )
  }
}
