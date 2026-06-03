import Foundation
import Testing

@testable import LocalCoderCore

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
  func settingsStoreDefaultsSelectedModelTo4B() async {
    let userDefaults = makeUserDefaults()
    let store = ModelSettingsStore(
      userDefaults: userDefaults,
      settingsURL: temporarySettingsURL()
    )

    let selectedModelID = await store.selectedModelID(
      availableModelIDs: Set(ManagedModelCatalog.models.map(\.id)))

    #expect(selectedModelID == "gemma3-4b")
  }

  @Test
  func settingsStorePersistsSelectedModelAndPerModelSettings() async throws {
    let userDefaultsSuiteName = makeUserDefaultsSuiteName()
    let settingsURL = temporarySettingsURL()
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(suiteName: userDefaultsSuiteName),
      settingsURL: settingsURL
    )
    let model = ManagedModelCatalog.model(id: "gemma3-1b")!
    let settings = StoredModelSettings(
      systemPrompt: "Use short answers.",
      generationSettings: ChatGenerationSettings(
        temperature: 0.4, topP: 0.8, topK: 20, maxTokens: 512),
      contextTokenLimit: 32_768
    )

    await store.setSelectedModelID(model.id)
    try await store.save(settings: settings, for: model)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(suiteName: userDefaultsSuiteName),
      settingsURL: settingsURL
    )
    #expect(
      await reloadedStore.selectedModelID(
        availableModelIDs: Set(ManagedModelCatalog.models.map(\.id)))
        == model.id)
    #expect(await reloadedStore.settings(for: model) == settings)
  }

  @Test
  func settingsStoreFallsBackToDefaultsForCorruptSettingsFile() async throws {
    let settingsURL = temporarySettingsURL()
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: settingsURL, atomically: true, encoding: .utf8)
    let store = ModelSettingsStore(userDefaults: makeUserDefaults(), settingsURL: settingsURL)

    let settings = await store.settings(for: ManagedModelCatalog.defaultModel)

    #expect(settings.systemPrompt == ChatPromptDefaults.codingSystemPrompt)
    #expect(settings.generationSettings == .codingDefault)
    #expect(settings.contextTokenLimit == ManagedModelCatalog.defaultModel.defaultContextTokenLimit)
  }

  @Test
  func settingsStorePreservesConcurrentSavesForDifferentModels() async throws {
    let settingsURL = temporarySettingsURL()
    let store = ModelSettingsStore(userDefaults: makeUserDefaults(), settingsURL: settingsURL)
    let firstModel = ManagedModelCatalog.model(id: "gemma3-1b")!
    let secondModel = ManagedModelCatalog.model(id: "gemma3-27b")!
    let firstSettings = StoredModelSettings(
      systemPrompt: "Use tiny-model defaults.",
      generationSettings: ChatGenerationSettings(
        temperature: 0.1, topP: 0.7, topK: 10, maxTokens: 256),
      contextTokenLimit: 16_384
    )
    let secondSettings = StoredModelSettings(
      systemPrompt: "Use large-model defaults.",
      generationSettings: ChatGenerationSettings(
        temperature: 0.3, topP: 0.9, topK: 30, maxTokens: 1024),
      contextTokenLimit: 131_072
    )

    async let firstSave: Void = store.save(settings: firstSettings, for: firstModel)
    async let secondSave: Void = store.save(settings: secondSettings, for: secondModel)
    _ = try await (firstSave, secondSave)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(), settingsURL: settingsURL)
    #expect(await reloadedStore.settings(for: firstModel) == firstSettings)
    #expect(await reloadedStore.settings(for: secondModel) == secondSettings)
  }

  private func makeUserDefaultsSuiteName() -> String {
    "local-coder-tests-\(UUID().uuidString)"
  }

  private func makeUserDefaults(suiteName: String? = nil) -> UserDefaults {
    let suiteName = suiteName ?? makeUserDefaultsSuiteName()
    return UserDefaults(suiteName: suiteName)!
  }

  private func temporarySettingsURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
  }
}
