import Foundation
import SumikaCore

nonisolated struct AppBehaviorSettings: Codable, Equatable, Sendable {
  var autoloadLastModel: Bool
  var todoWriteToolEnabled: Bool

  init(
    autoloadLastModel: Bool = false,
    todoWriteToolEnabled: Bool = false
  ) {
    self.autoloadLastModel = autoloadLastModel
    self.todoWriteToolEnabled = todoWriteToolEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case autoloadLastModel
    case todoWriteToolEnabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    autoloadLastModel =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .autoloadLastModel
      ) ?? false
    todoWriteToolEnabled =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .todoWriteToolEnabled
      ) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(autoloadLastModel, forKey: .autoloadLastModel)
    try container.encode(todoWriteToolEnabled, forKey: .todoWriteToolEnabled)
  }
}

protocol AppBehaviorSettingsStoring: Sendable {
  func settings() async -> AppBehaviorSettings
  func save(settings: AppBehaviorSettings) async throws
}

actor AppBehaviorSettingsStore: AppBehaviorSettingsStoring {
  private let settingsURL: URL

  init(
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "app-behavior-settings.json", directoryHint: .notDirectory)
  ) {
    self.settingsURL = settingsURL
  }

  func settings() async -> AppBehaviorSettings {
    guard
      let data = try? Data(contentsOf: settingsURL),
      let decoded = try? JSONDecoder().decode(AppBehaviorSettings.self, from: data)
    else {
      return AppBehaviorSettings()
    }

    return decoded
  }

  func save(settings: AppBehaviorSettings) async throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(settings)
    try data.write(to: settingsURL, options: .atomic)
  }
}
