import Foundation

public struct ChatModelContextBuilder: Sendable {
  private let promptContextSelector: any CurrentPromptContextSelecting

  public init(
    promptContextSelector: any CurrentPromptContextSelecting = CurrentPromptContextSelector()
  ) {
    self.promptContextSelector = promptContextSelector
  }

  public func transcript(
    from state: ChatSession,
    includingTurnID: ChatTurn.ID? = nil
  ) -> ModelPromptProjection {
    var entries: [ModelContextEntry] = []

    for turn in state.turns {
      guard turn.modelContextPolicy != .excluded || turn.id == includingTurnID else {
        continue
      }

      appendEntries(for: turn, to: &entries)
    }

    return ModelPromptProjection(entries: entries)
  }

  private func appendEntries(
    for turn: ChatTurn,
    to entries: inout [ModelContextEntry]
  ) {
    var previousProjectedItemWasTool = false

    for item in turn.items {
      switch item {
      case .userMessage(let message):
        appendUserEntry(message, turnID: turn.id, to: &entries)
        previousProjectedItemWasTool = false
      case .assistantThinking:
        break
      case .assistantMessage(let message):
        guard message.deliveryStatus != .cancelled,
          !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          previousProjectedItemWasTool = false
          continue
        }
        appendAssistantEntry(message, turnID: turn.id, to: &entries)
        previousProjectedItemWasTool = false
      case .tool(let record):
        guard record.resultPayload != nil else {
          previousProjectedItemWasTool = false
          continue
        }
        if !previousProjectedItemWasTool {
          appendAssistantToolBoundary(turnID: turn.id, to: &entries)
        }
        appendToolEntry(record, turnID: turn.id, to: &entries)
        previousProjectedItemWasTool = true
      }
    }
  }

  private func appendUserEntry(
    _ message: UserTurnMessage,
    turnID: ChatTurn.ID,
    to entries: inout [ModelContextEntry]
  ) {
    guard
      let entry = try? ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        sourceMessageID: message.id,
        prompt: message.content,
        attachments: message.attachments,
        systemContext: CurrentPromptContextRenderer.render(message.promptContext),
        currentPromptContext: message.promptContext
      )
    else {
      return
    }
    entries.append(entry)
  }

  private func appendAssistantEntry(
    _ message: AssistantTurnMessage,
    turnID: ChatTurn.ID,
    to entries: inout [ModelContextEntry]
  ) {
    guard
      let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: message.id,
        content: message.content
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
        originalUserRequest: nil
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
