import Foundation

public struct ChatModelContextBuilder: Sendable {
  private let promptContextSelector: any CurrentPromptContextSelecting
  private let focusedFileReusePolicy: FocusedFilePromptReusePolicy

  public init(
    promptContextSelector: any CurrentPromptContextSelecting = CurrentPromptContextSelector()
  ) {
    self.promptContextSelector = promptContextSelector
    focusedFileReusePolicy = .conservative
  }

  init(
    promptContextSelector: any CurrentPromptContextSelecting = CurrentPromptContextSelector(),
    focusedFileReusePolicy: FocusedFilePromptReusePolicy
  ) {
    self.promptContextSelector = promptContextSelector
    self.focusedFileReusePolicy = focusedFileReusePolicy
  }

  package func transcript(
    from state: ChatSession,
    includingTurnID: ChatTurn.ID? = nil
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
    to entries: inout [ModelContextEntry]
  ) {
    let suppressedToolCallIDs = unresolvedToolCallIDs(in: turn)
    var previousProjectedItemWasTool = false
    var previousProjectedItemWasAssistantOutput = false

    for item in turn.items {
      switch item {
      case .userMessage(let message):
        appendUserEntry(
          message,
          turnID: turn.id,
          workspaceInstructionsProjection: workspaceInstructionsProjection,
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
        appendAssistantEntry(message, content: modelContent, turnID: turn.id, to: &entries)
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
          appendAssistantToolBoundary(turnID: turn.id, to: &entries)
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
    to entries: inout [ModelContextEntry]
  ) {
    let promptContext = effectivePromptContext(
      for: message,
      workspaceInstructionsProjection: workspaceInstructionsProjection
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
    workspaceInstructionsProjection: WorkspaceInstructionsProjection?
  ) -> CurrentPromptContext {
    guard workspaceInstructionsProjection?.messageID == message.id,
      workspaceInstructionsProjection?.rendersSnapshot == true
    else {
      return message.promptContext.removingWorkspaceInstructions()
    }
    return message.promptContext
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
    turnID: ChatTurn.ID,
    to entries: inout [ModelContextEntry]
  ) {
    guard
      let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: message.id,
        content: content
      )
    else {
      return
    }
    entries.append(entry)
  }

  private func appendAssistantToolBoundary(
    turnID: ChatTurn.ID,
    to entries: inout [ModelContextEntry]
  ) {
    guard
      let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: ""
      )
    else {
      return
    }
    entries.append(entry)
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

  public func currentPromptContext(
    userInput: String,
    mode: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    attachments: [ChatAttachment] = [],
    workspace: Workspace? = nil,
    budget: ContextBudget = .focusedFileDefault
  ) -> RenderedCurrentPromptContext {
    let context = promptContextSelector.selectContext(
      userInput: userInput,
      mode: mode,
      focusedFileState: focusedFileState,
      attachments: attachments,
      workspace: workspace,
      budget: budget
    )
    return CurrentPromptContextRenderer.renderedContext(context)
  }
}

private struct WorkspaceInstructionsProjection: Sendable {
  let messageID: UUID
  let rendersSnapshot: Bool
}
