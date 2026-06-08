import Foundation
import LocalCoderCore

nonisolated struct AppBehaviorSettings: Codable, Equatable, Sendable {
  var autoloadLastModel: Bool

  init(autoloadLastModel: Bool = false) {
    self.autoloadLastModel = autoloadLastModel
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
