import Foundation
import SumikaCore

nonisolated struct AppBehaviorSettings: Codable, Equatable, Sendable {
  var autoloadLastModel: Bool
  var todoWriteToolEnabled: Bool
  var defaultInteractionMode: WorkspaceInteractionMode
  var defaultToolApprovalPolicy: ToolApprovalPolicy
  var assistantSpeechEnabled: Bool
  var assistantSpeechLanguageCode: String?
  var assistantSpeechVoiceIdentifier: String?
  var assistantSpeechRate: Float
  var speechInputAudioModelID: String?

  init(
    autoloadLastModel: Bool = false,
    todoWriteToolEnabled: Bool = false,
    defaultInteractionMode: WorkspaceInteractionMode = .chat,
    defaultToolApprovalPolicy: ToolApprovalPolicy = .manual,
    assistantSpeechEnabled: Bool = false,
    assistantSpeechLanguageCode: String? = nil,
    assistantSpeechVoiceIdentifier: String? = nil,
    assistantSpeechRate: Float = AssistantSpeechRate.defaultValue,
    speechInputAudioModelID: String? = nil
  ) {
    self.autoloadLastModel = autoloadLastModel
    self.todoWriteToolEnabled = todoWriteToolEnabled
    self.defaultInteractionMode = defaultInteractionMode
    self.defaultToolApprovalPolicy = defaultToolApprovalPolicy
    self.assistantSpeechEnabled = assistantSpeechEnabled
    self.assistantSpeechLanguageCode = assistantSpeechLanguageCode
    self.assistantSpeechVoiceIdentifier = assistantSpeechVoiceIdentifier
    self.assistantSpeechRate = AssistantSpeechRate.clamped(assistantSpeechRate)
    self.speechInputAudioModelID = speechInputAudioModelID
  }

  private enum CodingKeys: String, CodingKey {
    case autoloadLastModel
    case todoWriteToolEnabled
    case defaultInteractionMode
    case defaultToolApprovalPolicy
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
    defaultInteractionMode =
      try container.decodeIfPresent(
        WorkspaceInteractionMode.self,
        forKey: .defaultInteractionMode
      ) ?? .chat
    defaultToolApprovalPolicy =
      try container.decodeIfPresent(
        ToolApprovalPolicy.self,
        forKey: .defaultToolApprovalPolicy
      ) ?? .manual
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
    try container.encode(defaultInteractionMode, forKey: .defaultInteractionMode)
    try container.encode(defaultToolApprovalPolicy, forKey: .defaultToolApprovalPolicy)
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
  func load() async throws -> AppBehaviorSettings
  func save(settings: AppBehaviorSettings) async throws
}

actor AppBehaviorSettingsStore: AppBehaviorSettingsStoring {
  private let file: VersionedJSONFile<AppBehaviorSettingsFileFormat>

  init(
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "app-behavior-settings.json", directoryHint: .notDirectory)
  ) {
    self.file = VersionedJSONFile(fileURL: settingsURL)
  }

  func load() async throws -> AppBehaviorSettings {
    switch try await file.load() {
    case .missing:
      return AppBehaviorSettings()
    case .current(let document):
      return document.domainSettings
    case .migrated(let document, fromVersion: _):
      return document.domainSettings
    }
  }

  func save(settings: AppBehaviorSettings) async throws {
    try await file.save(AppBehaviorSettingsFileV1(settings: settings))
  }
}

nonisolated private enum AppBehaviorSettingsFileFormat: VersionedJSONFormat {
  typealias CurrentDocument = AppBehaviorSettingsFileV1

  static let currentVersion = 1

  static func decode(_ data: Data, sourceVersion: Int) throws -> CurrentDocument {
    switch sourceVersion {
    case 0:
      let legacy = try JSONDecoder().decode(AppBehaviorSettingsFileV0.self, from: data)
      return AppBehaviorSettingsFileV1(migrating: legacy)
    case currentVersion:
      return try JSONDecoder().decode(CurrentDocument.self, from: data)
    default:
      throw AppBehaviorSettingsFileError.unsupportedSourceVersion(sourceVersion)
    }
  }
}

nonisolated private enum AppBehaviorSettingsFileError: Error {
  case unsupportedSourceVersion(Int)
}

