import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ModelRuntimeControllerTests {
  @Test
  func initializesSelectedModelFromStore() async throws {
    let store = RuntimeFakeModelSettingsStore()
    let selectedModel = try #require(ManagedModelCatalog.model(id: "gemma4-e2b"))
    let settings = StoredModelSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2, topP: 0.7, topK: 10, maxTokens: 256),
      contextTokenLimit: 16_384
    )
    store.selectedModelIDValue = selectedModel.id
    store.settingsByModelID[selectedModel.id] = settings
    let controller = await makeController(modelSettingsStore: store)

    #expect(controller.selectedModelID == selectedModel.id)
    #expect(controller.selectedModel.id == selectedModel.id)
    #expect(controller.modelPath == selectedModel.localPath)
    #expect(controller.modelContextTokenLimit == settings.contextTokenLimit)
  }

  @Test
  func selectingModelPersistsSelectionAndPublishesSettings() async throws {
    let store = RuntimeFakeModelSettingsStore()
    let selectedModel = try #require(ManagedModelCatalog.model(id: "gemma4-e2b"))
    let settings = StoredModelSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2, topP: 0.7, topK: 10, maxTokens: 256),
      contextTokenLimit: 16_384
    )
    store.settingsByModelID[selectedModel.id] = settings
    let controller = await makeController(modelSettingsStore: store)
    var publishedSettings: StoredModelSettings?
    controller.onModelDidChange = { publishedSettings = $0 }

    controller.selectModel(selectedModel)

    try await waitUntil { publishedSettings == settings }
    #expect(controller.selectedModelID == selectedModel.id)
    #expect(controller.modelPath == selectedModel.localPath)
    #expect(controller.modelContextTokenLimit == settings.contextTokenLimit)
    #expect(store.selectedModelIDValue == selectedModel.id)
    #expect(publishedSettings == settings)
  }

  @Test
  func selectingModelRefreshesSelectedModelAvailability() async throws {
    let selectedModel = try #require(ManagedModelCatalog.model(id: "gemma4-e2b"))
    let controller = await makeController(modelAvailability: { $0.id == selectedModel.id })
    controller.modelAvailabilitySnapshot[selectedModel.id] = false

    controller.selectModel(selectedModel)

    #expect(controller.isModelDownloaded(selectedModel))
  }

  @Test
  func downloadSelectedModelUpdatesDownloadState() async throws {
    let downloader = RuntimeControllerFakeModelDownloader()
    let controller = await makeController(modelDownloader: downloader)

    controller.downloadSelectedModel()

    try await waitUntil { controller.downloadState == .downloaded }
    #expect(controller.downloadProgress == 1)
    #expect(downloader.downloadedModelID == ManagedModelCatalog.defaultModelID)
    #expect(controller.isModelDownloaded(ManagedModelCatalog.defaultModel))
  }

  @Test
  func downloadSelectedModelPublishesIntermediateProgress() async throws {
    let downloader = RuntimeControllerFakeModelDownloader(progressFractions: [0.25, 1])
    let controller = await makeController(modelDownloader: downloader)

    controller.downloadSelectedModel()

    try await waitUntil { controller.downloadProgress == 0.25 }
    #expect(controller.downloadState == .downloading(progress: 0.25))

    try await waitUntil { controller.downloadState == .downloaded }
    #expect(controller.downloadProgress == 1)
  }

  @Test
  func downloadSelectedModelPublishesFailureAndClearsProgress() async throws {
    let downloader = RuntimeControllerFakeModelDownloader(
      error: RuntimeControllerFakeDownloadError.failed)
    let controller = await makeController(modelDownloader: downloader)
    var errorMessage: String?
    controller.onError = { errorMessage = $0 }

    controller.downloadSelectedModel()

    try await waitUntil {
      controller.downloadState
        == .failed(RuntimeControllerFakeDownloadError.failed.localizedDescription)
    }
    #expect(controller.downloadProgress == nil)
    #expect(errorMessage == RuntimeControllerFakeDownloadError.failed.localizedDescription)
  }

  @Test
  func setModelDirectoryUpdatesPathWhenRuntimeIsNotLoaded() async throws {
    let controller = await makeController()
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)

    controller.setModelDirectory(modelDirectory)

    #expect(controller.modelPath == modelDirectory.path(percentEncoded: false))
    #expect(controller.modelState == .notLoaded)
  }

  @Test
  func saveSelectedModelSettingsPersistsCurrentRuntimeSettings() async throws {
    let store = RuntimeFakeModelSettingsStore()
    let controller = await makeController(modelSettingsStore: store)
    controller.modelContextTokenLimit = 12_288
    let generationSettings = ChatGenerationSettings(
      temperature: 0.3,
      topP: 0.85,
      topK: 40,
      maxTokens: 768,
      maxKVSize: 8192
    )

    controller.saveSelectedModelSettings(
      systemPrompt: "Use concise code review notes.",
      generationSettings: generationSettings
    )

    try await waitUntil { store.savedSettingsByModelID[controller.selectedModel.id] != nil }
    let savedSettings = store.savedSettingsByModelID[controller.selectedModel.id]
    #expect(savedSettings?.systemPrompt == "Use concise code review notes.")
    #expect(savedSettings?.generationSettings == generationSettings)
    #expect(savedSettings?.contextTokenLimit == 12_288)
  }

  @Test
  func loadSelectedModelResetsPathToSelectedModelDirectoryBeforeLoading() async throws {
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(runtime: runtime, modelPath: "/tmp/custom-model")
    controller.modelAvailabilitySnapshot[controller.selectedModel.id] = true
    let initialOperationID = controller.currentOperationID()

    controller.loadSelectedModel()

    #expect(controller.modelPath == controller.selectedModel.localPath)
    #expect(controller.currentOperationID() != initialOperationID)
    try await waitUntil { controller.modelState != .loading }
  }

  @Test
  func applyingSameSessionModelDoesNotCancelInFlightLoad() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerRaceLoadingRuntime()
    defer { Task { await runtime.releaseFirstLoad() } }
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()
    try await waitUntilAsync { await runtime.loadCount == 1 }
    let loadOperationID = controller.currentOperationID()

    let didResetRuntime = controller.applySessionModel(controller.selectedModel)

    #expect(!didResetRuntime)
    #expect(controller.currentOperationID() == loadOperationID)
    await runtime.releaseFirstLoad()
    try await waitUntil { controller.modelState == .ready }
    #expect(await runtime.loadCount == 1)
  }

  @Test
  func loadModelUsesDirectoryConfigurationAndUpdatesReadyState() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }

    let configuration = await runtime.loadedConfiguration
    #expect(configuration?.localModelDirectory == modelDirectory)
    #expect(configuration?.contextTokenLimit == 2048)
    #expect(configuration?.supportsImageInput == true)
  }

  @Test
  func loadModelPassesSelectedModelImageCapability() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerRecordingRuntime()
    let store = RuntimeFakeModelSettingsStore()
    store.selectedModelIDValue = "gemma4-e4b"
    let controller = await makeController(
      modelSettingsStore: store,
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }

    let configuration = await runtime.loadedConfiguration
    #expect(configuration?.supportsImageInput == true)
  }

  @Test
  func loadModelCapsContextLimitAtUserRequestedSetting() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"max_position_embeddings":131072}"#)
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }

    let configuration = await runtime.loadedConfiguration
    #expect(configuration?.contextTokenLimit == 16_384)
  }

  @Test
  func loadModelIgnoresCancelledEarlierOperationAfterNewLoadStarts() async throws {
    let firstModelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let secondModelDirectory = try makeModelDirectory(config: #"{"n_ctx":4096}"#)
    let runtime = RuntimeControllerRaceLoadingRuntime()
    defer { Task { await runtime.releaseFirstLoad() } }
    let controller = await makeController(
      runtime: runtime,
      modelPath: firstModelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()
    try await waitUntilAsync { await runtime.loadCount == 1 }

    controller.modelPath = secondModelDirectory.path(percentEncoded: false)
    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }
    try await waitUntilAsync { await runtime.loadCount == 2 }
    await runtime.releaseFirstLoad()
    try await waitUntilAsync { await runtime.didFinishFirstLoad }
    await Task.yield()

    #expect(controller.modelState == .ready)
    let configurations = await runtime.loadedConfigurations
    #expect(configurations.count == 2)
    #expect(configurations[0].localModelDirectory == firstModelDirectory)
    #expect(configurations[1].localModelDirectory == secondModelDirectory)
    #expect(configurations[1].contextTokenLimit == 4096)
  }

  @Test
  func staleUnloadDoesNotOverwriteRuntimeAfterSubsequentLoad() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerDelayedUnloadRuntime()
    defer { Task { await runtime.releaseUnload() } }
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )
    controller.modelState = .ready

    controller.unloadModel()
    try await waitUntilAsync { await runtime.didStartUnload }

    controller.loadModel()
    await Task.yield()
    #expect(await runtime.loadCount == 0)

    await runtime.releaseUnload()
    try await waitUntilAsync { await runtime.didFinishUnload }
    try await waitUntil { controller.modelState == .ready }

    #expect(await runtime.isLoaded)
  }

  @Test
  func unloadModelReleasesRuntimeAndResetsModelState() async throws {
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(runtime: runtime)
    controller.modelState = .ready

    controller.unloadModel()

    try await waitUntil { controller.modelState == .notLoaded }
    try await waitUntilAsync { await runtime.didUnload }

    #expect(await runtime.didUnload)
  }

  private func makeController(
    modelSettingsStore: RuntimeFakeModelSettingsStore =
      RuntimeFakeModelSettingsStore(),
    modelDownloader: RuntimeControllerFakeModelDownloader = RuntimeControllerFakeModelDownloader(),
    runtime: any ChatModelRuntime = RuntimeControllerRecordingRuntime(),
    modelPath: String? = nil,
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool = { _ in false }
  ) async -> ModelRuntimeController {
    let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
    let selectedModelID = await modelSettingsStore.selectedModelID(
      availableModelIDs: availableModelIDs)
    let selectedModel =
      ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
    let settings = await modelSettingsStore.settings(for: selectedModel)
    let runtimeOperations = RuntimeOperationCoordinator(runtime: runtime)
    let lifecycleCoordinator = ModelLifecycleCoordinator(
      modelDownloader: modelDownloader,
      runtimeOperations: runtimeOperations,
      modelAvailability: modelAvailability
    )
    return ModelRuntimeController(
      selectedModelID: selectedModel.id,
      modelPath: modelPath ?? selectedModel.localPath,
      modelContextTokenLimit: settings.contextTokenLimit,
      modelSettingsStore: modelSettingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: lifecycleCoordinator,
      resourceMonitor: RuntimeControllerFakeResourceMonitor(),
      initialOperationID: UUID()
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

  private func makeModelDirectory(config: String) throws -> URL {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "sumika-chat-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    try config.write(
      to: modelDirectory.appending(path: "config.json", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    return modelDirectory
  }

}

private final class RuntimeFakeModelSettingsStore: ModelSettingsStoring, @unchecked Sendable {
  var selectedModelIDValue = ManagedModelCatalog.defaultModelID
  var settingsByModelID: [String: StoredModelSettings] = [:]
  var savedSettingsByModelID: [String: StoredModelSettings] = [:]

  func selectedModelID(availableModelIDs: Set<String>) async -> String {
    availableModelIDs.contains(selectedModelIDValue)
      ? selectedModelIDValue : ManagedModelCatalog.defaultModelID
  }

  func setSelectedModelID(_ modelID: String) async {
    selectedModelIDValue = modelID
  }

  func settings(for model: ManagedModel) async -> StoredModelSettings {
    settingsByModelID[model.id]
      ?? StoredModelSettings(
        systemPrompt: model.defaultSystemPrompt,
        generationSettings: model.defaultGenerationSettings,
        contextTokenLimit: model.defaultContextTokenLimit
      )
  }

  func save(settings: StoredModelSettings, for model: ManagedModel) async throws {
    savedSettingsByModelID[model.id] = settings
  }
}

private final class RuntimeControllerFakeModelDownloader: ModelDownloading, @unchecked Sendable {
  var downloadedModelID: String?
  private let progressFractions: [Double]
  private let error: Error?

  init(progressFractions: [Double] = [1], error: Error? = nil) {
    self.progressFractions = progressFractions
    self.error = error
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    downloadedModelID = model.id
    for fraction in progressFractions {
      let progress = Progress(totalUnitCount: 100)
      progress.completedUnitCount = Int64(fraction * 100)
      await progressHandler(progress)
      try await Task.sleep(for: .milliseconds(20))
    }
    if let error {
      throw error
    }
    return model.localDirectoryURL
  }
}

private enum RuntimeControllerFakeDownloadError: LocalizedError {
  case failed

  var errorDescription: String? {
    "download failed"
  }
}

private actor RuntimeControllerRecordingRuntime: ChatModelRuntime {
  private(set) var loadedConfiguration: ChatModelConfiguration?
  private(set) var didUnload = false

  func load(configuration: ChatModelConfiguration) async throws {
    loadedConfiguration = configuration
  }

  func unload() async {
    didUnload = true
    loadedConfiguration = nil
  }

  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    reasoningEnabled: Bool
  ) async throws -> ChatContextUsage {
    ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private actor RuntimeControllerRaceLoadingRuntime: ChatModelRuntime {
  private var firstLoadContinuation: CheckedContinuation<Void, Never>?
  private(set) var loadedConfigurations: [ChatModelConfiguration] = []
  private(set) var didFinishFirstLoad = false

  var loadCount: Int {
    loadedConfigurations.count
  }

  func load(configuration: ChatModelConfiguration) async throws {
    loadedConfigurations.append(configuration)

    if loadedConfigurations.count == 1 {
      await withCheckedContinuation { continuation in
        firstLoadContinuation = continuation
        Task {
          try? await Task.sleep(for: .seconds(2))
          self.releaseFirstLoad()
        }
      }
      didFinishFirstLoad = true
      try Task.checkCancellation()
    }
  }

  func releaseFirstLoad() {
    firstLoadContinuation?.resume()
    firstLoadContinuation = nil
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    reasoningEnabled: Bool
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
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

private actor RuntimeControllerDelayedUnloadRuntime: ChatModelRuntime {
  private var unloadContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartUnload = false
  private(set) var didFinishUnload = false
  private(set) var isLoaded = true
  private(set) var loadCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
    loadCount += 1
    isLoaded = true
  }

  func unload() async {
    didStartUnload = true
    await withCheckedContinuation { continuation in
      unloadContinuation = continuation
      Task {
        try? await Task.sleep(for: .seconds(2))
        self.releaseUnload()
      }
    }
    isLoaded = false
    didFinishUnload = true
  }

  func releaseUnload() {
    unloadContinuation?.resume()
    unloadContinuation = nil
  }

  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    reasoningEnabled: Bool
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
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

private struct RuntimeControllerFakeResourceMonitor: ProcessResourceMonitoring {
  func currentUsage() async -> ProcessResourceUsage? {
    ProcessResourceUsage(memoryBytes: 0, cpuPercent: 0)
  }
}
