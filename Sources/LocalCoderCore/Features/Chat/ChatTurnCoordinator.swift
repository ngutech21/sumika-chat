import Foundation

@MainActor
public final class ChatTurnCoordinator {
  private(set) var activeTurnID: ChatTurn.ID?
  private var activeTask: Task<Void, Never>?

  deinit {
    activeTask?.cancel()
  }

  @discardableResult
  public func startTurn(
    id turnID: ChatTurn.ID,
    operation: @escaping @MainActor @Sendable (ChatTurn.ID) async -> Void
  ) -> ChatTurn.ID {
    activeTask?.cancel()
    activeTurnID = turnID
    activeTask = Task {
      await operation(turnID)
    }
    return turnID
  }

  public func cancelActiveTurn() -> ChatTurn.ID? {
    guard let activeTurnID else {
      return nil
    }

    activeTask?.cancel()
    activeTask = nil
    self.activeTurnID = nil
    return activeTurnID
  }

  public func finishTurn(_ turnID: ChatTurn.ID) {
    guard activeTurnID == turnID else {
      return
    }

    activeTask = nil
    activeTurnID = nil
  }

  public func isActive(_ turnID: ChatTurn.ID) -> Bool {
    activeTurnID == turnID
  }
}
