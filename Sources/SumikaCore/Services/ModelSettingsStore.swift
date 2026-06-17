import Foundation

public struct StoredModelSettings: Codable, Equatable, Sendable {
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var contextTokenLimit: Int

  public init(
    systemPrompt: String = ChatPromptDefaults.codingSystemPrompt,
    generationSettings: ChatGenerationSettings = .codingDefault,
    contextTokenLimit: Int = ManagedModelCatalog.defaultContextTokenLimit
  ) {
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
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
        systemPrompt: model.defaultSystemPrompt,
        generationSettings: model.defaultGenerationSettings,
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
