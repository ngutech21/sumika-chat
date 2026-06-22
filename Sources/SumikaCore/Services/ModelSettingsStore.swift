import Foundation

public struct StoredModelSettings: Codable, Equatable, Sendable {
  public var modeSettings: ChatModeSettingsSet
  public var contextTokenLimit: Int
  public var systemPrompt: String {
    modeSettings.agent.systemPrompt
  }
  public var generationSettings: ChatGenerationSettings {
    modeSettings.agent.generationSettings
  }

  public init(
    modeSettings: ChatModeSettingsSet = .defaultSettings,
    contextTokenLimit: Int = ManagedModelCatalog.defaultContextTokenLimit
  ) {
    self.modeSettings = modeSettings
    self.contextTokenLimit = contextTokenLimit
  }

  public init(
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    contextTokenLimit: Int = ManagedModelCatalog.defaultContextTokenLimit
  ) {
    let settings = ChatModeSettings(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings
    )
    self.modeSettings = ChatModeSettingsSet(chat: settings, agent: settings)
    self.contextTokenLimit = contextTokenLimit
  }

}

public protocol ModelSettingsStoring: Sendable {
  func selectedModelID(availableModelIDs: Set<String>) async -> String
  func setSelectedModelID(_ modelID: String) async
  func settings(for model: ManagedModel) async -> StoredModelSettings
  func save(settings: StoredModelSettings, for model: ManagedModel) async throws
}

nonisolated private struct UserDefaultsBox: @unchecked Sendable {
  public let userDefaults: UserDefaults
}

public actor ModelSettingsStore: ModelSettingsStoring {
  private struct SettingsFile: Codable {
    var modelSettings: [String: StoredModelSettings]
  }

  private let userDefaultsBox: UserDefaultsBox
  private let settingsURL: URL
  private let selectedModelKey = "selectedModelID"

  public init(
    userDefaults: UserDefaults = .standard,
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "model-settings.json", directoryHint: .notDirectory)
  ) {
    self.userDefaultsBox = UserDefaultsBox(userDefaults: userDefaults)
    self.settingsURL = settingsURL
  }

  public func selectedModelID(availableModelIDs: Set<String>) async -> String {
    guard
      let storedID = userDefaultsBox.userDefaults.string(forKey: selectedModelKey),
      availableModelIDs.contains(storedID)
    else {
      return ManagedModelCatalog.defaultModelID
    }

    return storedID
  }

  public func setSelectedModelID(_ modelID: String) async {
    userDefaultsBox.userDefaults.set(modelID, forKey: selectedModelKey)
  }

  public func settings(for model: ManagedModel) async -> StoredModelSettings {
    guard let stored = readSettingsFile().modelSettings[model.id] else {
      return StoredModelSettings(
        modeSettings: model.defaultModeSettings,
        contextTokenLimit: model.defaultContextTokenLimit
      )
    }

    return stored
  }

  public func save(settings: StoredModelSettings, for model: ManagedModel) async throws {
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
