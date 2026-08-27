import Dispatch
import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-model-management-tests"))
struct ModelManagementTests {
  @Test
  func generationConfigReadDoesNotBlockOtherStoreOperations() async throws {
    let providerStarted = DispatchSemaphore(value: 0)
    let releaseProvider = DispatchSemaphore(value: 0)
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: try temporarySettingsURL(),
      generationConfigProvider: { _ in
        providerStarted.signal()
        _ = releaseProvider.wait(timeout: .now() + 2)
        return nil
      }
    )
    let settingsTask = Task {
      await store.settings(for: ManagedModelCatalog.defaultModel)
    }
    defer { releaseProvider.signal() }
    let didStartProvider = await Task.detached {
      waitForSemaphore(providerStarted, timeout: .now() + 1)
    }.value
    try #require(didStartProvider)

    try await withTestTimeout(.milliseconds(250)) {
      await store.setSelectedModelID("replacement-model")
    }

    releaseProvider.signal()
    _ = await settingsTask.value
  }

  @Test
  func settingsStorePersistsOnlyChangedFieldsAsSchemaV3Overrides() async throws {
    let settingsURL = try temporarySettingsURL()
    let model = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let generationConfig = GenerationSettingsOverride(
      temperature: 1,
      topP: 0.95,
      topK: 64,
      presencePenalty: 1.5
    )
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in generationConfig }
    )
    let before = await store.settings(for: model)
    var previousSnapshot = before.modeSettings
    previousSnapshot.chat.generationSettings.topK = 7
    var after = previousSnapshot
    after.chat.generationSettings.temperature = 0
    after.chat.generationSettings.topK = 64

    let updated = try await store.apply(
      .modeSettingsChanged(from: previousSnapshot, updated: after),
      for: model
    )

    #expect(updated.modeSettings.chat.generationSettings.temperature == 0)
    #expect(updated.modeSettings.chat.generationSettings.topP == 0.95)
    #expect(updated.modeSettings.chat.generationSettings.presencePenalty == 1.5)

    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == 3)
    let modelSettings = try #require(object["modelSettings"] as? [String: Any])
    let persisted = try #require(modelSettings[model.id] as? [String: Any])
    let modeOverrides = try #require(persisted["modeOverrides"] as? [String: Any])
    let chat = try #require(modeOverrides["chat"] as? [String: Any])
    let generation = try #require(chat["generationSettings"] as? [String: Any])
    #expect(generation["temperature"] as? Double == 0)
    #expect(generation["topK"] as? Int == 64)
    #expect(generation["topP"] == nil)
    #expect(modeOverrides["agent"] == nil)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in generationConfig }
    )
    #expect(await reloadedStore.settings(for: model) == updated)
  }

  @Test
  func settingsStorePersistsExplicitMTPActivationPerMode() async throws {
    let settingsURL = try temporarySettingsURL()
    let model = try #require(
      ManagedModelCatalog.model(id: "Qwen3.6-27B-OptiQ-4bit")
    )
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in nil }
    )
    let before = await store.settings(for: model)
    var edited = before.modeSettings
    edited.agent.generationSettings.isMTPEnabled = true

    let updated = try await store.apply(
      .modeSettingsChanged(from: before.modeSettings, updated: edited),
      for: model
    )

    #expect(updated.modeSettings.agent.generationSettings.isMTPEnabled)
    #expect(updated.modeSettings.agent.generationSettings.temperature == 0)
    #expect(!updated.modeSettings.chat.generationSettings.isMTPEnabled)

    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    )
    let models = try #require(object["modelSettings"] as? [String: Any])
    let agentGeneration = try persistedGenerationSettings(
      modelID: model.id,
      mode: "agent",
      in: models
    )
    #expect(agentGeneration["isMTPEnabled"] as? Bool == true)
    #expect(agentGeneration["temperature"] as? Double == 0)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in nil }
    )
    #expect(await reloadedStore.settings(for: model) == updated)
  }

  @Test
  func settingsStoreMigratesSchemaV1SnapshotsAsExplicitOverrides() async throws {
    let settingsURL = try temporarySettingsURL()
    let model = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let legacySettings = StoredModelSettings(
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Legacy chat prompt",
          generationSettings: ChatGenerationSettings(
            temperature: 0.2,
            topP: 0.3,
            topK: 4,
            maxTokens: 500,
            repetitionPenalty: 1.1,
            repetitionContextSize: 42,
            presencePenalty: 0.4,
            reasoningSelection: .off
          )
        ),
        agent: ChatModeSettings(
          systemPrompt: "Legacy agent prompt",
          generationSettings: ChatGenerationSettings(
            temperature: 0.5,
            topP: 0.6,
            topK: 7,
            maxTokens: 800,
            repetitionPenalty: 1.2,
            repetitionContextSize: 84,
            presencePenalty: 0.8,
            reasoningSelection: .on
          )
        )
      ),
      contextTokenLimit: 12_345
    )
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(
      LegacyModelSettingsFile(modelSettings: [model.id: legacySettings])
    ).write(to: settingsURL, options: .atomic)
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in
        GenerationSettingsOverride(
          temperature: 1.8,
          topP: 0.99,
          topK: 99,
          repetitionPenalty: 1.9,
          presencePenalty: 1.9
        )
      }
    )

    let restored = try await store.restoreConfiguration(
      availableModels: ManagedModelCatalog.models
    )
    #expect(restored.settings == legacySettings)

    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == 3)
    let reloaded = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in
        GenerationSettingsOverride(temperature: 1.9, topP: 0.1, topK: 1)
      }
    )
    #expect(await reloaded.settings(for: model) == legacySettings)
  }

  @Test
  func settingsStoreDecodesPartialSchemaV2ModeOverrides() async throws {
    let settingsURL = try temporarySettingsURL()
    let model = ManagedModelCatalog.defaultModel
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(
      """
      {
        "schemaVersion": 2,
        "modelSettings": {
          "\(model.id)": {
            "modeOverrides": {
              "chat": { "systemPrompt": "Only this field is custom." }
            }
          }
        }
      }
      """.utf8
    ).write(to: settingsURL, options: .atomic)
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in nil }
    )

    let settings = await store.settings(for: model)

    #expect(settings.modeSettings.chat.systemPrompt == "Only this field is custom.")
    #expect(settings.modeSettings.chat.generationSettings.temperature == 1)
    #expect(settings.modeSettings.chat.generationSettings.topP == 0.95)
    #expect(settings.modeSettings.agent.systemPrompt == ChatPromptDefaults.agentSystemPrompt)
  }

  @Test
  func settingsStoreMigratesSchemaV2ReasoningBooleansPerModelAndMode() async throws {
    let settingsURL = try temporarySettingsURL()
    let qwen = try #require(ManagedModelCatalog.model(id: "qwen3.8-27B-OptiQ-4bit"))
    let binary = ManagedModelCatalog.defaultModel
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(
      """
      {
        "schemaVersion": 2,
        "modelSettings": {
          "\(qwen.id)": {
            "modeOverrides": {
              "chat": { "generationSettings": { "reasoningEnabled": true } },
              "agent": { "generationSettings": { "reasoningEnabled": false } }
            }
          },
          "\(binary.id)": {
            "modeOverrides": {
              "chat": { "generationSettings": { "reasoningEnabled": true } },
              "agent": { "generationSettings": { "reasoningEnabled": false } }
            }
          }
        }
      }
      """.utf8
    ).write(to: settingsURL, options: .atomic)
    let userDefaults = makeUserDefaults()
    let store = ModelSettingsStore(
      userDefaults: userDefaults,
      settingsURL: settingsURL,
      generationConfigProvider: { _ in nil }
    )
    await store.setSelectedModelID(qwen.id)

    let restored = try await store.restoreConfiguration(
      availableModels: ManagedModelCatalog.models
    )
    let binarySettings = await store.settings(for: binary)

    #expect(restored.model == qwen)
    #expect(
      restored.settings.modeSettings.chat.generationSettings.reasoningSelection
        == .effort(.medium)
    )
    #expect(restored.settings.modeSettings.agent.generationSettings.reasoningSelection == .off)
    #expect(binarySettings.modeSettings.chat.generationSettings.reasoningSelection == .on)
    #expect(binarySettings.modeSettings.agent.generationSettings.reasoningSelection == .off)

    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == 3)
    let models = try #require(object["modelSettings"] as? [String: Any])
    let qwenGeneration = try persistedGenerationSettings(
      modelID: qwen.id,
      mode: "chat",
      in: models
    )
    let binaryGeneration = try persistedGenerationSettings(
      modelID: binary.id,
      mode: "chat",
      in: models
    )
    #expect(qwenGeneration["reasoningSelection"] as? String == "medium")
    #expect(binaryGeneration["reasoningSelection"] as? String == "on")
    #expect(qwenGeneration["reasoningEnabled"] == nil)
    #expect(binaryGeneration["reasoningEnabled"] == nil)
  }

  @Test
  func modeAndContextResetsRemoveOnlyTheirOwnOverrides() async throws {
    let settingsURL = try temporarySettingsURL()
    let model = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in nil }
    )
    let recommended = await store.settings(for: model)
    var chatEdited = recommended.modeSettings
    chatEdited.chat.generationSettings.temperature = 0.2
    let afterChat = try await store.apply(
      .modeSettingsChanged(from: recommended.modeSettings, updated: chatEdited),
      for: model
    )
    var agentEdited = afterChat.modeSettings
    agentEdited.agent.generationSettings.topK = 9
    _ = try await store.apply(
      .modeSettingsChanged(from: afterChat.modeSettings, updated: agentEdited),
      for: model
    )
    _ = try await store.apply(.contextTokenLimitChanged(12_345), for: model)

    let afterChatReset = try await store.apply(.resetMode(.chat), for: model)
    #expect(afterChatReset.modeSettings.chat == recommended.modeSettings.chat)
    #expect(afterChatReset.modeSettings.agent.generationSettings.topK == 9)
    #expect(afterChatReset.contextTokenLimit == 12_345)

    let explicitlyDefaultContext = try await store.apply(
      .contextTokenLimitChanged(model.defaultContextTokenLimit),
      for: model
    )
    #expect(explicitlyDefaultContext.contextTokenLimit == model.defaultContextTokenLimit)
    let explicitDefaultObject = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    )
    let explicitDefaultModels = try #require(
      explicitDefaultObject["modelSettings"] as? [String: Any]
    )
    let explicitDefaultSettings = try #require(
      explicitDefaultModels[model.id] as? [String: Any]
    )
    #expect(
      explicitDefaultSettings["contextTokenLimitOverride"] as? Int
        == model.defaultContextTokenLimit
    )

    let afterContextReset = try await store.apply(.resetContextTokenLimit, for: model)
    #expect(afterContextReset.contextTokenLimit == model.defaultContextTokenLimit)
    #expect(afterContextReset.modeSettings.agent.generationSettings.topK == 9)
  }

  @Test
  func catalogGroupsModelsByPrimaryUserGoal() {
    let modelsByGroup = Dictionary(grouping: ManagedModelCatalog.models, by: \.group)

    #expect(
      Set(modelsByGroup[.everydayChat, default: []].map(\.id)) == [
        "gemma4-e4b-qat-4bit",
        "gemma4-12b-qat-4bit",
      ])
    #expect(
      Set(modelsByGroup[.coding, default: []].map(\.id)) == [
        "gemma4-26b-qat-4bit",
        "gemma4-31b-qat-4bit",
        "qwen3.6-35b-a3b-4bit",
        "qwen3.6-35b-a3b-optiq-4bit",
        "qwen3.6-35b-a3b-8bit",
        "qwen3.6-27B-4bit",
        "Qwen3.6-27B-OptiQ-4bit",
        "qwen3.6-27B-8bit",
        "qwen3.8-27B-OptiQ-4bit",
      ])
    #expect(
      Set(modelsByGroup[.specialized, default: []].map(\.id)) == [
        "qwen3.6-40B-8bit-heretic"
      ])
  }

  @Test
  func catalogMarksOneBestModelForEverydayChatAndCoding() {
    let bestModels = ManagedModelCatalog.models.filter {
      $0.recommendation == .bestForGroup
    }

    #expect(bestModels.map(\.id) == ["gemma4-12b-qat-4bit", "qwen3.8-27B-OptiQ-4bit"])
  }

  @Test
  func catalogExposesSelectableReasoningEffortOnlyForQwen38() throws {
    let qwen38 = try #require(ManagedModelCatalog.model(id: "qwen3.8-27B-OptiQ-4bit"))

    #expect(
      qwen38.reasoningCapability
        == .selectableEffort(supported: [.low, .medium, .xhigh], defaultValue: .medium)
    )
    #expect(
      ManagedModelCatalog.models
        .filter { $0.id != qwen38.id }
        .allSatisfy { $0.reasoningCapability == .toggle }
    )
    #expect(ManagedModelCatalog.models.allSatisfy { $0.reasoningCapability.hasValidOptions })
  }

  @Test
  func catalogAssignsVersionedFamilyProfilesAcrossQuantizations() {
    let profilesByID = Dictionary(
      uniqueKeysWithValues: ManagedModelCatalog.models.compactMap { model in
        model.generationProfile.map { (model.id, $0) }
      }
    )

    for modelID in [
      "gemma4-e4b-qat-4bit",
      "gemma4-12b-qat-4bit",
      "gemma4-26b-qat-4bit",
      "gemma4-31b-qat-4bit",
    ] {
      #expect(profilesByID[modelID] == .gemma4)
    }
    for modelID in [
      "qwen3.6-35b-a3b-4bit",
      "qwen3.6-35b-a3b-optiq-4bit",
      "qwen3.6-35b-a3b-8bit",
      "qwen3.6-27B-4bit",
      "Qwen3.6-27B-OptiQ-4bit",
      "qwen3.6-27B-8bit",
      "qwen3.6-40B-8bit-heretic",
    ] {
      #expect(profilesByID[modelID] == .qwen36)
    }
    #expect(profilesByID["qwen3.8-27B-OptiQ-4bit"] == .qwen38)
  }

  @Test
  func bundledMTPDrafterIsEnabledOnlyForApprovedCatalogModels() {
    let enabledModelIDs = ManagedModelCatalog.models
      .filter(\.usesBundledMTPDrafter)
      .map(\.id)

    #expect(
      enabledModelIDs == [
        "qwen3.6-35b-a3b-optiq-4bit",
        "Qwen3.6-27B-OptiQ-4bit",
      ]
    )
  }

  @Test
  func managedModelDefaultsBundledMTPDrafterToDisabled() {
    let fixture = ManagedModel(
      id: "test-model",
      displayName: "Test model",
      detail: "Fixture model",
      huggingFaceRepoID: "example/test-model",
      localDirectoryName: "test-model",
      estimatedDownloadSize: "1 MB",
      group: .specialized,
      requiresLargeMemory: false,
      stability: .experimental,
      supportsImageInput: false,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: 1024
    )
    #expect(!fixture.usesBundledMTPDrafter)
  }

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
      group: .specialized,
      requiresLargeMemory: false,
      stability: .experimental,
      toolCallingPolicy: ToolCallingPolicy(
        isEnabled: false,
        allowsMultipleToolCalls: false
      ),
      supportsImageInput: false,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: 1024
    )

    #expect(!model.supportsWorkspaceTools)
  }

  @Test
  func settingsStoreUsesQwen36ProfileWhenNoSettingsAreSaved() async throws {
    let model = try #require(ManagedModelCatalog.model(id: "qwen3.6-35b-a3b-8bit"))
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: try temporarySettingsURL(),
      generationConfigProvider: { _ in
        GenerationSettingsOverride(temperature: 1, topP: 0.95, topK: 20)
      }
    )

    let settings = await store.settings(for: model)
    let chat = settings.modeSettings.chat.generationSettings
    let agent = settings.modeSettings.agent.generationSettings

    #expect(chat.temperature == 0.7)
    #expect(chat.topP == 0.9)
    #expect(chat.topK == 0)
    #expect(chat.maxTokens == 32_768)
    #expect(chat.presencePenalty == 0)
    #expect(chat.repetitionPenalty == 1)
    #expect(agent.temperature == 0.6)
    #expect(agent.topP == 0.95)
    #expect(agent.topK == 20)
    #expect(agent.maxTokens == 32_768)
    #expect(agent.presencePenalty == 0)
    #expect(agent.repetitionPenalty == 1)
  }

  @Test
  func settingsStorePersistsPerModelSettings() async throws {
    let settingsURL = try temporarySettingsURL()
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
            temperature: 1.1, topP: 0.9, topK: 30, maxTokens: 768, minP: 0.17)),
        agent: ChatModeSettings(
          systemPrompt: "Use short coding steps.",
          generationSettings: ChatGenerationSettings(
            temperature: 0.4, topP: 0.8, topK: 20, maxTokens: 512, minP: 0.08))
      ),
      contextTokenLimit: 32_768
    )

    try await persist(settings, for: model, in: store)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL
    )
    #expect(await reloadedStore.settings(for: model) == settings)
  }

  @Test
  func restoreConfigurationResolvesDefaultModelWhenNoConfigurationExists() async throws {
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: try temporarySettingsURL(),
      generationConfigProvider: { _ in nil }
    )

    let restored = try await store.restoreConfiguration(
      availableModels: ManagedModelCatalog.models
    )

    #expect(restored.model == ManagedModelCatalog.defaultModel)
    #expect(
      restored.settings
        == ModelSettingsResolver.settings(
          for: ManagedModelCatalog.defaultModel,
          generationConfig: nil,
          userOverrides: ModelSettingsOverrides()
        )
    )
  }

  @Test
  func restoreConfigurationReturnsPersistedSelectionAndSettings() async throws {
    let userDefaultsSuiteName = makeUserDefaultsSuiteName()
    let settingsURL = try temporarySettingsURL()
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
    try await persist(settings, for: model, in: store)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(suiteName: userDefaultsSuiteName),
      settingsURL: settingsURL
    )
    let restored = try await reloadedStore.restoreConfiguration(
      availableModels: ManagedModelCatalog.models
    )

    #expect(restored.model == model)
    #expect(restored.settings == settings)
  }

  @Test
  func restoreConfigurationRejectsCorruptSettingsFile() async throws {
    let settingsURL = try temporarySettingsURL()
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: settingsURL, atomically: true, encoding: .utf8)
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in nil }
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
      settingsURL: try temporarySettingsURL(),
      generationConfigProvider: { _ in nil }
    )

    await #expect(throws: ModelSettingsRestoreError.self) {
      try await store.restoreConfiguration(availableModels: ManagedModelCatalog.models)
    }
  }

  @Test
  func settingsStoreFallsBackToDefaultsForCorruptSettingsFile() async throws {
    let settingsURL = try temporarySettingsURL()
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: settingsURL, atomically: true, encoding: .utf8)
    let store = ModelSettingsStore(
      userDefaults: makeUserDefaults(),
      settingsURL: settingsURL,
      generationConfigProvider: { _ in nil }
    )

    let settings = await store.settings(for: ManagedModelCatalog.defaultModel)
    let expected = ModelSettingsResolver.settings(
      for: ManagedModelCatalog.defaultModel,
      generationConfig: nil,
      userOverrides: ModelSettingsOverrides()
    )

    #expect(settings == expected)
    #expect(settings.modeSettings.chat.systemPrompt == ChatPromptDefaults.chatSystemPrompt)
    #expect(settings.modeSettings.agent.systemPrompt == ChatPromptDefaults.agentSystemPrompt)
    #expect(settings.contextTokenLimit == ManagedModelCatalog.defaultModel.defaultContextTokenLimit)
  }

  @Test
  func settingsStorePreservesConcurrentSavesForDifferentModels() async throws {
    let settingsURL = try temporarySettingsURL()
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

    async let firstSave: Void = persist(firstSettings, for: firstModel, in: store)
    async let secondSave: Void = persist(secondSettings, for: secondModel, in: store)
    _ = try await (firstSave, secondSave)

    let reloadedStore = ModelSettingsStore(
      userDefaults: makeUserDefaults(), settingsURL: settingsURL)
    #expect(await reloadedStore.settings(for: firstModel) == firstSettings)
    #expect(await reloadedStore.settings(for: secondModel) == secondSettings)
  }

  private func makeUserDefaultsSuiteName() -> String {
    "sumika-tests-\(UUID().uuidString)"
  }

  private func persistedGenerationSettings(
    modelID: String,
    mode: String,
    in models: [String: Any]
  ) throws -> [String: Any] {
    let model = try #require(models[modelID] as? [String: Any])
    let overrides = try #require(model["modeOverrides"] as? [String: Any])
    let modeSettings = try #require(overrides[mode] as? [String: Any])
    return try #require(modeSettings["generationSettings"] as? [String: Any])
  }

  private func makeUserDefaults(suiteName: String? = nil) -> UserDefaults {
    let suiteName = suiteName ?? makeUserDefaultsSuiteName()
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Expected test UserDefaults suite to be available.")
      return .standard
    }
    return userDefaults
  }

  private func temporarySettingsURL() throws -> URL {
    try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
  }

  private func persist(
    _ settings: StoredModelSettings,
    for model: ManagedModel,
    in store: ModelSettingsStore
  ) async throws {
    let previous = await store.settings(for: model)
    _ = try await store.apply(
      .modeSettingsChanged(from: previous.modeSettings, updated: settings.modeSettings),
      for: model
    )
    _ = try await store.apply(
      .contextTokenLimitChanged(settings.contextTokenLimit),
      for: model
    )
  }
}

private func waitForSemaphore(
  _ semaphore: DispatchSemaphore,
  timeout: DispatchTime
) -> Bool {
  semaphore.wait(timeout: timeout) == .success
}

private struct LegacyModelSettingsFile: Encodable {
  let modelSettings: [String: StoredModelSettings]
}
