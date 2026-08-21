import Foundation

internal struct ChatModelContextBuilder: Sendable {
  private let focusedFileReusePolicy: FocusedFilePromptReusePolicy

  internal init() {
    focusedFileReusePolicy = .conservative
  }

  init(
    focusedFileReusePolicy: FocusedFilePromptReusePolicy
  ) {
    self.focusedFileReusePolicy = focusedFileReusePolicy
  }

  internal func transcript(
    from state: ChatSession,
    includingTurnID: ChatTurn.ID? = nil,
    supportsHistoricalReasoningPreservation: Bool = false
  ) -> ModelPromptProjection {
    var entries: [ModelContextEntry] = []
    var anchorResetBeforeEntryIDs: Set<ModelContextEntry.ID> = []
    var resetsAnchorBeforeNextProjectedEntry = false
    let workspaceInstructionsProjection = latestWorkspaceInstructionsProjection(in: state)

    for turn in state.turns {
      guard turn.modelContextPolicy != .excluded || turn.id == includingTurnID else {
        resetsAnchorBeforeNextProjectedEntry = true
        continue
      }

      let firstNewEntryIndex = entries.endIndex
      appendEntries(
        for: turn,
        workspaceInstructionsProjection: workspaceInstructionsProjection,
        includesActivatedSkills: state.interactionMode == .agent,
        preservesHistoricalReasoning: supportsHistoricalReasoningPreservation,
        to: &entries
      )
      if resetsAnchorBeforeNextProjectedEntry, firstNewEntryIndex < entries.endIndex {
        anchorResetBeforeEntryIDs.insert(entries[firstNewEntryIndex].id)
        resetsAnchorBeforeNextProjectedEntry = false
      }
    }

    return FocusedFilePromptReusePlanner.apply(
      to: ModelPromptProjection(entries: entries),
      policy: focusedFileReusePolicy,
      anchorResetBeforeEntryIDs: anchorResetBeforeEntryIDs
    )
  }

