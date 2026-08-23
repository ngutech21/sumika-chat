import Foundation

struct DownloadModelResult: Sendable {
  let localPath: String
}

enum LocalModelDirectoryError: LocalizedError {
  case notFound(String)
  case unsafeManagedDirectory(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let path):
      "Model directory does not exist: \(path)"
    case .unsafeManagedDirectory(let path):
      "Refusing to delete a model directory outside the managed Models folder: \(path)"
    }
  }
}

struct ModelLifecycleCoordinator: Sendable {
  private let modelDownloader: any ModelDownloading
  private let runtimeOperations: RuntimeOperationCoordinator
  private let modelAvailability: @Sendable (ManagedModel) -> Bool
  private let modelDirectoryBaseURL: URL
  private let modelDirectoryRemover: @Sendable (URL) throws -> Void

  init(
    modelDownloader: any ModelDownloading,
    runtimeOperations: RuntimeOperationCoordinator,
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool = Self.defaultModelAvailability,
    modelDirectoryBaseURL: URL = LocalModelDirectory.defaultBaseURL,
    modelDirectoryRemover: @escaping @Sendable (URL) throws -> Void =
      Self.defaultModelDirectoryRemover
  ) {
    self.modelDownloader = modelDownloader
    self.runtimeOperations = runtimeOperations
    self.modelAvailability = modelAvailability
    self.modelDirectoryBaseURL = modelDirectoryBaseURL
    self.modelDirectoryRemover = modelDirectoryRemover
  }

  func ensureDefaultModelDirectoryExists() throws -> URL {
    try LocalModelDirectory.ensureDefaultBaseDirectoryExists()
  }

  func modelAvailabilitySnapshot(for models: [ManagedModel]) -> [ManagedModel.ID: Bool] {
    Dictionary(
      uniqueKeysWithValues: models.map { model in
        (model.id, isModelDownloaded(model))
      })
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> DownloadModelResult {
    _ = try await modelDownloader.download(model: model, progressHandler: progressHandler)
    return DownloadModelResult(localPath: model.localPath)
  }

  func loadModel(
    from directoryURL: URL,
    requestedContextTokenLimit: Int,
    supportsImageInput: Bool,
    reasoningTraceFormat: ReasoningTraceFormat,
    supportsHistoricalReasoningPreservation: Bool,
    reasoningEffort: ModelReasoningEffort?,
    thinkingBudgetPolicy: ThinkingBudgetPolicy,
    operationID: UUID
  ) async throws {
    try validateModelDirectory(directoryURL)
    try Task.checkCancellation()

    let configuration = ChatModelConfiguration(
      localModelDirectory: directoryURL,
      contextTokenLimit: effectiveContextTokenLimit(
        for: directoryURL,
        requestedContextTokenLimit: requestedContextTokenLimit
      ),
      supportsImageInput: supportsImageInput,
      reasoningTraceFormat: reasoningTraceFormat,
      supportsHistoricalReasoningPreservation: supportsHistoricalReasoningPreservation,
      reasoningEffort: reasoningEffort,
      thinkingBudgetPolicy: thinkingBudgetPolicy
    )
    try await runtimeOperations.load(configuration: configuration, operationID: operationID)
  }

  func unloadModel(operationID: UUID) async throws {
    try await runtimeOperations.unload(operationID: operationID)
  }

  func deleteDownloadedModel(
    _ model: ManagedModel,
    unloadOperationID: UUID?,
    runtimeUnloadWillBegin: @MainActor @Sendable () -> Void
  ) async throws {
    let modelDirectory = try validatedManagedModelDirectory(for: model)
    try Task.checkCancellation()

    if let unloadOperationID {
      await runtimeUnloadWillBegin()
      try await runtimeOperations.unload(operationID: unloadOperationID)
      try Task.checkCancellation()
    }

    let modelDirectoryRemover = modelDirectoryRemover
    try await Task.detached {
      try modelDirectoryRemover(modelDirectory)
    }.value
  }

  func clearContext(operationID: UUID) async throws {
    try await runtimeOperations.clearContext(operationID: operationID)
  }

  func isModelDownloaded(_ model: ManagedModel) -> Bool {
    modelAvailability(model)
  }

  static func defaultModelAvailability(_ model: ManagedModel) -> Bool {
    let modelDirectory = model.localDirectoryURL
    let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: modelDirectory.path(percentEncoded: false),
        isDirectory: &isDirectory
      ), isDirectory.boolValue
    else {
      return false
    }

    return FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false))
  }

  static func defaultModelDirectoryRemover(_ modelDirectory: URL) throws {
    try FileManager.default.removeItem(at: modelDirectory)
  }

  private func validateModelDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    let path = url.path(percentEncoded: false)

    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw LocalModelDirectoryError.notFound(path)
    }
  }

  private func validatedManagedModelDirectory(for model: ManagedModel) throws -> URL {
    let baseURL = modelDirectoryBaseURL.standardizedFileURL
    let modelDirectory = baseURL.appending(
      path: model.localDirectoryName,
      directoryHint: .isDirectory
    ).standardizedFileURL
    let parentURL = modelDirectory.deletingLastPathComponent().standardizedFileURL

    guard
      !model.localDirectoryName.isEmpty,
      model.localDirectoryName == modelDirectory.lastPathComponent,
      modelDirectory != baseURL,
      parentURL == baseURL
    else {
      throw LocalModelDirectoryError.unsafeManagedDirectory(
        modelDirectory.path(percentEncoded: false)
      )
    }

    return modelDirectory
  }

  private func effectiveContextTokenLimit(
    for modelDirectory: URL,
    requestedContextTokenLimit: Int
  ) -> Int {
    let modelLimit = LocalModelDirectory.readContextTokenLimit(from: modelDirectory)
    let requestedLimit = max(requestedContextTokenLimit, 1)

    guard let modelLimit else {
      return requestedLimit
    }

    return min(requestedLimit, modelLimit)
  }
}
