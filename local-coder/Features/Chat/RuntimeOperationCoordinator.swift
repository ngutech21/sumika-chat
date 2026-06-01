import Foundation

actor RuntimeOperationCoordinator {
  private let runtime: any ChatModelRuntime
  private var currentOperationID = UUID()
  private var activeUnloadTask: Task<Void, Never>?
  private var activeUnloadOperationID: UUID?

  init(runtime: any ChatModelRuntime, initialOperationID: UUID = UUID()) {
    self.runtime = runtime
    self.currentOperationID = initialOperationID
  }

  func beginOperation() -> UUID {
    currentOperationID = UUID()
    return currentOperationID
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

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    operationID: UUID
  ) async throws -> ChatContextUsage {
    try checkCurrent(operationID)
    let usage = try await runtime.contextUsage(
      for: messages,
      attachments: attachments,
      systemPrompt: systemPrompt
    )
    try checkCurrent(operationID)
    return usage
  }

  private func checkCurrent(_ operationID: UUID) throws {
    guard currentOperationID == operationID else {
      throw CancellationError()
    }
  }
}
