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

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "local-coder-tests-\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
  }

  private func temporarySettingsURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
  }
}
