import Foundation
import Testing

@testable import LocalCoderCore

@MainActor
struct ContextUsageCoordinatorTests {
  @Test
  func refreshPublishesUsageWhenModelIsReady() async {
    let runtime = ContextUsageFakeRuntime(
      usage: ChatContextUsage(usedTokens: 12, tokenLimit: 128))
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    await coordinator.refreshNow(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }

    #expect(events == [.updated(ChatContextUsage(usedTokens: 12, tokenLimit: 128))])
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
  func refreshPublishesOnlyLatestResult() async throws {
    let runtime = ContextUsageControlledRuntime()
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    coordinator.refresh(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }
    try await waitUntilAsync { await runtime.contextUsageRequestCount == 1 }

    coordinator.refresh(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }
    try await waitUntilAsync { await runtime.contextUsageRequestCount == 2 }

    await runtime.resolveContextUsage(
      at: 1,
      with: ChatContextUsage(usedTokens: 20, tokenLimit: 100)
    )
    try await waitUntil { events == [.updated(ChatContextUsage(usedTokens: 20, tokenLimit: 100))] }

    await runtime.resolveContextUsage(
      at: 0,
      with: ChatContextUsage(usedTokens: 10, tokenLimit: 100)
    )
    try await waitUntilAsync { await runtime.completedContextUsageCount == 2 }
    await Task.yield()

    #expect(events == [.updated(ChatContextUsage(usedTokens: 20, tokenLimit: 100))])
  }

  @Test
  func clearRuntimeContextClearsThenRefreshes() async throws {
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
    try await waitUntil { events == [.updated(ChatContextUsage(usedTokens: 42, tokenLimit: nil))] }
  }

  @Test
  func clearRuntimeContextDoesNotPublishAfterNewerRefresh() async throws {
    let runtime = ContextUsageDelayedClearRuntime()
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

    #expect(events == [.updated(ChatContextUsage(usedTokens: 42, tokenLimit: nil))])
  }

  @Test
  func refreshFailurePublishesFailedEvent() async {
    let runtime = ContextUsageFailingRuntime()
    let operationID = UUID()
    let coordinator = makeCoordinator(runtime: runtime, initialOperationID: operationID)
    var events: [ContextUsageEvent] = []

    await coordinator.refreshNow(snapshot: readySnapshot(operationID: operationID)) {
      events.append($0)
    }

    #expect(events == [.failed])
  }

  private func makeCoordinator(
    runtime: any ChatModelRuntime,
    initialOperationID: UUID
  ) -> ContextUsageCoordinator {
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: initialOperationID
    )
    return ContextUsageCoordinator(
      modelLifecycleCoordinator: ModelLifecycleCoordinator(
        modelDownloader: ContextUsageFakeModelDownloader(),
        runtimeOperations: runtimeOperations
      ))
  }

  private func readySnapshot(
    modelState: ModelLoadState = .ready,
    operationID: UUID
  ) -> ContextUsageSnapshot {
    ContextUsageSnapshot(
      modelState: modelState,
      operationID: operationID,
      messages: [ChatMessage(userContent: "hello")],
      attachments: [],
      systemPrompt: "system"
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !condition() {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
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
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return usage
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private actor ContextUsageControlledRuntime: ChatModelRuntime {
  private var contextUsageContinuations: [CheckedContinuation<ChatContextUsage, Never>] = []
  private(set) var completedContextUsageCount = 0

  var contextUsageRequestCount: Int {
    contextUsageContinuations.count
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    let usage = await withCheckedContinuation { continuation in
      contextUsageContinuations.append(continuation)
    }
    completedContextUsageCount += 1
    return usage
  }

  func resolveContextUsage(at index: Int, with usage: ChatContextUsage) {
    guard contextUsageContinuations.indices.contains(index) else {
      return
    }
    let continuation = contextUsageContinuations.remove(at: index)
    continuation.resume(returning: usage)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
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
    }
    didFinishClearContext = true
  }

  func releaseClearContext() {
    clearContextContinuation?.resume()
    clearContextContinuation = nil
  }

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 42, tokenLimit: nil)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private actor ContextUsageFailingRuntime: ChatModelRuntime {
  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    throw ContextUsageTestError.failed
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private enum ContextUsageTestError: Error {
  case failed
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
