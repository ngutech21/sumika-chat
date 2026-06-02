import Foundation

@MainActor
final class ChatTurnCoordinator {
  private(set) var activeTurnID: ChatTurnRecord.ID?
  private var activeTask: Task<Void, Never>?

  deinit {
    activeTask?.cancel()
  }

  @discardableResult
  func startTurn(
    id turnID: ChatTurnRecord.ID,
    operation: @escaping @MainActor @Sendable (ChatTurnRecord.ID) async -> Void
  ) -> ChatTurnRecord.ID {
    activeTask?.cancel()
    activeTurnID = turnID
    activeTask = Task {
      await operation(turnID)
    }
    return turnID
  }

  func cancelActiveTurn() -> ChatTurnRecord.ID? {
    guard let activeTurnID else {
      return nil
    }

    activeTask?.cancel()
    activeTask = nil
    self.activeTurnID = nil
    return activeTurnID
  }

  func finishTurn(_ turnID: ChatTurnRecord.ID) {
    guard activeTurnID == turnID else {
      return
    }

    activeTask = nil
    activeTurnID = nil
  }

  func isActive(_ turnID: ChatTurnRecord.ID) -> Bool {
    activeTurnID == turnID
  }
}
