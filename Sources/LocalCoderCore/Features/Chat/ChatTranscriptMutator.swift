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

  public func appendChunk(_ chunk: String, to messageID: UUID, in state: inout ChatSession) {
    appendEvent(
      ChatTurnEvent(
        payload: .assistantChunkAppended(
          AssistantChunkAppendedEvent(messageID: messageID, chunk: chunk)
        )
      ),
      toTurnContainingMessageID: messageID,
      in: &state
    )
  }

  public func updateGenerationMetrics(
    _ metrics: ChatGenerationMetrics?,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    appendEvent(
      ChatTurnEvent(
        payload: .assistantGenerationMetricsUpdated(
          AssistantGenerationMetricsUpdatedEvent(messageID: messageID, metrics: metrics)
        )
      ),
      toTurnContainingMessageID: messageID,
      in: &state
    )
  }

  public func updateDeliveryStatus(
    _ status: AssistantTurnMessage.DeliveryStatus,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    appendEvent(
      ChatTurnEvent(
        payload: .assistantDeliveryStatusUpdated(
          AssistantDeliveryStatusUpdatedEvent(messageID: messageID, status: status)
        )
      ),
      toTurnContainingMessageID: messageID,
      in: &state
    )
  }

  public func replaceAssistantContent(
    _ content: String,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    appendEvent(
      ChatTurnEvent(
        payload: .assistantContentReplaced(
          AssistantContentReplacedEvent(messageID: messageID, content: content)
        )
      ),
      toTurnContainingMessageID: messageID,
      in: &state
    )
  }

  public func annotateToolCall(
    _ toolCall: ToolCallModelMessage,
    for messageID: UUID,
    in state: inout ChatSession
  ) {
    ensureToolCallRecord(for: toolCall, nearMessageID: messageID, in: &state)
    redactModelFacingToolCallPayloadIfNeeded(toolCall, sourceMessageID: messageID, in: &state)
    appendEvent(
      ChatTurnEvent(
        payload: .assistantMessageAnnotatedAsToolCall(
          AssistantToolCallAnnotationEvent(messageID: messageID, toolCallID: toolCall.callID)
        )
      ),
      toTurnContainingMessageID: messageID,
      in: &state
    )
  }

  public func appendToolResult(
    _ toolResult: ToolResultModelMessage,
    turnID: ChatTurn.ID? = nil,
    to state: inout ChatSession
  ) {
    ensureToolCallRecord(for: toolResult, turnID: turnID, in: &state)
    appendEvent(
      ChatTurnEvent(payload: .toolResultAppended(toolResult)),
      toTurn: turnID,
      in: &state
    )
  }

  public func recordToolCall(
    _ record: ToolCallRecord,
    turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    appendEvent(
      ChatTurnEvent(payload: .toolCallRecorded(record)),
      toTurn: turnID,
      in: &state
    )
    guard let turn = state.turns.first(where: { $0.id == turnID }),
      !turn.items.contains(where: { item in
        guard case .toolCall(let id) = item else {
          return false
        }
        return id == record.id
      })
    else {
      return
    }
    appendItem(.toolCall(record.id), toTurn: turnID, in: &state)
  }

  public func updateToolCallRecord(
    _ record: ToolCallRecord,
    in state: inout ChatSession
  ) {
    guard state.toolCalls.contains(where: { $0.id == record.id }) else {
      return
    }
    appendEvent(
      ChatTurnEvent(payload: .toolCallUpdated(record)),
      toTurn: state.turnID(containingToolCall: record.id),
      in: &state
    )
  }

  public func removeMessage(id: UUID, from state: inout ChatSession) {
    appendEvent(
      ChatTurnEvent(payload: .messageRemoved(MessageRemovedEvent(messageID: id))),
      toTurnContainingMessageID: id,
      in: &state
    )
  }

  public func removeTransientAssistantPlaceholders(from state: inout ChatSession) {
    for turnID in state.turns.map(\.id) {
      guard let turn = state.turns.first(where: { $0.id == turnID }),
        turn.items.contains(where: { item in
          guard case .assistantMessage(let message) = item else {
            return false
          }
          return message.content.isEmpty && message.deliveryStatus == .streaming
        })
      else {
        continue
      }
      appendEvent(
        ChatTurnEvent(payload: .transientAssistantPlaceholdersRemoved),
        toTurn: turnID,
        in: &state
      )
    }
  }

  public func markStreamingAssistantMessagesCancelled(
    inTurn turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    appendEvent(
      ChatTurnEvent(payload: .streamingAssistantMessagesCancelled),
      toTurn: turnID,
      in: &state
    )
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
    let event = ChatTurnEvent(payload: .transcriptItemAppended(item))
    guard let turnID else {
      if state.turns.isEmpty {
        state.turns.append(ChatTurn(status: .completed, items: [item]))
      } else {
        state.turns[state.turns.count - 1].appendEvent(event)
      }
      return
    }

    guard state.turns.contains(where: { $0.id == turnID }) else {
      state.turns.append(ChatTurn(id: turnID, status: .completed, items: [item]))
      return
    }

    appendEvent(event, toTurn: turnID, in: &state)
  }

  public func updateTurnStatus(
    _ status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy? = nil,
    for turnID: ChatTurn.ID,
    in state: inout ChatSession
  ) {
    appendEvent(
      ChatTurnEvent(
        payload: .turnStatusChanged(
          TurnStatusChangedEvent(status: status, modelContextPolicy: modelContextPolicy)
        )
      ),
      toTurn: turnID,
      in: &state
    )
  }

  private func ensureToolCallRecord(
    for toolResult: ToolResultModelMessage,
    turnID: ChatTurn.ID?,
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
    appendEvent(
      ChatTurnEvent(
        payload: .toolCallRecorded(
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
      ),
      toTurn: turnID,
      in: &state
    )
  }

  private func ensureToolCallRecord(
    for toolCall: ToolCallModelMessage,
    nearMessageID messageID: UUID,
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
    appendEvent(
      ChatTurnEvent(
        payload: .toolCallRecorded(
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
      ),
      toTurnContainingMessageID: messageID,
      in: &state
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

  private func appendEvent(
    _ event: ChatTurnEvent,
    toTurn turnID: ChatTurn.ID?,
    in state: inout ChatSession
  ) {
    guard let turnID else {
      if state.turns.isEmpty {
        state.turns.append(ChatTurn(events: [event]))
      } else {
        state.turns[state.turns.count - 1].appendEvent(event)
      }
      return
    }

    guard let index = state.turns.firstIndex(where: { $0.id == turnID }) else {
      state.turns.append(ChatTurn(id: turnID, events: [event]))
      return
    }

    state.turns[index].appendEvent(event)
  }

  private func appendEvent(
    _ event: ChatTurnEvent,
    toTurnContainingMessageID messageID: UUID,
    in state: inout ChatSession
  ) {
    let turnID = turnID(containingMessageID: messageID, in: state)
    appendEvent(event, toTurn: turnID, in: &state)
  }

  private func turnID(
    containingMessageID messageID: UUID,
    in state: ChatSession
  ) -> ChatTurn.ID? {
    state.turns.first { turn in
      turn.items.contains { $0.messageID == messageID }
        || turn.events.contains { event in
          event.referencesMessageID(messageID)
        }
    }?.id
  }

}

nonisolated extension ChatTurnEvent {
  fileprivate func referencesMessageID(_ messageID: UUID) -> Bool {
    switch payload {
    case .transcriptItemAppended(let item):
      item.messageID == messageID
    case .assistantChunkAppended(let event):
      event.messageID == messageID
    case .assistantContentReplaced(let event):
      event.messageID == messageID
    case .assistantDeliveryStatusUpdated(let event):
      event.messageID == messageID
    case .assistantGenerationMetricsUpdated(let event):
      event.messageID == messageID
    case .messageRemoved(let event):
      event.messageID == messageID
    case .assistantMessageAnnotatedAsToolCall(let event):
      event.messageID == messageID || event.toolCallID == messageID
    case .toolCallRecorded(let record), .toolCallUpdated(let record):
      record.id == messageID
    case .toolResultAppended(let result):
      result.callID == messageID
    case .transientAssistantPlaceholdersRemoved, .streamingAssistantMessagesCancelled,
      .turnStatusChanged:
      false
    }
  }
}

nonisolated extension ToolCallModelMessage {
  fileprivate var shouldRedactPayloadInModelHistory: Bool {
    toolName == .writeFile || toolName == .editFile
  }
}
