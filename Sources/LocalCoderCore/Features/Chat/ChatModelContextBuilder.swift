import Foundation

public struct ChatModelContextBuilder: Sendable {
  private let promptContextSelector: any CurrentPromptContextSelecting

  public init(
    promptContextSelector: any CurrentPromptContextSelecting = CurrentPromptContextSelector()
  ) {
    self.promptContextSelector = promptContextSelector
  }

  public func transcript(
    from state: ChatSessionState,
    includingTurnID: ChatTurnRecord.ID? = nil
  ) -> ModelFacingTranscript {
    let excludedTurnIDs = Set(
      state.turns.compactMap { turn -> ChatTurnRecord.ID? in
        guard turn.modelContextPolicy == .excluded, turn.id != includingTurnID else {
          return nil
        }
        return turn.id
      }
    )

    guard !excludedTurnIDs.isEmpty else {
      return state.modelFacingTranscript
    }

    return ModelFacingTranscript(
      entries: state.modelFacingTranscript.entries.filter { entry in
        guard let turnID = entry.turnID else {
          return true
        }
        return !excludedTurnIDs.contains(turnID)
      }
    )
  }

  public func currentPromptSystemContext(
    userInput: String,
    mode: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    budget: ContextBudget = .focusedFileDefault
  ) -> [String] {
    let context = promptContextSelector.selectContext(
      userInput: userInput,
      mode: mode,
      focusedFileState: focusedFileState,
      budget: budget
    )
    return CurrentPromptContextRenderer.render(context)
  }
}
