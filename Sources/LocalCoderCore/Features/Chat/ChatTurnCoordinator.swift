import Foundation

@MainActor
public final class ChatTurnCoordinator {
  private(set) var activeTurnID: ChatTurnRecord.ID?
  private var activeTask: Task<Void, Never>?

  deinit {
    activeTask?.cancel()
  }

  @discardableResult
  public func startTurn(
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

  public func cancelActiveTurn() -> ChatTurnRecord.ID? {
    guard let activeTurnID else {
      return nil
    }

    activeTask?.cancel()
    activeTask = nil
    self.activeTurnID = nil
    return activeTurnID
  }

  public func finishTurn(_ turnID: ChatTurnRecord.ID) {
    guard activeTurnID == turnID else {
      return
    }

    activeTask = nil
    activeTurnID = nil
  }

  public func isActive(_ turnID: ChatTurnRecord.ID) -> Bool {
    activeTurnID == turnID
  }
}
