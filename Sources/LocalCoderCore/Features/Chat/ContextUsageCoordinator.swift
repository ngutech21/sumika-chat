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
    for entry in transcript.projectedEntries(mode: .compactedHistoryForLaterTurns) {
      byteCount += entry.content.utf8.count
    }
    for attachment in attachments {
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
  private let turnTracer: any TurnTracing
  private let debounceDelay: Duration
  private var task: Task<Void, Never>?
  private var exactTask: Task<Void, Never>?
  private var pendingRefresh: PendingRefresh?
  private var requestID = UUID()

  public init(
    modelLifecycleCoordinator: ModelLifecycleCoordinator,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    debounceDelay: Duration = .milliseconds(750)
  ) {
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
    self.turnTracer = turnTracer
    self.debounceDelay = debounceDelay
  }

  deinit {
    task?.cancel()
    exactTask?.cancel()
  }

  public func cancel() {
    task?.cancel()
    task = nil
    pendingRefresh = nil
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
    refreshDebounced(snapshot: snapshot, onEvent: onEvent)
  }

  public func refreshDebounced(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) {
    let requestID = beginRequest()
    guard shouldAttemptExactRefresh(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
    else {
      return
    }

    task = Task {
      do {
        try await Task.sleep(for: debounceDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else {
        return
      }
      await startExactRefresh(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
      finishTask(requestID: requestID)
    }
  }

  public func refreshNow(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) async {
    let requestID = beginRequest()
    guard shouldAttemptExactRefresh(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
    else {
      return
    }
    await startExactRefresh(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
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
    pendingRefresh = nil
    let requestID = UUID()
    self.requestID = requestID
    return requestID
  }

  private func shouldAttemptExactRefresh(
    requestID: UUID,
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) -> Bool {
    guard snapshot.modelState == .ready else {
      guard isCurrent(requestID) else {
        return false
      }
      onEvent(.reset)
      return false
    }

    guard !snapshot.runtimeIsBusy else {
      publishEstimate(snapshot: snapshot, onEvent: onEvent)
      pendingRefresh = PendingRefresh(snapshot: snapshot, onEvent: onEvent)
      return false
    }

    if exactTask != nil {
      publishEstimate(snapshot: snapshot, onEvent: onEvent)
      pendingRefresh = PendingRefresh(snapshot: snapshot, onEvent: onEvent)
      return false
    }

    return true
  }

  private func startExactRefresh(
    requestID: UUID,
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) async {
    exactTask = Task {
      await refreshExact(requestID: requestID, snapshot: snapshot, onEvent: onEvent)
    }
    await exactTask?.value
    finishExactRefresh(requestID: requestID)
  }

  private func refreshExact(
    requestID: UUID,
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) async {
    do {
      let startedAt = Date()
      let usage = try await modelLifecycleCoordinator.contextUsage(
        for: snapshot.transcript,
        attachments: snapshot.attachments,
        systemPrompt: snapshot.systemPrompt,
        operationID: snapshot.operationID
      )
      await turnTracer.recordTurnTraceEvent(
        TurnTraceEvent(
          turnID: snapshot.turnID,
          generationID: nil,
          phase: .tokenizeContextUsage,
          durationMs: Date().timeIntervalSince(startedAt) * 1000,
          promptBytes: snapshot.systemPrompt.utf8.count,
          promptTokens: usage.usedTokens,
          messageCount: snapshot.transcript.entries.count,
          interactionMode: snapshot.interactionMode
        )
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

  private func publishEstimate(
    snapshot: ContextUsageSnapshot,
    onEvent: @escaping @MainActor (ContextUsageEvent) -> Void
  ) {
    onEvent(.updated(snapshot.estimatedUsage()))
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

  private func finishExactRefresh(requestID: UUID) {
    if isCurrent(requestID) {
      exactTask = nil
    } else {
      exactTask = nil
      if let pendingRefresh {
        self.pendingRefresh = nil
        refreshDebounced(snapshot: pendingRefresh.snapshot, onEvent: pendingRefresh.onEvent)
      }
    }
  }

  private struct PendingRefresh {
    let snapshot: ContextUsageSnapshot
    let onEvent: @MainActor (ContextUsageEvent) -> Void
  }
}
