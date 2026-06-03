import Foundation

public struct LoadModelResult: Sendable {
  public let configuration: ChatModelConfiguration
  public let contextUsage: ChatContextUsage?
}

public struct DownloadModelResult: Sendable {
  public let localPath: String
}

public enum LocalModelDirectoryError: LocalizedError {
  case notFound(String)

  public var errorDescription: String? {
    switch self {
    case .notFound(let path):
      "Model directory does not exist: \(path)"
    }
  }
}

public struct ModelLifecycleCoordinator: Sendable {
  private let modelDownloader: any ModelDownloading
  private let runtimeOperations: RuntimeOperationCoordinator

  public init(
    modelDownloader: any ModelDownloading,
    runtimeOperations: RuntimeOperationCoordinator
  ) {
    self.modelDownloader = modelDownloader
    self.runtimeOperations = runtimeOperations
  }

  public func ensureDefaultModelDirectoryExists() throws -> URL {
    try LocalModelDirectory.ensureDefaultBaseDirectoryExists()
  }

  public func modelAvailabilitySnapshot(for models: [ManagedModel]) -> [ManagedModel.ID: Bool] {
    Dictionary(
      uniqueKeysWithValues: models.map { model in
        (model.id, isModelDownloaded(model))
      })
  }

  public func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> DownloadModelResult {
    _ = try await modelDownloader.download(model: model, progressHandler: progressHandler)
    return DownloadModelResult(localPath: model.localPath)
  }

  public func loadModel(
    from directoryURL: URL,
    requestedContextTokenLimit: Int,
    operationID: UUID
  ) async throws -> LoadModelResult {
    try validateModelDirectory(directoryURL)
    try Task.checkCancellation()

    let configuration = ChatModelConfiguration(
      localModelDirectory: directoryURL,
      contextTokenLimit: effectiveContextTokenLimit(
        for: directoryURL,
        requestedContextTokenLimit: requestedContextTokenLimit
      )
    )
    try await runtimeOperations.load(configuration: configuration, operationID: operationID)
    return LoadModelResult(configuration: configuration, contextUsage: nil)
  }

  public func unloadModel(operationID: UUID) async throws {
    try await runtimeOperations.unload(operationID: operationID)
  }

  public func clearContext(operationID: UUID) async throws {
    try await runtimeOperations.clearContext(operationID: operationID)
  }

  public func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    operationID: UUID
  ) async throws -> ChatContextUsage {
    try await runtimeOperations.contextUsage(
      for: messages,
      attachments: attachments,
      systemPrompt: systemPrompt,
      operationID: operationID
    )
  }

  private func isModelDownloaded(_ model: ManagedModel) -> Bool {
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
