import Foundation
import SumikaCore

nonisolated struct AppBehaviorSettings: Codable, Equatable, Sendable {
  var autoloadLastModel: Bool
  var todoWriteToolEnabled: Bool
  var assistantSpeechEnabled: Bool
  var assistantSpeechLanguageCode: String?
  var assistantSpeechVoiceIdentifier: String?
  var assistantSpeechRate: Float
  var speechInputAudioModelID: String?

  init(
    autoloadLastModel: Bool = false,
    todoWriteToolEnabled: Bool = false,
    assistantSpeechEnabled: Bool = false,
    assistantSpeechLanguageCode: String? = nil,
    assistantSpeechVoiceIdentifier: String? = nil,
    assistantSpeechRate: Float = AssistantSpeechRate.defaultValue,
    speechInputAudioModelID: String? = nil
  ) {
    self.autoloadLastModel = autoloadLastModel
    self.todoWriteToolEnabled = todoWriteToolEnabled
    self.assistantSpeechEnabled = assistantSpeechEnabled
    self.assistantSpeechLanguageCode = assistantSpeechLanguageCode
    self.assistantSpeechVoiceIdentifier = assistantSpeechVoiceIdentifier
    self.assistantSpeechRate = AssistantSpeechRate.clamped(assistantSpeechRate)
    self.speechInputAudioModelID = speechInputAudioModelID
  }

  private enum CodingKeys: String, CodingKey {
    case autoloadLastModel
    case todoWriteToolEnabled
    case assistantSpeechEnabled
    case assistantSpeechLanguageCode
    case assistantSpeechVoiceIdentifier
    case assistantSpeechRate
    case speechInputAudioModelID
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
    assistantSpeechEnabled =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .assistantSpeechEnabled
      ) ?? false
    assistantSpeechLanguageCode =
      try container.decodeIfPresent(String.self, forKey: .assistantSpeechLanguageCode)
    assistantSpeechVoiceIdentifier =
      try container.decodeIfPresent(String.self, forKey: .assistantSpeechVoiceIdentifier)
    assistantSpeechRate =
      AssistantSpeechRate.clamped(
        try container.decodeIfPresent(Float.self, forKey: .assistantSpeechRate)
          ?? AssistantSpeechRate.defaultValue
      )
    speechInputAudioModelID =
      try container.decodeIfPresent(String.self, forKey: .speechInputAudioModelID)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(autoloadLastModel, forKey: .autoloadLastModel)
    try container.encode(todoWriteToolEnabled, forKey: .todoWriteToolEnabled)
    try container.encode(assistantSpeechEnabled, forKey: .assistantSpeechEnabled)
    try container.encodeIfPresent(assistantSpeechLanguageCode, forKey: .assistantSpeechLanguageCode)
    try container.encodeIfPresent(
      assistantSpeechVoiceIdentifier,
      forKey: .assistantSpeechVoiceIdentifier
    )
    try container.encode(
      AssistantSpeechRate.clamped(assistantSpeechRate),
      forKey: .assistantSpeechRate
    )
    try container.encodeIfPresent(speechInputAudioModelID, forKey: .speechInputAudioModelID)
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
