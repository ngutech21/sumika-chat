import Foundation
import Testing

@testable import local_coder

@MainActor
struct ModelRuntimeControllerTests {
  @Test
  func initializesSelectedModelFromStore() {
    let store = RuntimeFakeModelSettingsStore()
    let selectedModel = ManagedModelCatalog.model(id: "gemma3-1b")!
    let settings = StoredModelSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2, topP: 0.7, topK: 10, maxTokens: 256),
      contextTokenLimit: 16_384
    )
    store.selectedModelIDValue = selectedModel.id
    store.settingsByModelID[selectedModel.id] = settings
    let controller = makeController(modelSettingsStore: store)

    #expect(controller.selectedModelID == selectedModel.id)
    #expect(controller.selectedModel.id == selectedModel.id)
    #expect(controller.modelPath == selectedModel.localPath)
    #expect(controller.modelContextTokenLimit == settings.contextTokenLimit)
  }

  @Test
  func selectingModelPersistsSelectionAndPublishesSettings() {
    let store = RuntimeFakeModelSettingsStore()
    let selectedModel = ManagedModelCatalog.model(id: "gemma3-1b")!
    let settings = StoredModelSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2, topP: 0.7, topK: 10, maxTokens: 256),
      contextTokenLimit: 16_384
    )
    store.settingsByModelID[selectedModel.id] = settings
    let controller = makeController(modelSettingsStore: store)
    var publishedSettings: StoredModelSettings?
    controller.onModelDidChange = { publishedSettings = $0 }

    controller.selectModel(selectedModel)

    #expect(controller.selectedModelID == selectedModel.id)
    #expect(controller.modelPath == selectedModel.localPath)
    #expect(controller.modelContextTokenLimit == settings.contextTokenLimit)
    #expect(store.selectedModelIDValue == selectedModel.id)
    #expect(publishedSettings == settings)
  }

  @Test
  func downloadSelectedModelUpdatesDownloadState() async throws {
    let downloader = RuntimeControllerFakeModelDownloader()
    let controller = makeController(modelDownloader: downloader)

    controller.downloadSelectedModel()

    try await waitUntil { controller.downloadState == .downloaded }
    #expect(controller.downloadProgress == 1)
    #expect(downloader.downloadedModelID == ManagedModelCatalog.defaultModelID)
    #expect(controller.isModelDownloaded(ManagedModelCatalog.defaultModel))
  }

  @Test
  func downloadSelectedModelPublishesFailureAndClearsProgress() async throws {
    let downloader = RuntimeControllerFakeModelDownloader(
      error: RuntimeControllerFakeDownloadError.failed)
    let controller = makeController(modelDownloader: downloader)
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

  private func makeController(
    modelSettingsStore: RuntimeFakeModelSettingsStore =
      RuntimeFakeModelSettingsStore(),
    modelDownloader: RuntimeControllerFakeModelDownloader = RuntimeControllerFakeModelDownloader()
  ) -> ModelRuntimeController {
    let runtimeOperations = RuntimeOperationCoordinator(runtime: RuntimeControllerFakeRuntime())
    let lifecycleCoordinator = ModelLifecycleCoordinator(
      modelDownloader: modelDownloader,
      runtimeOperations: runtimeOperations
    )
    return ModelRuntimeController(
      modelSettingsStore: modelSettingsStore,
      modelDownloader: modelDownloader,
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
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class RuntimeFakeModelSettingsStore: ModelSettingsStoring, @unchecked Sendable {
  var selectedModelIDValue = ManagedModelCatalog.defaultModelID
  var settingsByModelID: [String: StoredModelSettings] = [:]
  var savedSettingsByModelID: [String: StoredModelSettings] = [:]

  func selectedModelID(availableModelIDs: Set<String>) -> String {
    availableModelIDs.contains(selectedModelIDValue)
      ? selectedModelIDValue : ManagedModelCatalog.defaultModelID
  }

  func setSelectedModelID(_ modelID: String) {
    selectedModelIDValue = modelID
  }

  func settings(for model: ManagedModel) -> StoredModelSettings {
    settingsByModelID[model.id]
      ?? StoredModelSettings(
        systemPrompt: model.defaultSystemPrompt,
        generationSettings: model.defaultGenerationSettings,
        contextTokenLimit: model.defaultContextTokenLimit
      )
  }

  func save(settings: StoredModelSettings, for model: ManagedModel) throws {
    savedSettingsByModelID[model.id] = settings
  }
}

private final class RuntimeControllerFakeModelDownloader: ModelDownloading, @unchecked Sendable {
  var downloadedModelID: String?
  private let error: Error?

  init(error: Error? = nil) {
    self.error = error
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    downloadedModelID = model.id
    let progress = Progress(totalUnitCount: 100)
    progress.completedUnitCount = 100
    await progressHandler(progress)
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

private actor RuntimeControllerFakeRuntime: ChatModelRuntime {
  func load(configuration: ChatModelConfiguration) async throws {}
  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private struct RuntimeControllerFakeResourceMonitor: ProcessResourceMonitoring {
  func currentUsage() async -> ProcessResourceUsage? {
    ProcessResourceUsage(memoryBytes: 0, cpuPercent: 0)
  }
}
