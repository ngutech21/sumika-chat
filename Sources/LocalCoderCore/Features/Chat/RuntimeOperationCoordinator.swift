import Foundation

public actor RuntimeOperationCoordinator {
  private let runtime: any ChatModelRuntime
  private var currentOperationID = UUID()
  private var activeUnloadTask: Task<Void, Never>?
  private var activeUnloadOperationID: UUID?

  public init(runtime: any ChatModelRuntime, initialOperationID: UUID = UUID()) {
    self.runtime = runtime
    self.currentOperationID = initialOperationID
  }

  public func beginOperation() -> UUID {
    currentOperationID = UUID()
    return currentOperationID
  }

  public func setCurrentOperation(_ operationID: UUID) {
    currentOperationID = operationID
  }

  public func currentOperation() -> UUID {
    currentOperationID
  }

  public func isCurrent(_ operationID: UUID) -> Bool {
    currentOperationID == operationID
  }

  public func load(configuration: ChatModelConfiguration, operationID: UUID) async throws {
    if let activeUnloadTask {
      await activeUnloadTask.value
    }

    try checkCurrent(operationID)
    try await runtime.load(configuration: configuration)
    try checkCurrent(operationID)
  }

  public func unload(operationID: UUID) async throws {
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

  public func clearContext(operationID: UUID) async throws {
    try checkCurrent(operationID)
    await runtime.clearContext()
    try checkCurrent(operationID)
  }

  public func contextUsage(
    for transcript: ModelFacingTranscript,
    attachments: [ChatAttachment],
    systemPrompt: String,
    operationID: UUID
  ) async throws -> ChatContextUsage {
    try checkCurrent(operationID)
    let usage = try await runtime.contextUsage(
      for: transcript,
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
