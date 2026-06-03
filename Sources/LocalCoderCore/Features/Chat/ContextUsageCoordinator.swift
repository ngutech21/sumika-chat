import Foundation

public struct ContextUsageSnapshot: Sendable {
  public let modelState: ModelLoadState
  public let operationID: UUID
  public let messages: [ChatMessage]
  public let attachments: [ChatAttachment]
  public let systemPrompt: String
}

public enum ContextUsageEvent: Sendable, Equatable {
  case reset
  case updated(ChatContextUsage)
  case failed
  case error(String)
}

@MainActor
public final class ContextUsageCoordinator {
  private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  private var task: Task<Void, Never>?
  private var requestID = UUID()

  public init(modelLifecycleCoordinator: ModelLifecycleCoordinator) {
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
  }

  deinit {
    task?.cancel()
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }

  public func invalidate(onEvent: @escaping @MainActor (ContextUsageEvent) -> Void) {
    requestID = UUID()
    cancel()
    onEvent(.reset)
  }

  public func refresh(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) {
    let requestID = beginRequest()
    task = Task {
      await refresh(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
      finishTask(requestID: requestID)
    }
  }

  public func refreshNow(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) async {
    let requestID = beginRequest()
    await refresh(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
  }

  public func clearRuntimeContext(
    operationID: UUID,
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) {
    let requestID = beginRequest()
    let modelLifecycleCoordinator = modelLifecycleCoordinator
    task = Task {
      do {
        try await modelLifecycleCoordinator.clearContext(operationID: operationID)
      } catch is CancellationError {
      } catch {
        guard isCurrent(requestID) else {
          return
        }
        onEvent(.error(error.localizedDescription))
      }

      guard isCurrent(requestID) else {
        return
      }
      await refresh(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
      finishTask(requestID: requestID)
    }
  }

  private func beginRequest() -> UUID {
    task?.cancel()
    let requestID = UUID()
    self.requestID = requestID
    return requestID
  }

  private func refresh(
    requestID: UUID,
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) async {
    guard snapshot.modelState == .ready else {
      guard isCurrent(requestID) else {
        return
      }
      onEvent(.reset)
      return
    }

    do {
      let usage = try await modelLifecycleCoordinator.contextUsage(
        for: snapshot.messages,
        attachments: snapshot.attachments,
        systemPrompt: snapshot.systemPrompt,
        operationID: snapshot.operationID
      )
      guard isCurrent(requestID) else {
        return
      }
      onEvent(.updated(usage))
    } catch is CancellationError {
    } catch {
      guard isCurrent(requestID) else {
        return
      }
      onEvent(.failed)
    }
  }

  private func isCurrent(_ requestID: UUID) -> Bool {
    self.requestID == requestID
  }

  private func finishTask(requestID: UUID) {
    guard isCurrent(requestID) else {
      return
    }
    task = nil
  }
}
