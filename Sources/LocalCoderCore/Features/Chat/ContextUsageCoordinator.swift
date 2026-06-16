import Foundation

public struct ContextUsageSnapshot: Sendable {
  public let modelState: ModelLoadState
  public let operationID: UUID
  public let turnID: ChatTurn.ID?
  public let transcript: ModelContextSnapshot
  public let attachments: [ChatAttachment]
  public let systemPrompt: String
  public let contextTokenLimit: Int?
  public let runtimeIsBusy: Bool
  public let interactionMode: WorkspaceInteractionMode?

  public init(
    modelState: ModelLoadState,
    operationID: UUID,
    turnID: ChatTurn.ID? = nil,
    transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    contextTokenLimit: Int? = nil,
    runtimeIsBusy: Bool = false,
    interactionMode: WorkspaceInteractionMode? = nil
  ) {
    self.modelState = modelState
    self.operationID = operationID
    self.turnID = turnID
    self.transcript = transcript
    self.attachments = attachments
    self.systemPrompt = systemPrompt
    self.contextTokenLimit = contextTokenLimit
    self.runtimeIsBusy = runtimeIsBusy
    self.interactionMode = interactionMode
  }

  public func estimatedUsage(isStale: Bool = true) -> ChatContextUsage {
    var byteCount = systemPrompt.utf8.count
    // `.fullHistory` projects every entry to its `frozenContent.content` verbatim,
    // so we sum the stored content directly instead of allocating a projected array.
    for entry in transcript.entries {
      byteCount += entry.frozenContent.content.utf8.count
    }
    for attachment in attachments {
      guard attachment.kind == .text else {
        continue
      }
      byteCount += attachment.content.utf8.count
    }

    return ChatContextUsage(
      usedTokens: Int(ceil(Double(byteCount) / 4.0)),
      tokenLimit: contextTokenLimit,
      accuracy: .estimate,
      isStale: isStale
    )
  }
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

  public init(
    modelLifecycleCoordinator: ModelLifecycleCoordinator,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    debounceDelay: Duration = .milliseconds(750)
  ) {
    _ = turnTracer
    _ = debounceDelay
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
  }

  deinit {
    task?.cancel()
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }

  public func invalidate(onEvent: @MainActor (ContextUsageEvent) -> Void) {
    requestID = UUID()
    cancel()
    onEvent(.reset)
  }

  public func refresh(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) {
    refreshDebounced(snapshot: snapshot, onEvent: onEvent)
  }

  public func refreshDebounced(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) {
    let requestID = beginRequest()
    guard snapshot.modelState == .ready else {
      guard isCurrent(requestID) else {
        return
      }
      onEvent(.reset)
      return
    }

    publishEstimate(snapshot: snapshot, onEvent: onEvent)
  }

  public func refreshNow(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) async {
    let requestID = beginRequest()
    guard snapshot.modelState == .ready else {
      guard isCurrent(requestID) else {
        return
      }
      onEvent(.reset)
      return
    }

    publishEstimate(snapshot: snapshot, onEvent: onEvent)
  }

  public func clearRuntimeContext(
    operationID: UUID,
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) {
    let requestID = beginRequest()
    let modelLifecycleCoordinator = modelLifecycleCoordinator
    publishEstimate(snapshot: snapshot, onEvent: onEvent)
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
      finishTask(requestID: requestID)
    }
  }

  private func beginRequest() -> UUID {
    task?.cancel()
    let requestID = UUID()
    self.requestID = requestID
    return requestID
  }

  private func publishEstimate(
    snapshot: ContextUsageSnapshot,
    onEvent: @MainActor (ContextUsageEvent) -> Void
  ) {
    onEvent(.updated(snapshot.estimatedUsage(isStale: false)))
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
