import Foundation

nonisolated struct StoredModelSettings: Codable, Equatable, Sendable {
  var systemPrompt: String
  var generationSettings: ChatGenerationSettings
  var contextTokenLimit: Int

  init(
    systemPrompt: String = ChatPromptDefaults.codingSystemPrompt,
    generationSettings: ChatGenerationSettings = .codingDefault,
    contextTokenLimit: Int = ManagedModelCatalog.defaultContextTokenLimit
  ) {
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.contextTokenLimit = contextTokenLimit
  }

  private enum CodingKeys: String, CodingKey {
    case systemPrompt
    case generationSettings
    case contextTokenLimit
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    generationSettings = try container.decode(
      ChatGenerationSettings.self, forKey: .generationSettings)
    contextTokenLimit =
      try container.decodeIfPresent(Int.self, forKey: .contextTokenLimit)
      ?? ManagedModelCatalog.defaultContextTokenLimit
  }
}

nonisolated protocol ModelSettingsStoring: Sendable {
  func selectedModelID(availableModelIDs: Set<String>) async -> String
  func setSelectedModelID(_ modelID: String) async
  func settings(for model: ManagedModel) async -> StoredModelSettings
  func save(settings: StoredModelSettings, for model: ManagedModel) async throws
}

nonisolated private struct UserDefaultsBox: @unchecked Sendable {
  let userDefaults: UserDefaults
}

actor ModelSettingsStore: ModelSettingsStoring {
  private struct SettingsFile: Codable {
    var modelSettings: [String: StoredModelSettings]
  }

  nonisolated private let userDefaultsBox: UserDefaultsBox
  nonisolated private let settingsURL: URL
  nonisolated private let selectedModelKey = "selectedModelID"

  init(
    userDefaults: UserDefaults = .standard,
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
  ) {
    self.userDefaultsBox = UserDefaultsBox(userDefaults: userDefaults)
    self.settingsURL = settingsURL
  }

  func selectedModelID(availableModelIDs: Set<String>) async -> String {
    guard
      let storedID = userDefaultsBox.userDefaults.string(forKey: selectedModelKey),
      availableModelIDs.contains(storedID)
    else {
      return ManagedModelCatalog.defaultModelID
    }

    return storedID
  }

  func setSelectedModelID(_ modelID: String) async {
    userDefaultsBox.userDefaults.set(modelID, forKey: selectedModelKey)
  }

  func settings(for model: ManagedModel) async -> StoredModelSettings {
    guard let stored = readSettingsFile().modelSettings[model.id] else {
      return StoredModelSettings(
        systemPrompt: model.defaultSystemPrompt,
        generationSettings: model.defaultGenerationSettings,
        contextTokenLimit: model.defaultContextTokenLimit
      )
    }

    return stored
  }

  func save(settings: StoredModelSettings, for model: ManagedModel) async throws {
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

  private func readSettingsFile() -> SettingsFile {
    guard
      let data = try? Data(contentsOf: settingsURL),
      let decoded = try? JSONDecoder().decode(SettingsFile.self, from: data)
    else {
      return SettingsFile(modelSettings: [:])
    }

    return decoded
  }
}
