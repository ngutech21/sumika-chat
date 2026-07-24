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

package protocol ModelSettingsStoring: Sendable {
  func setSelectedModelID(_ modelID: String) async
  func settings(for model: ManagedModel) async -> StoredModelSettings
  func save(settings: StoredModelSettings, for model: ManagedModel) async throws
}

nonisolated private struct UserDefaultsBox: @unchecked Sendable {
  package let userDefaults: UserDefaults
}

package actor ModelSettingsStore: ModelSettingsStoring {
  private struct SettingsFile: Codable {
    var modelSettings: [String: StoredModelSettings]

    init(modelSettings: [String: StoredModelSettings]) {
      self.modelSettings = modelSettings
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: ModelSettingsFileCodingKeys.self)
      modelSettings = try container.decodeIfPresent(
        [String: StoredModelSettings].self,
        forKey: .modelSettings,
        default: [:]
      )
    }
  }

  private let userDefaultsBox: UserDefaultsBox
  private let settingsURL: URL
  private let selectedModelKey = "selectedModelID"
  private let generationConfigPresetProvider:
    @Sendable (ManagedModel) -> ChatGenerationConfigPreset?

  package init(
    userDefaults: UserDefaults = .standard,
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "model-settings.json", directoryHint: .notDirectory),
    generationConfigPresetProvider:
      @escaping @Sendable (ManagedModel) ->
      ChatGenerationConfigPreset? = {
        LocalModelDirectory.readGenerationConfigPreset(from: $0.localDirectoryURL)
      }
  ) {
    self.userDefaultsBox = UserDefaultsBox(userDefaults: userDefaults)
    self.settingsURL = settingsURL
    self.generationConfigPresetProvider = generationConfigPresetProvider
  }

  package func setSelectedModelID(_ modelID: String) async {
    userDefaultsBox.userDefaults.set(modelID, forKey: selectedModelKey)
  }

  package func settings(for model: ManagedModel) async -> StoredModelSettings {
    guard let stored = readSettingsFile().modelSettings[model.id] else {
      return defaultSettings(for: model)
    }

    return stored
  }

  package func restoreConfiguration(
    availableModels: [ManagedModel]
  ) async throws -> RestoredModelConfiguration? {
    let storedSelection = userDefaultsBox.userDefaults.object(forKey: selectedModelKey)
    let storedModelID: String?
    if let storedSelection {
      guard let modelID = storedSelection as? String, !modelID.isEmpty else {
        throw ModelSettingsRestoreError.invalidSelectedModel(String(describing: storedSelection))
      }
      storedModelID = modelID
    } else {
      storedModelID = nil
    }

    let settingsFile = try readSettingsFileIfPresent()
    guard storedModelID != nil || settingsFile != nil else {
      return nil
    }

    let modelID = storedModelID ?? ManagedModelCatalog.defaultModelID
    guard let model = availableModels.first(where: { $0.id == modelID }) else {
      throw ModelSettingsRestoreError.invalidSelectedModel(modelID)
    }
    let settings = settingsFile?.modelSettings[model.id] ?? defaultSettings(for: model)
    return RestoredModelConfiguration(model: model, settings: settings)
  }

  /// Layers the model's own `generation_config.json` sampling preset onto the built-in
  /// defaults when the user has not saved per-model settings. Chat mode adopts the full
  /// preset (the model authors' recommendation). Agent mode adopts only the nucleus/top-k
  /// shape and keeps its conservative, loop-resistant temperature and penalties, since the
  /// recommended temperature (~1.0 for Gemma) would make tool calling unreliable.
  package static func applyingGenerationConfigPreset(
    _ preset: ChatGenerationConfigPreset?,
    to modeSettings: ChatModeSettingsSet
  ) -> ChatModeSettingsSet {
    guard let preset else {
      return modeSettings
    }
    var updated = modeSettings
    updated.chat.generationSettings = preset.applying(to: updated.chat.generationSettings)
    let agentSamplingShape = ChatGenerationConfigPreset(topP: preset.topP, topK: preset.topK)
    updated.agent.generationSettings = agentSamplingShape.applying(
      to: updated.agent.generationSettings)
    return updated
  }

  package func save(settings: StoredModelSettings, for model: ManagedModel) async throws {
    var file = readSettingsFile()
    file.modelSettings[model.id] = settings

    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(file)
    try data.write(to: settingsURL, options: .atomic)
  }

  private func defaultSettings(for model: ManagedModel) -> StoredModelSettings {
    StoredModelSettings(
      modeSettings: Self.applyingGenerationConfigPreset(
        generationConfigPresetProvider(model),
        to: model.defaultModeSettings
      ),
      contextTokenLimit: model.defaultContextTokenLimit
    )
  }

  private func readSettingsFile() -> SettingsFile {
    do {
      return try readSettingsFileIfPresent() ?? SettingsFile(modelSettings: [:])
    } catch {
      return SettingsFile(modelSettings: [:])
    }
  }

  private func readSettingsFileIfPresent() throws -> SettingsFile? {
    guard FileManager.default.fileExists(atPath: settingsURL.path(percentEncoded: false)) else {
      return nil
    }

    let data: Data
    do {
      data = try Data(contentsOf: settingsURL)
    } catch {
      throw ModelSettingsRestoreError.unreadableSettings(error.localizedDescription)
    }

    do {
      return try JSONDecoder().decode(SettingsFile.self, from: data)
    } catch {
      throw ModelSettingsRestoreError.invalidSettings(error.localizedDescription)
    }
  }
}