nonisolated private struct AppBehaviorSettingsFileV0: Decodable, Sendable {
  var autoloadLastModel: Bool
  var todoWriteToolEnabled: Bool
  var defaultInteractionMode: WorkspaceInteractionMode
  var defaultToolApprovalPolicy: ToolApprovalPolicy
  var assistantSpeechEnabled: Bool
  var assistantSpeechLanguageCode: String?
  var assistantSpeechVoiceIdentifier: String?
  var assistantSpeechRate: Float
  var speechInputAudioModelID: String?

  private enum CodingKeys: String, CodingKey {
    case autoloadLastModel
    case todoWriteToolEnabled
    case defaultInteractionMode
    case defaultToolApprovalPolicy
    case assistantSpeechEnabled
    case assistantSpeechLanguageCode
    case assistantSpeechVoiceIdentifier
    case assistantSpeechRate
    case speechInputAudioModelID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    autoloadLastModel =
      try container.decodeIfPresent(Bool.self, forKey: .autoloadLastModel) ?? false
    todoWriteToolEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .todoWriteToolEnabled) ?? false
    defaultInteractionMode =
      try container.decodeIfPresent(WorkspaceInteractionMode.self, forKey: .defaultInteractionMode)
      ?? .chat
    defaultToolApprovalPolicy =
      try container.decodeIfPresent(ToolApprovalPolicy.self, forKey: .defaultToolApprovalPolicy)
      ?? .manual
    assistantSpeechEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .assistantSpeechEnabled) ?? false
    assistantSpeechLanguageCode =
      try container.decodeIfPresent(String.self, forKey: .assistantSpeechLanguageCode)
    assistantSpeechVoiceIdentifier =
      try container.decodeIfPresent(String.self, forKey: .assistantSpeechVoiceIdentifier)
    assistantSpeechRate = AssistantSpeechRate.clamped(
      try container.decodeIfPresent(Float.self, forKey: .assistantSpeechRate)
        ?? AssistantSpeechRate.defaultValue
    )
    speechInputAudioModelID =
      try container.decodeIfPresent(String.self, forKey: .speechInputAudioModelID)
  }
}

nonisolated private struct AppBehaviorSettingsFileV1: Codable, Equatable, Sendable {
  let schemaVersion: Int
  var autoloadLastModel: Bool
  var todoWriteToolEnabled: Bool
  var defaultInteractionMode: WorkspaceInteractionMode
  var defaultToolApprovalPolicy: ToolApprovalPolicy
  var assistantSpeechEnabled: Bool
  var assistantSpeechLanguageCode: String?
  var assistantSpeechVoiceIdentifier: String?
  var assistantSpeechRate: Float
  var speechInputAudioModelID: String?

  init(settings: AppBehaviorSettings) {
    schemaVersion = AppBehaviorSettingsFileFormat.currentVersion
    autoloadLastModel = settings.autoloadLastModel
    todoWriteToolEnabled = settings.todoWriteToolEnabled
    defaultInteractionMode = settings.defaultInteractionMode
    defaultToolApprovalPolicy = settings.defaultToolApprovalPolicy
    assistantSpeechEnabled = settings.assistantSpeechEnabled
    assistantSpeechLanguageCode = settings.assistantSpeechLanguageCode
    assistantSpeechVoiceIdentifier = settings.assistantSpeechVoiceIdentifier
    assistantSpeechRate = AssistantSpeechRate.clamped(settings.assistantSpeechRate)
    speechInputAudioModelID = settings.speechInputAudioModelID
  }

  init(migrating legacy: AppBehaviorSettingsFileV0) {
    schemaVersion = AppBehaviorSettingsFileFormat.currentVersion
    autoloadLastModel = legacy.autoloadLastModel
    todoWriteToolEnabled = legacy.todoWriteToolEnabled
    defaultInteractionMode = legacy.defaultInteractionMode
    defaultToolApprovalPolicy = legacy.defaultToolApprovalPolicy
    assistantSpeechEnabled = legacy.assistantSpeechEnabled
    assistantSpeechLanguageCode = legacy.assistantSpeechLanguageCode
    assistantSpeechVoiceIdentifier = legacy.assistantSpeechVoiceIdentifier
    assistantSpeechRate = AssistantSpeechRate.clamped(legacy.assistantSpeechRate)
    speechInputAudioModelID = legacy.speechInputAudioModelID
  }

  var domainSettings: AppBehaviorSettings {
    AppBehaviorSettings(
      autoloadLastModel: autoloadLastModel,
      todoWriteToolEnabled: todoWriteToolEnabled,
      defaultInteractionMode: defaultInteractionMode,
      defaultToolApprovalPolicy: defaultToolApprovalPolicy,
      assistantSpeechEnabled: assistantSpeechEnabled,
      assistantSpeechLanguageCode: assistantSpeechLanguageCode,
      assistantSpeechVoiceIdentifier: assistantSpeechVoiceIdentifier,
      assistantSpeechRate: assistantSpeechRate,
      speechInputAudioModelID: speechInputAudioModelID
    )
  }
}
