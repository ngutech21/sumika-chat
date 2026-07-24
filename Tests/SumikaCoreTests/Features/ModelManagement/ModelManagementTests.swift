import Foundation
import Testing

@testable import SumikaCore

struct ModelManagementTests {
  @Test
  func supportsWorkspaceToolsTracksToolCallingPolicyEnabledFlag() {
    #expect(ManagedModelCatalog.defaultModel.supportsWorkspaceTools)

    let model = ManagedModel(
      id: "test-model",
      displayName: "Test model",
      detail: "Fixture model",
      huggingFaceRepoID: "example/test-model",
      localDirectoryName: "test-model",
      estimatedDownloadSize: "1 MB",
      isRecommended: false,
      requiresLargeMemory: false,
      stability: .experimental,
      toolCallingPolicy: .unsupported,
      supportsImageInput: false,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: 1024,
      enabled: true
    )

    #expect(!model.supportsWorkspaceTools)
    #expect(model.maxToolLoopIterations == 8)
  }

  @Test
  func catalogDeclaresReasoningTraceFormats() throws {
    #expect(ManagedModelCatalog.defaultModel.reasoningTraceFormat == .gemmaChannel)

    let qwen27B = try #require(ManagedModelCatalog.model(id: "qwen3.6-27B-4bit"))
    #expect(qwen27B.reasoningTraceFormat == .qwenThinkTags)

    let qwen35B = try #require(ManagedModelCatalog.model(id: "qwen3.6-35b-a3b-4bit"))
    #expect(qwen35B.reasoningTraceFormat == .qwenThinkTags)
  }

  @Test
  func catalogDeclaresToolLoopBudgetsByModelSize() throws {
    let smallModelIDs = [
      "gemma4-e4b-qat-4bit",
      "gemma4-12b-qat-4bit",
      "gemma4-26b-qat-4bit",
      "qwen3.6-27B-4bit",
      "qwen3.6-27B-8bit",
    ]
    for modelID in smallModelIDs {
      let model = try #require(ManagedModelCatalog.model(id: modelID))
      #expect(model.maxToolLoopIterations == 8)
    }

    let largeModelIDs = [
      "gemma4-31b-qat-4bit",
      "qwen3.6-35b-a3b-4bit",
      "qwen3.6-35b-a3b-8bit",
      "qwen3.6-40B-8bit-heretic",
    ]
    for modelID in largeModelIDs {
      let model = try #require(ManagedModelCatalog.model(id: modelID))
      #expect(model.maxToolLoopIterations == 12)
    }
  }

