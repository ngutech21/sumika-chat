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

  public func appendModelContextUserBoundary(
    _ content: String,
    turnID: ChatTurn.ID,
    systemPromptSnapshot: String,
    to state: inout ChatSession
  ) {
    if let entry = try? ModelFacingPromptRenderer.userPromptEntry(
      turnID: turnID,
      prompt: content,
      systemContext: [systemPromptSnapshot]
    ) {
      appendModelContextEntry(entry, to: &state)
    }
  }

  public func appendFinalToolResultFollowUpBoundary(
    _ content: String,
    turnID: ChatTurn.ID,
    systemPromptSnapshot: String,
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
        prompt: content,
        systemContext: [systemPromptSnapshot]
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
        systemContext: [systemPromptSnapshot]
      )
    else {
      return
    }

    state.modelContextSnapshot.entries[terminalIndex] = followUpEntry
  }

  public func updateLastUserModelContextSystemPromptSnapshot(
    _ systemPromptSnapshot: String,
    turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    updateLastUserModelContextEntrySystemPromptSnapshot(
      systemPromptSnapshot,
      turnID: turnID,
      in: &state
    )
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

  public func appendChunk(_ chunk: String, to messageID: UUID, in state: inout ChatSession) {
    updateAssistantMessage(messageID, in: &state) { message in
      var updatedMessage = message
      updatedMessage.content += chunk
      return updatedMessage
    }
  }

  public func updateGenerationMetrics(
    _ metrics: ChatGenerationMetrics?,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateAssistantMessage(messageID, in: &state) { message in
      var updatedMessage = message
      updatedMessage.generationMetrics = metrics
      return updatedMessage
    }
  }

  public func updateDeliveryStatus(
    _ status: AssistantTurnMessage.DeliveryStatus,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateAssistantMessage(messageID, in: &state) { message in
      var updatedMessage = message
      updatedMessage.deliveryStatus = status
      return updatedMessage
    }
  }

  public func replaceAssistantContent(
    _ content: String,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    updateAssistantMessage(messageID, in: &state) { message in
      var updatedMessage = message
      updatedMessage.content = content
      updatedMessage.deliveryStatus = .complete
      return updatedMessage
    }
  }

  public func annotateToolCall(
    _ toolCall: ToolCallModelMessage,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    ensureToolCallRecord(for: toolCall, in: &state)
    replaceItem(matchingMessageID: messageID, with: .toolCall(toolCall.callID), in: &state)
    guard toolCall.omitsPayloadFromModelHistory else {
      return
    }
    replaceAssistantModelContextEntry(
      sourceMessageID: messageID,
      content: toolCall.modelContextContent,
      in: &state
    )
  }

  public func appendToolResult(
    _ toolResult: ToolResultModelMessage,
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSession
  ) {
    ensureToolCallRecord(for: toolResult, in: &state)
    appendItem(.toolResult(toolResult.callID), toTurn: turnID, in: &state)
  }

  public func removeMessage(id: UUID, from state: inout ChatSession) {
    removeItems(matchingMessageID: id, from: &state)
  }

  public func removeTransientAssistantPlaceholders(from state: inout ChatSession) {
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
    in state: inout ChatSession
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
        var updatedMessage = message
        updatedMessage.deliveryStatus = .cancelled
        return .assistantMessage(updatedMessage)
      }
      updatedTurn.updatedAt = Date()
      return updatedTurn
    }
  }

  public func clearTranscript(in state: inout ChatSession) {
    state.modelContextSnapshot.entries.removeAll()
    state.toolCalls.removeAll()
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
    in state: inout ChatSession
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

  private func updateAssistantMessage(
    _ messageID: UUID,
    in state: inout ChatSession,
    transform: (AssistantTurnMessage) -> AssistantTurnMessage
  ) {
    for turnIndex in state.turns.indices {
      for itemIndex in state.turns[turnIndex].items.indices {
        switch state.turns[turnIndex].items[itemIndex] {
        case .assistantMessage(let message) where message.id == messageID:
          state.turns[turnIndex].items[itemIndex] = .assistantMessage(transform(message))
          state.turns[turnIndex].updatedAt = Date()
          return
        case .toolCall, .toolResult, .userMessage, .assistantMessage:
          continue
        }
      }
    }
  }

  private func replaceItem(
    matchingMessageID messageID: UUID,
    with replacement: ChatTurnItem,
    in state: inout ChatSession
  ) {
    for turnIndex in state.turns.indices {
      for itemIndex in state.turns[turnIndex].items.indices {
        guard state.turns[turnIndex].items[itemIndex].messageID == messageID else {
          continue
        }
        state.turns[turnIndex].items[itemIndex] = replacement
        state.turns[turnIndex].updatedAt = Date()
        return
      }
    }
  }

  private func replaceAssistantModelContextEntry(
    sourceMessageID: UUID,
    content: String,
    in state: inout ChatSession
  ) {
    guard
      let index = state.modelContextSnapshot.entries.lastIndex(where: { entry in
        entry.sourceMessageID == sourceMessageID && entry.body.modelRole == .assistant
      }),
      let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        id: state.modelContextSnapshot.entries[index].id,
        turnID: state.modelContextSnapshot.entries[index].turnID,
        sourceMessageID: sourceMessageID,
        content: content
      )
    else {
      return
    }

    state.modelContextSnapshot.entries[index] = entry
  }

  private func removeItems(matchingMessageID messageID: UUID, from state: inout ChatSession) {
    for turnIndex in state.turns.indices {
      let originalCount = state.turns[turnIndex].items.count
      state.turns[turnIndex].items.removeAll { item in
        switch item {
        case .userMessage(let message):
          message.id == messageID
        case .assistantMessage(let message):
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
    in state: inout ChatSession
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
    in state: inout ChatSession
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
    in state: inout ChatSession,
    transform: (ChatTurn) -> ChatTurn
  ) {
    guard let index = state.turns.firstIndex(where: { $0.id == turnID }) else {
      return
    }

    state.turns[index] = transform(state.turns[index])
  }

  private func updateLastUserModelContextEntrySystemPromptSnapshot(
    _ systemPromptSnapshot: String,
    turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    guard
      let index = state.modelContextSnapshot.entries.lastIndex(where: { entry in
        entry.turnID == turnID && entry.body.modelRole == .user
      })
    else {
      return
    }

    let entry = state.modelContextSnapshot.entries[index]
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
      state.modelContextSnapshot.entries[index] = updatedEntry
    }
  }
}

extension ToolCallModelMessage {
  fileprivate var omitsPayloadFromModelHistory: Bool {
    toolName == .writeFile || toolName == .editFile || toolName == .todoWrite
  }
}
