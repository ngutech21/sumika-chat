import Foundation

package struct DownloadModelResult: Sendable {
  package let localPath: String
}

package enum LocalModelDirectoryError: LocalizedError {
  case notFound(String)

  package var errorDescription: String? {
    switch self {
    case .notFound(let path):
      "Model directory does not exist: \(path)"
    }
  }
}

package struct ModelLifecycleCoordinator: Sendable {
  private let modelDownloader: any ModelDownloading
  private let runtimeOperations: RuntimeOperationCoordinator
  private let modelAvailability: @Sendable (ManagedModel) -> Bool

  init(
    modelDownloader: any ModelDownloading,
    runtimeOperations: RuntimeOperationCoordinator,
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool = Self.defaultModelAvailability
  ) {
    self.modelDownloader = modelDownloader
    self.runtimeOperations = runtimeOperations
    self.modelAvailability = modelAvailability
  }

  package func ensureDefaultModelDirectoryExists() throws -> URL {
    try LocalModelDirectory.ensureDefaultBaseDirectoryExists()
  }

  package func modelAvailabilitySnapshot(for models: [ManagedModel]) -> [ManagedModel.ID: Bool] {
    Dictionary(
      uniqueKeysWithValues: models.map { model in
        (model.id, isModelDownloaded(model))
      })
  }

  package func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> DownloadModelResult {
    _ = try await modelDownloader.download(model: model, progressHandler: progressHandler)
    return DownloadModelResult(localPath: model.localPath)
  }

  package func loadModel(
    from directoryURL: URL,
    requestedContextTokenLimit: Int,
    supportsImageInput: Bool,
    reasoningTraceFormat: ReasoningTraceFormat,
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
      reasoningTraceFormat: reasoningTraceFormat
    )
    try await runtimeOperations.load(configuration: configuration, operationID: operationID)
  }

  package func unloadModel(operationID: UUID) async throws {
    try await runtimeOperations.unload(operationID: operationID)
  }

  package func clearContext(operationID: UUID) async throws {
    try await runtimeOperations.clearContext(operationID: operationID)
  }

  func isModelDownloaded(_ model: ManagedModel) -> Bool {
    modelAvailability(model)
  }

  package static func defaultModelAvailability(_ model: ManagedModel) -> Bool {
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

  private func validateModelDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    let path = url.path(percentEncoded: false)

    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw LocalModelDirectoryError.notFound(path)
    }
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