  @Test
  func settingsStorePersistsPerModelSettings() async throws {
    let settingsURL = temporarySettingsURL()
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL
    )
    let model = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let settings = StoredModelSettings(
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Use short conversational answers.",
          generationSettings: ChatGenerationSettings(
            temperature: 1.1, topP: 0.9, topK: 30, maxTokens: 768)),
        agent: ChatModeSettings(
          systemPrompt: "Use short coding steps.",
          generationSettings: ChatGenerationSettings(
            temperature: 0.4, topP: 0.8, topK: 20, maxTokens: 512, maxKVSize: 16_384))
      ),
      contextTokenLimit: 32_768
    )

    try await store.save(settings: settings, for: model)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL
    )
    #expect(await reloadedStore.settings(for: model) == settings)
  }

  @Test
  func restoreConfigurationReturnsNilWhenNoConfigurationExists() async throws {
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: temporarySettingsURL(),
      generationConfigPresetProvider: { _ in nil }
    )

    let restored = try await store.restoreConfiguration(
      availableModels: ManagedModelCatalog.models
    )

    #expect(restored == nil)
  }

  @Test
  func restoreConfigurationReturnsPersistedSelectionAndSettings() async throws {
    let userDefaultsSuiteName = makeUserDefaultsSuiteName()
    let settingsURL = temporarySettingsURL()
    let model = try #require(ManagedModelCatalog.model(id: "gemma4-26b-qat-4bit"))
    let settings = StoredModelSettings(
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Restored chat settings.",
          generationSettings: .chatDefault
        ),
        agent: ChatModeSettings(
          systemPrompt: "Restored agent settings.",
          generationSettings: .agentDefault
        )
      ),
      contextTokenLimit: 65_536
    )
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(suiteName: userDefaultsSuiteName),
      settingsURL: settingsURL
    )
    await store.setSelectedModelID(model.id)
    try await store.save(settings: settings, for: model)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(suiteName: userDefaultsSuiteName),
      settingsURL: settingsURL
    )
    let restored = try #require(
      try await reloadedStore.restoreConfiguration(
        availableModels: ManagedModelCatalog.models
      )
    )

    #expect(restored.model == model)
    #expect(restored.settings == settings)
  }

  @Test
  func restoreConfigurationRejectsCorruptSettingsFile() async throws {
    let settingsURL = temporarySettingsURL()
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: settingsURL, atomically: true, encoding: .utf8)
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigPresetProvider: { _ in nil }
    )

    await #expect(throws: ModelSettingsRestoreError.self) {
      try await store.restoreConfiguration(availableModels: ManagedModelCatalog.models)
    }
  }

  @Test
  func restoreConfigurationRejectsUnavailableSelectedModel() async throws {
    let userDefaults = makeUserDefaults()
    userDefaults.set("removed-model", forKey: "selectedModelID")
    let store = ModelSettingsStore(
      userDefaults: userDefaults,
      settingsURL: temporarySettingsURL(),
      generationConfigPresetProvider: { _ in nil }
    )

    await #expect(throws: ModelSettingsRestoreError.self) {
      try await store.restoreConfiguration(availableModels: ManagedModelCatalog.models)
    }
  }

  @Test
  func settingsStoreFallsBackToDefaultsForCorruptSettingsFile() async throws {
    let settingsURL = temporarySettingsURL()
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: settingsURL, atomically: true, encoding: .utf8)
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigPresetProvider: { _ in nil }
    )

    let settings = await store.settings(for: ManagedModelCatalog.defaultModel)

    #expect(settings.modeSettings == ManagedModelCatalog.defaultModel.defaultModeSettings)
    #expect(settings.modeSettings.chat.systemPrompt == ChatPromptDefaults.chatSystemPrompt)
    #expect(settings.modeSettings.chat.generationSettings == .chatDefault)
    #expect(settings.modeSettings.agent.systemPrompt == ChatPromptDefaults.agentSystemPrompt)
    #expect(settings.modeSettings.agent.generationSettings == .agentDefault)
    #expect(settings.contextTokenLimit == ManagedModelCatalog.defaultModel.defaultContextTokenLimit)
  }

  @Test
  func settingsStorePreservesConcurrentSavesForDifferentModels() async throws {
    let settingsURL = temporarySettingsURL()
    let store = ModelSettingsStore(userDefaults: makeUserDefaults(), settingsURL: settingsURL)
    let firstModel = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let secondModel = try #require(ManagedModelCatalog.model(id: "gemma4-26b-qat-4bit"))
    let firstSettings = StoredModelSettings(
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Use tiny-model chat defaults.",
          generationSettings: ChatGenerationSettings(
            temperature: 1.0, topP: 0.9, topK: 20, maxTokens: 512)),
        agent: ChatModeSettings(
          systemPrompt: "Use tiny-model agent defaults.",
          generationSettings: ChatGenerationSettings(
            temperature: 0.1, topP: 0.7, topK: 10, maxTokens: 256))
      ),
      contextTokenLimit: 16_384
    )
    let secondSettings = StoredModelSettings(
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Use large-model chat defaults.",
          generationSettings: ChatGenerationSettings(
            temperature: 1.2, topP: 0.95, topK: 40, maxTokens: 2048)),
        agent: ChatModeSettings(
          systemPrompt: "Use large-model agent defaults.",
          generationSettings: ChatGenerationSettings(
            temperature: 0.3, topP: 0.9, topK: 30, maxTokens: 1024))
      ),
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
    "sumika-tests-\(UUID().uuidString)"
  }

  private func makeUserDefaults(suiteName: String? = nil) -> UserDefaults {
    let suiteName = suiteName ?? makeUserDefaultsSuiteName()
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Expected test UserDefaults suite to be available.")
      return .standard
    }
    return userDefaults
  }

  private func temporarySettingsURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "sumika-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
  }
}
