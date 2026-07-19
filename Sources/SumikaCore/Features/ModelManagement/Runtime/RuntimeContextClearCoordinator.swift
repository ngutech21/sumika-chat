import Foundation

@MainActor
public final class RuntimeContextClearCoordinator {
  private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  private var pendingClear: PendingRuntimeContextClear?

  public init(modelLifecycleCoordinator: ModelLifecycleCoordinator) {
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
  }

  public func clear(
    operationID: UUID,
    onCompletion: @escaping @MainActor (Error?) -> Void
  ) {
    let previousTask = pendingClear?.task
    let modelLifecycleCoordinator = modelLifecycleCoordinator
    let clearID = UUID()
    let clearTask = Task {
      if let previousTask {
        _ = try? await previousTask.value
      }
      try Task.checkCancellation()
      try await modelLifecycleCoordinator.clearContext(operationID: operationID)
    }
    pendingClear = PendingRuntimeContextClear(id: clearID, task: clearTask)

    Task { [weak self, clearID, clearTask] in
      do {
        try await clearTask.value
        self?.complete(id: clearID, error: nil, onCompletion: onCompletion)
      } catch let error as CancellationError {
        self?.complete(id: clearID, error: error, onCompletion: onCompletion)
      } catch {
        self?.complete(id: clearID, error: error, onCompletion: onCompletion)
      }
    }
  }

  public func awaitPendingClear() async throws {
    guard let pendingClear else {
      return
    }

    try await pendingClear.task.value
    if self.pendingClear?.id == pendingClear.id {
      self.pendingClear = nil
    }
  }

  private func complete(
    id: UUID,
    error: Error?,
    onCompletion: @MainActor (Error?) -> Void
  ) {
    guard pendingClear?.id == id else {
      return
    }

    pendingClear = nil
    onCompletion(error)
  }

  private struct PendingRuntimeContextClear {
    let id: UUID
    let task: Task<Void, Error>
  }
}
