import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct RuntimeContextClearCoordinatorTests {
  @Test
  func newerClearRunsAfterPreviousClearIsCancelled() async throws {
    let previousOperationID = UUID()
    let currentOperationID = UUID()
    let runtime = BlockingFirstClearRuntime()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: previousOperationID
    )
    let coordinator = makeCoordinator(runtimeOperations: runtimeOperations)
    var completionErrors: [Error?] = []

    coordinator.clear(operationID: previousOperationID) {
      completionErrors.append($0)
    }
    try await waitUntil { await runtime.clearCount == 1 }

    await runtimeOperations.setCurrentOperation(currentOperationID)
    coordinator.clear(operationID: currentOperationID) {
      completionErrors.append($0)
    }
    await runtime.releaseFirstClear()

    try await waitUntil { await runtime.clearCount == 2 }
    try await waitUntil { completionErrors.count == 1 }

    #expect(completionErrors[0] == nil)
  }

  @Test
  func currentClearCancellationIsNotReportedAsSuccess() async throws {
    let staleOperationID = UUID()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: BlockingFirstClearRuntime(),
      initialOperationID: UUID()
    )
    let coordinator = makeCoordinator(runtimeOperations: runtimeOperations)
    var completionError: Error?
    var didComplete = false

    coordinator.clear(operationID: staleOperationID) { error in
      completionError = error
      didComplete = true
    }

    try await waitUntil { didComplete }

    #expect(completionError is CancellationError)
  }

  private func makeCoordinator(
    runtimeOperations: RuntimeOperationCoordinator
  ) -> RuntimeContextClearCoordinator {
    RuntimeContextClearCoordinator(
      modelLifecycleCoordinator: ModelLifecycleCoordinator(
        modelDownloader: UnavailableModelDownloader(),
        runtimeOperations: runtimeOperations,
        modelAvailability: { _ in true }
      )
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor BlockingFirstClearRuntime: ChatModelRuntime {
  private var firstClearContinuation: CheckedContinuation<Void, Never>?
  private var didReleaseFirstClear = false
  private(set) var clearCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    clearCount += 1
    guard clearCount == 1, !didReleaseFirstClear else {
      return
    }

    await withCheckedContinuation { continuation in
      firstClearContinuation = continuation
    }
  }

  func releaseFirstClear() {
    didReleaseFirstClear = true
    firstClearContinuation?.resume()
    firstClearContinuation = nil
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { $0.finish() }
  }
}
