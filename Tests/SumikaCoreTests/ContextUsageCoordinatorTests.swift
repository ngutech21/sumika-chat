import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ContextUsageCoordinatorTests {
  @Test
  func refreshPublishesEstimateWhenModelIsReadyWithoutRuntimeTokenization() async {
    let runtime = ContextUsageFakeRuntime(
      usage: ChatContextUsage(usedTokens: 12, tokenLimit: 128))
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    await coordinator.refreshNow(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }

    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(
      events == [
        .updated(
          ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false))
      ])
  }

  @Test
  func busyRefreshPublishesEstimateWithoutRuntimeTokenization() async {
    let runtime = ContextUsageFakeRuntime()
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    await coordinator.refreshNow(
      snapshot: readySnapshot(operationID: operationID, runtimeIsBusy: true)
    ) {
      events.append($0)
    }

    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(
      events == [
        .updated(
          ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false))
      ])
  }

  @Test
  func refreshResetsWhenModelIsNotReady() async {
    let runtime = ContextUsageFakeRuntime()
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    await coordinator.refreshNow(
      snapshot: readySnapshot(modelState: .loading, operationID: operationID)
    ) {
      events.append($0)
    }

    #expect(events == [.reset])
  }

  @Test
  func repeatedRefreshesPublishEstimatesWithoutRuntimeTokenization() async {
    let runtime = ContextUsageFakeRuntime()
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    coordinator.refresh(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }

    coordinator.refresh(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }

    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(
      events == [
        .updated(
          ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false)),
        .updated(
          ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false)),
      ])
  }

  @Test
  func invalidatePublishesResetAfterEstimateRefresh() async {
    let runtime = ContextUsageFakeRuntime()
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    await coordinator.refreshNow(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }

    coordinator.invalidate {
      events.append($0)
    }

    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(events.last == .reset)
  }

  @Test
  func clearRuntimeContextClearsWithoutExactRefresh() async throws {
    let runtime = ContextUsageFakeRuntime(
      usage: ChatContextUsage(usedTokens: 42, tokenLimit: nil))
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    coordinator.clearRuntimeContext(
      operationID: operationID,
      snapshot: readySnapshot(operationID: operationID)
    ) {
      events.append($0)
    }

    try await waitUntilAsync { await runtime.clearContextCount == 1 }
    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(
      events == [
        .updated(
          ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false))
      ])
  }

  @Test
  func clearRuntimeContextDoesNotPublishAfterNewerRefresh() async throws {
    let runtime = ContextUsageDelayedClearRuntime()
    defer { Task { await runtime.releaseClearContext() } }
    let firstOperationID = UUID()
    let secondOperationID = UUID()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: firstOperationID
    )
    let coordinator = ContextUsageCoordinator(
      modelLifecycleCoordinator: ModelLifecycleCoordinator(
        modelDownloader: ContextUsageFakeModelDownloader(),
        runtimeOperations: runtimeOperations
      ))
    var events: [ContextUsageEvent] = []

    coordinator.clearRuntimeContext(
      operationID: firstOperationID,
      snapshot: readySnapshot(operationID: firstOperationID)
    ) {
      events.append($0)
    }
    try await waitUntilAsync { await runtime.didStartClearContext }

    await runtimeOperations.setCurrentOperation(secondOperationID)
    await coordinator.refreshNow(snapshot: readySnapshot(operationID: secondOperationID)) {
      events.append($0)
    }
    await runtime.releaseClearContext()
    try await waitUntilAsync { await runtime.didFinishClearContext }
    await Task.yield()

    #expect(
      events == [
        .updated(
          ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false)),
        .updated(
          ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false)),
      ])
  }

  @Test
  func estimateRefreshDoesNotTraceTokenization() async {
    let runtime = ContextUsageFakeRuntime(usage: ChatContextUsage(usedTokens: 12, tokenLimit: 128))
    let operationID = UUID()
    let tracer = RecordingContextUsageTracer()
    let coordinator = makeCoordinator(
      runtime: runtime, initialOperationID: operationID, tracer: tracer)
    var events: [ContextUsageEvent] = []

    await coordinator.refreshNow(
      snapshot: readySnapshot(operationID: operationID, runtimeIsBusy: true)
    ) {
      events.append($0)
    }

    await coordinator.refreshNow(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }

    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(await tracer.events.isEmpty)
  }

  private func makeCoordinator(
    runtime: any ChatModelRuntime,
    initialOperationID: UUID,
    tracer: any TurnTracing = NoopTurnTracer()
  ) -> ContextUsageCoordinator {
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: initialOperationID
    )
    return ContextUsageCoordinator(
      modelLifecycleCoordinator: ModelLifecycleCoordinator(
        modelDownloader: ContextUsageFakeModelDownloader(),
        runtimeOperations: runtimeOperations
      ),
      turnTracer: tracer,
      debounceDelay: .milliseconds(10)
    )
  }

  private func readySnapshot(
    modelState: ModelLoadState = .ready,
    operationID: UUID,
    systemPrompt: String = "system",
    runtimeIsBusy: Bool = false
  ) -> ContextUsageSnapshot {
    let entry: ModelContextEntry
    do {
      entry = try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "hello"
      )
    } catch {
      preconditionFailure("Failed to build context usage test transcript: \(error)")
    }

    return ContextUsageSnapshot(
      modelState: modelState,
      operationID: operationID,
      transcript: ModelContextSnapshot(entries: [entry]),
      attachments: [],
      systemPrompt: systemPrompt,
      contextTokenLimit: 100,
      runtimeIsBusy: runtimeIsBusy
    )
  }

  private func waitUntilAsync(
    timeout: Duration = .seconds(1),
    condition: @escaping () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for async condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor ContextUsageFakeRuntime: ChatModelRuntime {
  private let usage: ChatContextUsage
  private(set) var clearContextCount = 0
  private(set) var contextUsageRequestCount = 0

  init(usage: ChatContextUsage = ChatContextUsage(usedTokens: 0, tokenLimit: nil)) {
    self.usage = usage
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    clearContextCount += 1
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    contextUsageRequestCount += 1
    return usage
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private actor ContextUsageDelayedClearRuntime: ChatModelRuntime {
  private var clearContextContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartClearContext = false
  private(set) var didFinishClearContext = false

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    didStartClearContext = true
    await withCheckedContinuation { continuation in
      clearContextContinuation = continuation
      Task {
        try? await Task.sleep(for: .seconds(2))
        self.releaseClearContext()
      }
    }
    didFinishClearContext = true
  }

  func releaseClearContext() {
    clearContextContinuation?.resume()
    clearContextContinuation = nil
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 42, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private actor RecordingContextUsageTracer: TurnTracing {
  private(set) var events: [TurnTraceEvent] = []

  func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    events.append(event)
  }
}

private struct ContextUsageFakeModelDownloader: ModelDownloading {
  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    _ = progressHandler
    return model.localDirectoryURL
  }
}
