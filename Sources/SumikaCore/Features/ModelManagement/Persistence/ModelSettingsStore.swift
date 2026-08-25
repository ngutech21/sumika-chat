import Foundation

package struct StoredModelSettings: Codable, Equatable, Sendable {
  package var modeSettings: ChatModeSettingsSet
  package var contextTokenLimit: Int

  package init(
    modeSettings: ChatModeSettingsSet = .defaultSettings,
    contextTokenLimit: Int = ManagedModelCatalog.defaultContextTokenLimit
  ) {
    self.modeSettings = modeSettings
    self.contextTokenLimit = contextTokenLimit
  }

  private enum CodingKeys: String, CodingKey {
    case modeSettings
    case systemPrompt
    case generationSettings
    case contextTokenLimit
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    contextTokenLimit = try container.decodeIfPresent(
      Int.self,
      forKey: .contextTokenLimit,
      default: ManagedModelCatalog.defaultContextTokenLimit
    )
    if let modeSettings = try container.decodeIfPresent(
      ChatModeSettingsSet.self,
      forKey: .modeSettings
    ) {
      self.modeSettings = modeSettings
      return
    }

    let systemPrompt = try container.decodeIfPresent(
      String.self,
      forKey: .systemPrompt,
      default: ChatPromptDefaults.agentSystemPrompt
    )
    let generationSettings = try container.decodeIfPresent(
      ChatGenerationSettings.self,
      forKey: .generationSettings,
      default: .agentDefault
    )
    let settings = ChatModeSettings(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings
    )
    modeSettings = ChatModeSettingsSet(chat: settings, agent: settings)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(modeSettings, forKey: .modeSettings)
    try container.encode(contextTokenLimit, forKey: .contextTokenLimit)
  }
}

private enum ModelSettingsFileCodingKeys: String, CodingKey {
  case schemaVersion
  case modelSettings
}

package struct RestoredModelConfiguration: Equatable, Sendable {
  package let model: ManagedModel
  package let settings: StoredModelSettings

  package init(model: ManagedModel, settings: StoredModelSettings) {
    self.model = model
    self.settings = settings
  }
}

package enum ModelSettingsRestoreError: LocalizedError, Equatable, Sendable {
  case invalidSelectedModel(String)
  case unreadableSettings(String)
  case invalidSettings(String)

  package var errorDescription: String? {
    switch self {
    case .invalidSelectedModel(let modelID):
      "The saved model “\(modelID)” is no longer available."
    case .unreadableSettings(let message):
      "Saved model settings could not be read: \(message)"
    case .invalidSettings(let message):
      "Saved model settings are invalid: \(message)"
    }
  }
}

package enum ModelSettingsMutation: Equatable, Sendable {
  case modeSettingsChanged(from: ChatModeSettingsSet, updated: ChatModeSettingsSet)
  case resetMode(WorkspaceInteractionMode)
  case contextTokenLimitChanged(Int)
  case resetContextTokenLimit
}

package protocol ModelSettingsStoring: Sendable {
  func setSelectedModelID(_ modelID: String) async
  func settings(for model: ManagedModel) async -> StoredModelSettings
  func apply(
    _ mutation: ModelSettingsMutation,
    for model: ManagedModel
  ) async throws -> StoredModelSettings
}

nonisolated private struct UserDefaultsBox: @unchecked Sendable {
  package let userDefaults: UserDefaults
}