  private func appendEntries(
    for turn: ChatTurn,
    workspaceInstructionsProjection: WorkspaceInstructionsProjection?,
    includesActivatedSkills: Bool,
    preservesHistoricalReasoning: Bool,
    to entries: inout [ModelContextEntry]
  ) {
    let suppressedToolCallIDs = unresolvedToolCallIDs(in: turn)
    var previousProjectedItemWasTool = false
    var previousProjectedItemWasAssistantOutput = false

    for (itemIndex, item) in turn.items.enumerated() {
      switch item {
      case .userMessage(let message):
        appendUserEntry(
          message,
          turnID: turn.id,
          workspaceInstructionsProjection: workspaceInstructionsProjection,
          includesActivatedSkills: includesActivatedSkills,
          to: &entries
        )
        previousProjectedItemWasTool = false
        previousProjectedItemWasAssistantOutput = false
      case .assistantThinking:
        break
      case .assistantMessage(let message):
        guard message.deliveryStatus != .cancelled,
          let modelContent = message.modelProjectedContent,
          !modelContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          previousProjectedItemWasTool = false
          previousProjectedItemWasAssistantOutput = false
          continue
        }
        appendAssistantEntry(
          message,
          content: modelContent,
          historicalReasoning: historicalReasoning(
            in: turn.items,
            forResponseContaining: itemIndex,
            isEnabled: preservesHistoricalReasoning
          ),
          turnID: turn.id,
          to: &entries
        )
        previousProjectedItemWasTool = false
        previousProjectedItemWasAssistantOutput = true
      case .tool(let record):
        guard record.resultPayload != nil,
          !suppressedToolCallIDs.contains(record.id)
        else {
          previousProjectedItemWasTool = false
          previousProjectedItemWasAssistantOutput = false
          continue
        }
        if !previousProjectedItemWasTool && !previousProjectedItemWasAssistantOutput {
          appendAssistantToolBoundary(
            historicalReasoning: historicalReasoning(
              in: turn.items,
              forResponseContaining: itemIndex,
              isEnabled: preservesHistoricalReasoning
            ),
            turnID: turn.id,
            to: &entries
          )
        }
        appendToolEntry(record, turnID: turn.id, to: &entries)
        previousProjectedItemWasTool = true
        previousProjectedItemWasAssistantOutput = false
      }
    }
  }

  /// A provider requires the complete assistant tool-call group followed by one
  /// result for every call. Suppress the whole derived batch until that barrier
  /// is satisfied; projecting only the resolved prefix would create an invalid
  /// MLX history even though the canonical records themselves are already saved.
  private func unresolvedToolCallIDs(in turn: ChatTurn) -> Set<ToolCallRecord.ID> {
    var visited = Set<ToolCallRecord.ID>()
    var suppressed = Set<ToolCallRecord.ID>()

    for item in turn.items {
      guard case .tool(let record) = item,
        !visited.contains(record.id),
        let batch = turn.toolCallBatch(containing: record.id)
      else {
        continue
      }
      let batchIDs = Set(batch.records.map(\.id))
      visited.formUnion(batchIDs)
      if !batch.isModelReady {
        suppressed.formUnion(batchIDs)
      }
    }
    return suppressed
  }

  private func appendUserEntry(
    _ message: UserTurnMessage,
    turnID: ChatTurn.ID,
    workspaceInstructionsProjection: WorkspaceInstructionsProjection?,
    includesActivatedSkills: Bool,
    to entries: inout [ModelContextEntry]
  ) {
    let promptContext = effectivePromptContext(
      for: message,
      workspaceInstructionsProjection: workspaceInstructionsProjection,
      includesActivatedSkills: includesActivatedSkills
    )
    guard
      let entry = try? ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        sourceMessageID: message.id,
        prompt: message.content,
        attachments: message.attachments,
        workspaceInstructions: CurrentPromptContextRenderer.renderWorkspaceInstructions(
          promptContext
        ),
        systemContext: CurrentPromptContextRenderer.renderSupportingContext(promptContext),
        currentPromptContext: promptContext
      )
    else {
      return
    }
    entries.append(entry)
  }

  private func effectivePromptContext(
    for message: UserTurnMessage,
    workspaceInstructionsProjection: WorkspaceInstructionsProjection?,
    includesActivatedSkills: Bool
  ) -> CurrentPromptContext {
    let context: CurrentPromptContext
    if workspaceInstructionsProjection?.messageID == message.id,
      workspaceInstructionsProjection?.rendersSnapshot == true
    {
      context = message.promptContext
    } else {
      context = message.promptContext.removingWorkspaceInstructions()
    }
    return includesActivatedSkills ? context : context.removingActivatedSkills()
  }

  private func latestWorkspaceInstructionsProjection(
    in state: ChatSession
  ) -> WorkspaceInstructionsProjection? {
    guard state.interactionMode == .agent else {
      return nil
    }
    var projection: WorkspaceInstructionsProjection?
    for turn in state.turns {
      guard turn.modelContextPolicy != .excluded else {
        continue
      }
      for item in turn.items {
        guard case .userMessage(let message) = item else {
          continue
        }
        for workspaceInstructions in message.promptContext.workspaceInstructions {
          projection = WorkspaceInstructionsProjection(
            messageID: message.id,
            rendersSnapshot: workspaceInstructions.snapshot != nil
          )
        }
      }
    }
    return projection
  }

  private func appendAssistantEntry(
    _ message: AssistantTurnMessage,
    content: String,
    historicalReasoning: HistoricalAssistantReasoning?,
    turnID: ChatTurn.ID,
    to entries: inout [ModelContextEntry]
  ) {
    guard
      let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: message.id,
        content: content,
        historicalReasoning: historicalReasoning
      )
    else {
      return
    }
    entries.append(entry)
  }

  private func appendAssistantToolBoundary(
    historicalReasoning: HistoricalAssistantReasoning?,
    turnID: ChatTurn.ID,
    to entries: inout [ModelContextEntry]
  ) {
    guard
      let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "",
        historicalReasoning: historicalReasoning
      )
    else {
      return
    }
    entries.append(entry)
  }

  /// User and assistant messages delimit model responses. Thinking and tool
  /// records are transparent within that response, matching `ToolCallBatch`.
  /// Persisted transcripts have no direct thinking-to-response link, so any
  /// group that is not exactly one confirmed, non-empty thinking item is
  /// intentionally omitted instead of guessing.
  private func historicalReasoning(
    in items: [ChatTurnItem],
    forResponseContaining itemIndex: Int,
    isEnabled: Bool
  ) -> HistoricalAssistantReasoning? {
    guard isEnabled, items.indices.contains(itemIndex) else {
      return nil
    }

    let precedingBoundaryIndex = items[...itemIndex].lastIndex { item in
      switch item {
      case .userMessage, .assistantMessage:
        return true
      case .assistantThinking, .tool:
        return false
      }
    }
    let groupStartIndex = precedingBoundaryIndex.map { $0 + 1 } ?? items.startIndex
    let followingBoundaryIndex = items.indices.dropFirst(itemIndex + 1).first { index in
      switch items[index] {
      case .userMessage, .assistantMessage:
        return true
      case .assistantThinking, .tool:
        return false
      }
    }
    let groupEndIndex = followingBoundaryIndex ?? items.endIndex
    let confirmedThinkingMessages: [AssistantThinkingMessage] = items[
      groupStartIndex..<groupEndIndex
    ].compactMap { item in
      guard case .assistantThinking(let message) = item,
        message.deliveryStatus == .complete,
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      return message
    }

    guard confirmedThinkingMessages.count == 1,
      let thinking = confirmedThinkingMessages.first
    else {
      return nil
    }
    return HistoricalAssistantReasoning(content: thinking.content)
  }

  private func appendToolEntry(
    _ record: ToolCallRecord,
    turnID: ChatTurn.ID,
    to entries: inout [ModelContextEntry]
  ) {
    guard let payload = record.resultPayload,
      let entry = try? ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        sourceMessageID: record.id,
        toolResult: ToolResultModelMessage(
          callID: record.id,
          toolName: record.request.toolName,
          payload: payload
        ),
        request: record.request,
        originalUserRequest: nil,
        modelFollowUpNotice: record.modelFollowUpNotice
      )
    else {
      return
    }
    entries.append(entry)
  }

  package func currentPromptContext(
    mode: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    attachments: [ChatAttachment] = [],
    budget: ContextBudget = .focusedFileDefault
  ) -> CurrentPromptContext {
    CurrentPromptContextSelector().selectContext(
      mode: mode,
      focusedFileState: focusedFileState,
      attachments: attachments,
      budget: budget
    )
  }
}

private struct WorkspaceInstructionsProjection: Sendable {
  let messageID: UUID
  let rendersSnapshot: Bool
}
