import Foundation

nonisolated struct ChatModelContextBuilder: Sendable {
  func messages(
    from state: ChatSessionState,
    includingTurnID: ChatTurnRecord.ID? = nil
  ) -> [ChatMessage] {
    let excludedTurnIDs = Set(
      state.turns.compactMap { turn -> ChatTurnRecord.ID? in
        guard turn.modelContextPolicy == .excluded, turn.id != includingTurnID else {
          return nil
        }
        return turn.id
      }
    )

    guard !excludedTurnIDs.isEmpty else {
      return state.messages
    }

    return state.messages.filter { message in
      guard let turnID = message.turnID else {
        return true
      }
      return !excludedTurnIDs.contains(turnID)
    }
  }
}