package actor ModelSettingsStore: ModelSettingsStoring {
  private enum StoredModelSelection: Sendable {
    case missing
    case modelID(String)
    case invalid(String)
  }

  private struct PersistedModeOverrides: Codable {
    var chat: ModeSettingsOverride?
    var agent: ModeSettingsOverride?

    var hasValues: Bool {
      chat?.hasValues == true || agent?.hasValues == true
    }
  }

  private struct PersistedModelSettings: Codable {
    var modeOverrides: PersistedModeOverrides?
    var contextTokenLimitOverride: Int?

    init(
      modeOverrides: PersistedModeOverrides? = nil,
      contextTokenLimitOverride: Int? = nil
    ) {
      self.modeOverrides = modeOverrides
      self.contextTokenLimitOverride = contextTokenLimitOverride
    }

    init(legacy settings: StoredModelSettings) {
      modeOverrides = PersistedModeOverrides(
        chat: ModeSettingsOverride(
          systemPrompt: settings.modeSettings.chat.systemPrompt,
          generationSettings: GenerationSettingsOverride(
            overriding: settings.modeSettings.chat.generationSettings,
            includeMinP: false
          )
        ),
        agent: ModeSettingsOverride(
          systemPrompt: settings.modeSettings.agent.systemPrompt,
          generationSettings: GenerationSettingsOverride(
            overriding: settings.modeSettings.agent.generationSettings,
            includeMinP: false
          )
        )
      )
      contextTokenLimitOverride = settings.contextTokenLimit
    }

    var overrides: ModelSettingsOverrides {
      ModelSettingsOverrides(
        chat: modeOverrides?.chat,
        agent: modeOverrides?.agent,
        contextTokenLimit: contextTokenLimitOverride
      )
    }

    var hasValues: Bool {
      modeOverrides?.hasValues == true || contextTokenLimitOverride != nil
    }
  }

  private struct SettingsFile: Codable {
    static let schemaVersion = 2

    var modelSettings: [String: PersistedModelSettings]
    let requiresMigration: Bool

    init(modelSettings: [String: PersistedModelSettings]) {
      self.modelSettings = modelSettings
      requiresMigration = false
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: ModelSettingsFileCodingKeys.self)
      switch try container.decodeIfPresent(Int.self, forKey: .schemaVersion) {
      case nil:
        let legacy = try container.decodeIfPresent(
          [String: StoredModelSettings].self,
          forKey: .modelSettings,
          default: [:]
        )
        modelSettings = legacy.mapValues(PersistedModelSettings.init(legacy:))
        requiresMigration = true
      case Self.schemaVersion:
        modelSettings = try container.decodeIfPresent(
          [String: PersistedModelSettings].self,
          forKey: .modelSettings,
          default: [:]
        )
        requiresMigration = false
      case .some(let schemaVersion):
        throw DecodingError.dataCorruptedError(
          forKey: .schemaVersion,
          in: container,
          debugDescription: "Unsupported model settings schema version \(schemaVersion)."
        )
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: ModelSettingsFileCodingKeys.self)
      try container.encode(Self.schemaVersion, forKey: .schemaVersion)
      try container.encode(modelSettings, forKey: .modelSettings)
    }
  }

  private let userDefaultsBox: UserDefaultsBox
  private let settingsURL: URL
  private let selectedModelKey = "selectedModelID"
  private let generationConfigProvider: @Sendable (ManagedModel) -> GenerationSettingsOverride?
  private var settingsMutationTask: Task<Void, Never>?

  package init(
    userDefaults: UserDefaults = .standard,
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
  ) {
    self.userDefaultsBox = UserDefaultsBox(userDefaults: userDefaults)
    self.settingsURL = settingsURL
    self.generationConfigProvider = {
      LocalModelDirectory.readGenerationConfigPreset(from: $0.localDirectoryURL)
    }
  }

  init(
    userDefaults: UserDefaults,
    settingsURL: URL,
    generationConfigProvider:
      @escaping @Sendable (ManagedModel) ->
      GenerationSettingsOverride?
  ) {
    self.userDefaultsBox = UserDefaultsBox(userDefaults: userDefaults)
    self.settingsURL = settingsURL
    self.generationConfigProvider = generationConfigProvider
  }

  package func setSelectedModelID(_ modelID: String) async {
    let userDefaultsBox = userDefaultsBox
    let selectedModelKey = selectedModelKey
    await Task.detached(priority: .utility) {
      userDefaultsBox.userDefaults.set(modelID, forKey: selectedModelKey)
    }.value
  }

  package func settings(for model: ManagedModel) async -> StoredModelSettings {
    await settingsMutationTask?.value
    let settingsFile = await readSettingsFile()
    let generationConfig = await generationConfig(for: model)
    return resolvedSettings(
      for: model,
      persisted: settingsFile.modelSettings[model.id],
      generationConfig: generationConfig
    )
  }

  package func restoreConfiguration(
    availableModels: [ManagedModel]
  ) async throws -> RestoredModelConfiguration {
    await settingsMutationTask?.value
    let userDefaultsBox = userDefaultsBox
    let selectedModelKey = selectedModelKey
    let storedSelection = await Task.detached(priority: .utility) {
      guard let value = userDefaultsBox.userDefaults.object(forKey: selectedModelKey) else {
        return StoredModelSelection.missing
      }
      guard let modelID = value as? String, !modelID.isEmpty else {
        return StoredModelSelection.invalid(String(describing: value))
      }
      return StoredModelSelection.modelID(modelID)
    }.value
    let storedModelID: String?
    switch storedSelection {
    case .missing:
      storedModelID = nil
    case .modelID(let modelID):
      storedModelID = modelID
    case .invalid(let description):
      throw ModelSettingsRestoreError.invalidSelectedModel(description)
    }

    let settingsFile = try await readSettingsFileIfPresent()
    if let settingsFile, settingsFile.requiresMigration {
      try await write(settingsFile)
    }
    let modelID = storedModelID ?? ManagedModelCatalog.defaultModelID
    guard let model = availableModels.first(where: { $0.id == modelID }) else {
      throw ModelSettingsRestoreError.invalidSelectedModel(modelID)
    }
    let settings = resolvedSettings(
      for: model,
      persisted: settingsFile?.modelSettings[model.id],
      generationConfig: await generationConfig(for: model)
    )
    return RestoredModelConfiguration(model: model, settings: settings)
  }

  package func apply(
    _ mutation: ModelSettingsMutation,
    for model: ManagedModel
  ) async throws -> StoredModelSettings {
    let predecessor = settingsMutationTask
    let operation = Task { [self] in
      await predecessor?.value
      return try await applyMutation(mutation, for: model)
    }
    settingsMutationTask = Task {
      _ = try? await operation.value
    }
    return try await operation.value
  }

  private func applyMutation(
    _ mutation: ModelSettingsMutation,
    for model: ManagedModel
  ) async throws -> StoredModelSettings {
    var file = try await readSettingsFileIfPresent() ?? SettingsFile(modelSettings: [:])
    var persisted = file.modelSettings[model.id] ?? PersistedModelSettings()
    var modeOverrides = persisted.modeOverrides ?? PersistedModeOverrides()

    switch mutation {
    case .modeSettingsChanged(let previous, let updated):
      if previous.chat != updated.chat {
        var chat = modeOverrides.chat ?? ModeSettingsOverride()
        chat.recordChanges(
          from: previous.chat,
          to: updated.chat
        )
        modeOverrides.chat = chat.hasValues ? chat : nil
      }
      if previous.agent != updated.agent {
        var agent = modeOverrides.agent ?? ModeSettingsOverride()
        agent.recordChanges(
          from: previous.agent,
          to: updated.agent
        )
        modeOverrides.agent = agent.hasValues ? agent : nil
      }
    case .resetMode(.chat):
      modeOverrides.chat = nil
    case .resetMode(.agent):
      modeOverrides.agent = nil
    case .contextTokenLimitChanged(let contextTokenLimit):
      persisted.contextTokenLimitOverride = contextTokenLimit
    case .resetContextTokenLimit:
      persisted.contextTokenLimitOverride = nil
    }

    persisted.modeOverrides = modeOverrides.hasValues ? modeOverrides : nil
    if persisted.hasValues {
      file.modelSettings[model.id] = persisted
    } else {
      file.modelSettings.removeValue(forKey: model.id)
    }
    try await write(file)
    return resolvedSettings(
      for: model,
      persisted: file.modelSettings[model.id],
      generationConfig: await generationConfig(for: model)
    )
  }

  private func resolvedSettings(
    for model: ManagedModel,
    persisted: PersistedModelSettings?,
    generationConfig: GenerationSettingsOverride?
  ) -> StoredModelSettings {
    ModelSettingsResolver.settings(
      for: model,
      generationConfig: generationConfig,
      userOverrides: persisted?.overrides ?? ModelSettingsOverrides()
    )
  }

  private func generationConfig(for model: ManagedModel) async -> GenerationSettingsOverride? {
    let generationConfigProvider = generationConfigProvider
    return await Task.detached(priority: .utility) {
      generationConfigProvider(model)
    }.value
  }

  private func write(_ file: SettingsFile) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(file)
    let settingsURL = settingsURL
    try await Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(
        at: settingsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: settingsURL, options: .atomic)
    }.value
  }

  private func readSettingsFile() async -> SettingsFile {
    do {
      return try await readSettingsFileIfPresent() ?? SettingsFile(modelSettings: [:])
    } catch {
      return SettingsFile(modelSettings: [:])
    }
  }

  private func readSettingsFileIfPresent() async throws -> SettingsFile? {
    let settingsURL = settingsURL
    let data: Data?
    do {
      data = try await Task.detached(priority: .utility) {
        guard
          FileManager.default.fileExists(
            atPath: settingsURL.path(percentEncoded: false)
          )
        else {
          return nil
        }
        return try Data(contentsOf: settingsURL)
      }.value
    } catch {
      throw ModelSettingsRestoreError.unreadableSettings(error.localizedDescription)
    }
    guard let data else {
      return nil
    }

    do {
      return try JSONDecoder().decode(SettingsFile.self, from: data)
    } catch {
      throw ModelSettingsRestoreError.invalidSettings(error.localizedDescription)
    }
  }
}
