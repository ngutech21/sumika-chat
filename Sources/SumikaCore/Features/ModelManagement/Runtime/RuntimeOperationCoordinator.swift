import Foundation

package actor RuntimeOperationCoordinator {
  private let runtime: any ChatModelRuntime
  private var currentOperationID = UUID()
  private var activeUnloadTask: Task<Void, Never>?
  private var activeUnloadOperationID: UUID?

  package init(runtime: any ChatModelRuntime, initialOperationID: UUID = UUID()) {
    self.runtime = runtime
    self.currentOperationID = initialOperationID
  }

  func setCurrentOperation(_ operationID: UUID) {
    currentOperationID = operationID
  }

  func currentOperation() -> UUID {
    currentOperationID
  }

  func isCurrent(_ operationID: UUID) -> Bool {
    currentOperationID == operationID
  }

  func checkCurrentOperation(_ operationID: UUID) throws {
    try checkCurrent(operationID)
  }

  func load(configuration: ChatModelConfiguration, operationID: UUID) async throws {
    if let activeUnloadTask {
      await activeUnloadTask.value
    }

    try checkCurrent(operationID)
    try await runtime.load(configuration: configuration)
    try checkCurrent(operationID)
  }

  func unload(operationID: UUID) async throws {
    try checkCurrent(operationID)
    let unloadTask = Task {
      await runtime.unload()
    }
    activeUnloadTask = unloadTask
    activeUnloadOperationID = operationID
    await unloadTask.value
    if activeUnloadOperationID == operationID {
      activeUnloadTask = nil
      activeUnloadOperationID = nil
    }
    try checkCurrent(operationID)
  }

  func clearContext(operationID: UUID) async throws {
    try checkCurrent(operationID)
    await runtime.clearContext()
    try checkCurrent(operationID)
  }

  func runtimeCacheDebugSnapshot(operationID: UUID) async throws
    -> RuntimeCacheDebugSnapshot?
  {
    try checkCurrent(operationID)
    let snapshot = await runtime.runtimeCacheDebugSnapshot()
    try checkCurrent(operationID)
    return snapshot
  }

  func generatedTokenCount(for text: String, operationID: UUID) async throws -> Int {
    try checkCurrent(operationID)
    let count = try await runtime.generatedTokenCount(for: text)
    try checkCurrent(operationID)
    return count
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    operationID: UUID
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    try checkCurrent(operationID)
    let stream = try await runtime.streamReply(
      for: transcript,
      attachments: attachments,
      promptPlan: promptPlan,
      settings: settings
    )
    try checkCurrent(operationID)

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await event in stream {
            try checkCurrent(operationID)
            continuation.yield(event)
          }
          try checkCurrent(operationID)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func checkCurrent(_ operationID: UUID) throws {
    guard currentOperationID == operationID else {
      throw CancellationError()
    }
  }
}
