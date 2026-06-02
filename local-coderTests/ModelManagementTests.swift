import Foundation
import Testing

@testable import local_coder

@MainActor
struct ModelManagementTests {
  @Test
  func catalogContainsCuratedGemma3ModelsAndDefaultsTo4B() {
    let models = ManagedModelCatalog.models

    #expect(models.map(\.id) == ["gemma3-1b", "gemma3-4b", "gemma3-27b"])
    #expect(ManagedModelCatalog.defaultModelID == "gemma3-4b")
    #expect(ManagedModelCatalog.defaultModel.id == "gemma3-4b")
    #expect(ManagedModelCatalog.defaultModel.defaultContextTokenLimit == 65_536)
    #expect(ManagedModelCatalog.defaultModel.isRecommended)
    #expect(ManagedModelCatalog.model(id: "gemma3-27b")?.requiresLargeMemory == true)
    #expect(
      ManagedModelCatalog.model(id: "gemma3-4b")?.huggingFaceRepoID
        == "mlx-community/gemma-3-4b-it-qat-4bit")
  }

  @Test
  func settingsStoreDefaultsSelectedModelTo4B() {
    let userDefaults = makeUserDefaults()
    let store = ModelSettingsStore(
      userDefaults: userDefaults,
      settingsURL: temporarySettingsURL()
    )

    let selectedModelID = store.selectedModelID(
      availableModelIDs: Set(ManagedModelCatalog.models.map(\.id)))

    #expect(selectedModelID == "gemma3-4b")
  }

  @Test
  func settingsStorePersistsSelectedModelAndPerModelSettings() throws {
    let userDefaults = makeUserDefaults()
    let settingsURL = temporarySettingsURL()
    let store = ModelSettingsStore(userDefaults: userDefaults, settingsURL: settingsURL)
    let model = ManagedModelCatalog.model(id: "gemma3-1b")!
    let settings = StoredModelSettings(
      systemPrompt: "Use short answers.",
      generationSettings: ChatGenerationSettings(
        temperature: 0.4, topP: 0.8, topK: 20, maxTokens: 512),
      contextTokenLimit: 32_768
    )

    store.setSelectedModelID(model.id)
    try store.save(settings: settings, for: model)

    let reloadedStore = ModelSettingsStore(userDefaults: userDefaults, settingsURL: settingsURL)
    #expect(
      reloadedStore.selectedModelID(availableModelIDs: Set(ManagedModelCatalog.models.map(\.id)))
        == model.id)
    #expect(reloadedStore.settings(for: model) == settings)
  }

  @Test
  func settingsStoreFallsBackToDefaultsForCorruptSettingsFile() throws {
    let settingsURL = temporarySettingsURL()
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: settingsURL, atomically: true, encoding: .utf8)
    let store = ModelSettingsStore(userDefaults: makeUserDefaults(), settingsURL: settingsURL)

    let settings = store.settings(for: ManagedModelCatalog.defaultModel)

    #expect(settings.systemPrompt == ChatPromptDefaults.codingSystemPrompt)
    #expect(settings.generationSettings == .codingDefault)
    #expect(settings.contextTokenLimit == ManagedModelCatalog.defaultModel.defaultContextTokenLimit)
  }

  @Test
  func selectingModelLoadsPerModelSettingsAndPersistsSelection() {
    let store = FakeModelSettingsStore()
    let selectedModel = ManagedModelCatalog.model(id: "gemma3-1b")!
    let settings = StoredModelSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2, topP: 0.7, topK: 10, maxTokens: 256),
      contextTokenLimit: 16_384
    )
    store.settingsByModelID[selectedModel.id] = settings
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: ManagedModelCatalog.defaultModel.localPath,
      modelSettingsStore: store,
      modelDownloader: FakeModelDownloader()
    )

    controller.selectModel(selectedModel)

    #expect(controller.modelRuntime.selectedModelID == selectedModel.id)
    #expect(controller.modelRuntime.modelPath == selectedModel.localPath)
    #expect(controller.chatSession.systemPrompt == settings.systemPrompt)
    #expect(controller.chatSession.generationSettings == settings.generationSettings)
    #expect(controller.modelRuntime.modelContextTokenLimit == settings.contextTokenLimit)
    #expect(store.selectedModelIDValue == selectedModel.id)
  }

  @Test
  func downloadSelectedModelUpdatesDownloadState() async throws {
    let downloader = FakeModelDownloader()
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: ManagedModelCatalog.defaultModel.localPath,
      modelSettingsStore: FakeModelSettingsStore(),
      modelDownloader: downloader
    )

    controller.downloadSelectedModel()

    try await waitUntil { controller.modelRuntime.downloadState == .downloaded }
    #expect(controller.modelRuntime.downloadProgress == 1)
    #expect(downloader.downloadedModelID == ManagedModelCatalog.defaultModelID)
    #expect(controller.modelRuntime.isModelDownloaded(ManagedModelCatalog.defaultModel))
  }

  @Test
  func downloadSelectedModelPublishesIntermediateProgress() async throws {
    let downloader = FakeModelDownloader(progressFractions: [0.25, 1])
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: ManagedModelCatalog.defaultModel.localPath,
      modelSettingsStore: FakeModelSettingsStore(),
      modelDownloader: downloader
    )

    controller.downloadSelectedModel()

    try await waitUntil { controller.modelRuntime.downloadProgress == 0.25 }
    #expect(controller.modelRuntime.downloadState == .downloading(progress: 0.25))

    try await waitUntil { controller.modelRuntime.downloadState == .downloaded }
    #expect(controller.modelRuntime.downloadProgress == 1)
  }

  @Test
  func downloadSelectedModelPublishesFailureAndClearsProgress() async throws {
    let downloader = FakeModelDownloader(error: FakeModelDownloadError.failed)
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: ManagedModelCatalog.defaultModel.localPath,
      modelSettingsStore: FakeModelSettingsStore(),
      modelDownloader: downloader
    )

    controller.downloadSelectedModel()

    try await waitUntil {
      controller.modelRuntime.downloadState
        == .failed(FakeModelDownloadError.failed.localizedDescription)
    }
    #expect(controller.modelRuntime.downloadProgress == nil)
    #expect(controller.errorMessage == FakeModelDownloadError.failed.localizedDescription)
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "local-coder-tests-\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
  }

  private func temporarySettingsURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
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

private final class FakeModelSettingsStore: ModelSettingsStoring, @unchecked Sendable {
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

private final class FakeModelDownloader: ModelDownloading, @unchecked Sendable {
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

private enum FakeModelDownloadError: LocalizedError {
  case failed

  var errorDescription: String? {
    "download failed"
  }
}

private actor FakeChatModelRuntime: ChatModelRuntime {
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
