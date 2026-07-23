import Foundation
import Testing

@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif
@Suite()
struct MLXGenerationLifecycleTests {
  @Test
  func generationOwnershipBeginsMonotonicGenerations() {
    var ownership = MLXGenerationOwnership()

    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    #expect(first.rawValue == 1)
    #expect(second.rawValue == 2)
    #expect(ownership.activeGenerationID == second)
  }

  @Test
  func generationOwnershipCompletesOnlyCurrentGeneration() {
    var ownership = MLXGenerationOwnership()
    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    let staleCompletionAccepted = ownership.completeIfCurrent(first)
    #expect(ownership.activeGenerationID == second)
    let currentCompletionAccepted = ownership.completeIfCurrent(second)
    #expect(ownership.activeGenerationID == nil)
    let repeatedCompletionAccepted = ownership.completeIfCurrent(second)

    #expect(!staleCompletionAccepted)
    #expect(currentCompletionAccepted)
    #expect(!repeatedCompletionAccepted)
  }

  @Test
  func generationOwnershipInvalidatesOnlyCurrentGeneration() {
    var ownership = MLXGenerationOwnership()
    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    let staleInvalidationAccepted = ownership.invalidateIfCurrent(first)
    #expect(ownership.activeGenerationID == second)
    let currentInvalidationAccepted = ownership.invalidateIfCurrent(second)
    #expect(ownership.activeGenerationID == nil)
    let repeatedInvalidationAccepted = ownership.invalidateIfCurrent(second)

    #expect(!staleInvalidationAccepted)
    #expect(currentInvalidationAccepted)
    #expect(!repeatedInvalidationAccepted)
  }

  @Test
  func generationOwnershipInvalidatesActiveGeneration() {
    var ownership = MLXGenerationOwnership()
    let generationID = ownership.beginGeneration()

    ownership.invalidateActiveGeneration()

    #expect(ownership.activeGenerationID == nil)
    let completionAccepted = ownership.completeIfCurrent(generationID)
    let invalidationAccepted = ownership.invalidateIfCurrent(generationID)

    #expect(!completionAccepted)
    #expect(!invalidationAccepted)
  }

  @Test
  func activeGenerationRegistrySupersedesAndCancelsPreviousTask() async throws {
    var registry = MLXActiveGenerationRegistry()
    let generationID = MLXGenerationID(rawValue: 1)
    let task = Task<Void, Never> {
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {}
    }

    registry.register(id: generationID, task: task)

    let supersededGeneration = registry.supersedeActiveGeneration()
    let superseded = try #require(supersededGeneration)
    #expect(superseded.id == generationID)
    #expect(superseded.task.isCancelled)
    #expect(registry.supersedeActiveGeneration() == nil)

    try await withTestTimeout(.seconds(5)) {
      await superseded.task.value
    }
  }

  @Test
  func activeGenerationRegistryClearsOnlyCurrentGeneration() {
    var registry = MLXActiveGenerationRegistry()
    let first = MLXGenerationID(rawValue: 1)
    let second = MLXGenerationID(rawValue: 2)
    let task = Task<Void, Never> {}

    registry.register(id: first, task: task)

    let staleClearAccepted = registry.clearIfCurrent(second)
    #expect(!staleClearAccepted)
    let currentClearAccepted = registry.clearIfCurrent(first)
    let repeatedClearAccepted = registry.clearIfCurrent(first)
    #expect(currentClearAccepted)
    #expect(!repeatedClearAccepted)
  }

  @Test
  func unloadAndClearContextClearMemoryCacheWithExplicitReasons() async {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let runtime = MLXChatRuntime(
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      },
      debugTraceStore: temporaryDebugTraceStore()
    )

    await runtime.unload()
    await runtime.clearContext()

    #expect(await memoryClearRecorder.reasons == [.unload, .clearContext])
  }

  @Test
  func unloadWaitsForActiveGenerationToDrainBeforeClearingMemoryCache() async throws {
    try await assertLifecycleOperationDrainsBeforeMemoryClear(reason: .unload) { runtime in
      await runtime.unload()
    }
  }

  @Test
  func clearContextWaitsForActiveGenerationToDrainBeforeClearingMemoryCache() async throws {
    try await assertLifecycleOperationDrainsBeforeMemoryClear(reason: .clearContext) { runtime in
      await runtime.clearContext()
    }
  }

  private func temporaryDebugTraceStore() -> MLXDebugTraceStore {
    MLXDebugTraceStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
    )
  }

  private func assertLifecycleOperationDrainsBeforeMemoryClear(
    reason: MLXMemoryClearReason,
    operation: @escaping @Sendable (MLXChatRuntime) async -> Void
  ) async throws {
    let recorder = MLXLifecycleDrainRecorder()
    let runtime = MLXChatRuntime(
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await recorder.record(.memoryClear(reason))
      },
      debugTraceStore: temporaryDebugTraceStore()
    )
    let task = Task<Void, Never> {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
      await recorder.record(.taskCancelled)
      await recorder.waitUntilAllowedToFinish()
      await recorder.record(.taskFinished)
    }
    await runtime.registerActiveGenerationForTesting(id: MLXGenerationID(rawValue: 1), task: task)

    let lifecycleTask = Task {
      await operation(runtime)
    }
    defer {
      task.cancel()
      lifecycleTask.cancel()
    }

    try await waitUntilAsync {
      await recorder.events.contains(.taskCancelled)
    }
    #expect(await recorder.events == [.taskCancelled])

    await recorder.allowTaskToFinish()
    try await withTestTimeout(.seconds(5)) {
      await lifecycleTask.value
    }

    #expect(await recorder.events == [.taskCancelled, .taskFinished, .memoryClear(reason)])
  }

  private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    condition: () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while await condition() == false {
      if ContinuousClock.now - start > timeout {
        throw MLXStreamWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private actor MLXMemoryClearRecorder {
    private var recordedReasons: [MLXMemoryClearReason] = []

    var reasons: [MLXMemoryClearReason] {
      recordedReasons
    }

    func record(_ reason: MLXMemoryClearReason) {
      recordedReasons.append(reason)
    }
  }

  private enum MLXLifecycleDrainEvent: Equatable {
    case taskCancelled
    case taskFinished
    case memoryClear(MLXMemoryClearReason)
  }

  private actor MLXLifecycleDrainRecorder {
    private var recordedEvents: [MLXLifecycleDrainEvent] = []
    private var shouldFinish = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    var events: [MLXLifecycleDrainEvent] {
      recordedEvents
    }

    func record(_ event: MLXLifecycleDrainEvent) {
      recordedEvents.append(event)
    }

    func waitUntilAllowedToFinish() async {
      if shouldFinish {
        return
      }

      await withCheckedContinuation { continuation in
        finishContinuation = continuation
      }
    }

    func allowTaskToFinish() {
      shouldFinish = true
      finishContinuation?.resume()
      finishContinuation = nil
    }
  }

  private struct MLXStreamWaitTimeoutError: Error {}

}
