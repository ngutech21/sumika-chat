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
  case selectedModelID
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
  func setSelectedModelID(_ modelID: String) async throws
  func settings(for model: ManagedModel) async -> StoredModelSettings
  func apply(
    _ mutation: ModelSettingsMutation,
    for model: ManagedModel
  ) async throws -> StoredModelSettings
}

nonisolated private struct UserDefaultsBox: @unchecked Sendable {
  package let userDefaults: UserDefaults
}

private enum StoredModelSelection: Equatable, Sendable {
  case missing
  case modelID(String)
  case invalid(String)
}

private struct PersistedModeOverrides: Codable, Equatable, Sendable {
  var chat: ModeSettingsOverride?
  var agent: ModeSettingsOverride?

  var hasValues: Bool {
    chat?.hasValues == true || agent?.hasValues == true
  }

  mutating func resolveReasoningSelections(for capability: ModelReasoningCapability) {
    if let selection = chat?.generationSettings.reasoningSelection {
      chat?.generationSettings.reasoningSelection = capability.resolving(selection)
    }
    if let selection = agent?.generationSettings.reasoningSelection {
      agent?.generationSettings.reasoningSelection = capability.resolving(selection)
    }
  }
}

private struct PersistedModelSettings: Codable, Equatable, Sendable {
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

  mutating func resolveReasoningSelections(for capability: ModelReasoningCapability) {
    modeOverrides?.resolveReasoningSelections(for: capability)
  }
}

/// The original, unversioned settings shape. These DTOs deliberately spell out the
/// historical wire format so later changes to the live domain models cannot change
/// how an old file is interpreted.
private struct SettingsFileV1: Decodable, Sendable {
  var modelSettings: [String: StoredModelSettingsV1]?

  var migratedModelSettings: [String: PersistedModelSettings] {
    (modelSettings ?? [:]).mapValues { PersistedModelSettings(legacy: $0.migrated) }
  }
}

private struct StoredModelSettingsV1: Decodable, Sendable {
  var modeSettings: ModeSettingsSetV1?
  var systemPrompt: String?
  var generationSettings: GenerationSettingsV1?
  var contextTokenLimit: Int?

  var migrated: StoredModelSettings {
    let migratedModeSettings: ChatModeSettingsSet
    if let modeSettings {
      migratedModeSettings = modeSettings.migrated
    } else {
      let shared = ChatModeSettings(
        systemPrompt: systemPrompt ?? ChatPromptDefaults.agentSystemPrompt,
        generationSettings: generationSettings?.migrated ?? .agentDefault
      )
      migratedModeSettings = ChatModeSettingsSet(chat: shared, agent: shared)
    }
    return StoredModelSettings(
      modeSettings: migratedModeSettings,
      contextTokenLimit: contextTokenLimit ?? ManagedModelCatalog.defaultContextTokenLimit
    )
  }
}

private struct ModeSettingsSetV1: Decodable, Sendable {
  var chat: ModeSettingsV1?
  var agent: ModeSettingsV1?

  var migrated: ChatModeSettingsSet {
    let defaults = ChatModeSettingsSet.defaultSettings
    return ChatModeSettingsSet(
      chat: chat?.migrated(default: defaults.chat) ?? defaults.chat,
      agent: agent?.migrated(default: defaults.agent) ?? defaults.agent
    )
  }
}

private struct ModeSettingsV1: Decodable, Sendable {
  var systemPrompt: String?
  var generationSettings: GenerationSettingsV1?

  func migrated(default defaultSettings: ChatModeSettings) -> ChatModeSettings {
    ChatModeSettings(
      systemPrompt: systemPrompt ?? defaultSettings.systemPrompt,
      generationSettings: generationSettings?.migrated ?? defaultSettings.generationSettings
    )
  }
}

private struct GenerationSettingsV1: Decodable, Sendable {
  var temperature: Double?
  var topP: Double?
  var topK: Int?
  var maxTokens: Int?
  var repetitionPenalty: Double?
  var repetitionContextSize: Int?
  var presencePenalty: Double?
  var reasoningEnabled: Bool?

  var migrated: ChatGenerationSettings {
    ChatGenerationSettings(
      temperature: temperature ?? 1,
      topP: topP ?? 1,
      topK: topK ?? 0,
      maxTokens: maxTokens ?? 2048,
      repetitionPenalty: repetitionPenalty ?? 1,
      repetitionContextSize: repetitionContextSize ?? 20,
      presencePenalty: presencePenalty ?? 0,
      reasoningSelection: reasoningEnabled == false ? .off : .on
    )
  }
}

private struct SettingsFileV2: Decodable, Sendable {
  var modelSettings: [String: PersistedModelSettingsV2]?

  var migratedModelSettings: [String: PersistedModelSettings] {
    (modelSettings ?? [:]).mapValues(\.migrated)
  }
}

private struct PersistedModelSettingsV2: Decodable, Sendable {
  var modeOverrides: PersistedModeOverridesV2?
  var contextTokenLimitOverride: Int?

  var migrated: PersistedModelSettings {
    PersistedModelSettings(
      modeOverrides: modeOverrides?.migrated,
      contextTokenLimitOverride: contextTokenLimitOverride
    )
  }
}

private struct PersistedModeOverridesV2: Decodable, Sendable {
  var chat: ModeSettingsOverrideV2?
  var agent: ModeSettingsOverrideV2?

  var migrated: PersistedModeOverrides {
    PersistedModeOverrides(chat: chat?.migrated, agent: agent?.migrated)
  }
}

private struct ModeSettingsOverrideV2: Decodable, Sendable {
  var systemPrompt: String?
  var generationSettings: GenerationSettingsOverrideV2?

  var migrated: ModeSettingsOverride {
    ModeSettingsOverride(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings?.migrated ?? GenerationSettingsOverride()
    )
  }
}

private struct GenerationSettingsOverrideV2: Decodable, Sendable {
  var temperature: Double?
  var topP: Double?
  var topK: Int?
  var minP: Double?
  var maxTokens: Int?
  var repetitionPenalty: Double?
  var repetitionContextSize: Int?
  var presencePenalty: Double?
  var reasoningEnabled: Bool?

  var migrated: GenerationSettingsOverride {
    GenerationSettingsOverride(
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      maxTokens: maxTokens,
      repetitionPenalty: repetitionPenalty,
      repetitionContextSize: repetitionContextSize,
      presencePenalty: presencePenalty,
      reasoningSelection: reasoningEnabled.map { $0 ? .on : .off }
    )
  }
}

private struct SettingsFileV3: Decodable, Sendable {
  var modelSettings: [String: PersistedModelSettingsV3]?

  var migratedModelSettings: [String: PersistedModelSettings] {
    (modelSettings ?? [:]).mapValues(\.migrated)
  }
}

private struct PersistedModelSettingsV3: Decodable, Sendable {
  var modeOverrides: PersistedModeOverridesV3?
  var contextTokenLimitOverride: Int?

  var migrated: PersistedModelSettings {
    PersistedModelSettings(
      modeOverrides: modeOverrides?.migrated,
      contextTokenLimitOverride: contextTokenLimitOverride
    )
  }
}

private struct PersistedModeOverridesV3: Decodable, Sendable {
  var chat: ModeSettingsOverrideV3?
  var agent: ModeSettingsOverrideV3?

  var migrated: PersistedModeOverrides {
    PersistedModeOverrides(chat: chat?.migrated, agent: agent?.migrated)
  }
}

private struct ModeSettingsOverrideV3: Decodable, Sendable {
  var systemPrompt: String?
  var generationSettings: GenerationSettingsOverrideV3?

  var migrated: ModeSettingsOverride {
    ModeSettingsOverride(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings?.migrated ?? GenerationSettingsOverride()
    )
  }
}

private struct GenerationSettingsOverrideV3: Decodable, Sendable {
  var temperature: Double?
  var topP: Double?
  var topK: Int?
  var minP: Double?
  var maxTokens: Int?
  var repetitionPenalty: Double?
  var repetitionContextSize: Int?
  var presencePenalty: Double?
  var reasoningSelection: String?
  var reasoningEnabled: Bool?

  var migrated: GenerationSettingsOverride {
    GenerationSettingsOverride(
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      maxTokens: maxTokens,
      repetitionPenalty: repetitionPenalty,
      repetitionContextSize: repetitionContextSize,
      presencePenalty: presencePenalty,
      reasoningSelection: migratedReasoningSelection
    )
  }

  private var migratedReasoningSelection: ReasoningSelection? {
    if let reasoningSelection {
      switch reasoningSelection {
      case "off":
        return .off
      case "low":
        return .effort(.low)
      case "medium":
        return .effort(.medium)
      case "xhigh":
        return .effort(.xhigh)
      default:
        return .on
      }
    }
    return reasoningEnabled.map { $0 ? .on : .off }
  }
}

private struct SettingsFileV4: Decodable, Sendable {
  var selectedModelID: String?
  var modelSettings: [String: PersistedModelSettingsV4]

  var currentModelSettings: [String: PersistedModelSettings] {
    modelSettings.mapValues(\.current)
  }
}

private struct PersistedModelSettingsV4: Decodable, Sendable {
  var modeOverrides: PersistedModeOverridesV4?
  var contextTokenLimitOverride: Int?

  var current: PersistedModelSettings {
    PersistedModelSettings(
      modeOverrides: modeOverrides?.current,
      contextTokenLimitOverride: contextTokenLimitOverride
    )
  }
}

private struct PersistedModeOverridesV4: Decodable, Sendable {
  var chat: ModeSettingsOverrideV4?
  var agent: ModeSettingsOverrideV4?

  var current: PersistedModeOverrides {
    PersistedModeOverrides(chat: chat?.current, agent: agent?.current)
  }
}

private struct ModeSettingsOverrideV4: Decodable, Sendable {
  var systemPrompt: String?
  var generationSettings: GenerationSettingsOverrideV4?

  var current: ModeSettingsOverride {
    ModeSettingsOverride(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings?.current ?? GenerationSettingsOverride()
    )
  }
}

private enum GenerationSettingsOverrideV4CodingKeys: String, CodingKey {
  case temperature
  case topP
  case topK
  case minP
  case maxTokens
  case repetitionPenalty
  case repetitionContextSize
  case presencePenalty
  case reasoningSelection
  case reasoningEnabled
}

private struct GenerationSettingsOverrideV4: Decodable, Sendable {
  var temperature: Double?
  var topP: Double?
  var topK: Int?
  var minP: Double?
  var maxTokens: Int?
  var repetitionPenalty: Double?
  var repetitionContextSize: Int?
  var presencePenalty: Double?
  var reasoningSelection: ReasoningSelection?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: GenerationSettingsOverrideV4CodingKeys.self)
    guard !container.contains(.reasoningEnabled) else {
      throw DecodingError.dataCorruptedError(
        forKey: .reasoningEnabled,
        in: container,
        debugDescription: "reasoningEnabled is not valid in model settings schema version 4."
      )
    }
    temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
    topP = try container.decodeIfPresent(Double.self, forKey: .topP)
    topK = try container.decodeIfPresent(Int.self, forKey: .topK)
    minP = try container.decodeIfPresent(Double.self, forKey: .minP)
    maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
    repetitionPenalty = try container.decodeIfPresent(
      Double.self,
      forKey: .repetitionPenalty
    )
    repetitionContextSize = try container.decodeIfPresent(
      Int.self,
      forKey: .repetitionContextSize
    )
    presencePenalty = try container.decodeIfPresent(Double.self, forKey: .presencePenalty)
    reasoningSelection = try Self.decodeReasoningSelection(from: container)
  }

  var current: GenerationSettingsOverride {
    GenerationSettingsOverride(
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      maxTokens: maxTokens,
      repetitionPenalty: repetitionPenalty,
      repetitionContextSize: repetitionContextSize,
      presencePenalty: presencePenalty,
      reasoningSelection: reasoningSelection
    )
  }

  private static func decodeReasoningSelection(
    from container: KeyedDecodingContainer<GenerationSettingsOverrideV4CodingKeys>
  ) throws -> ReasoningSelection? {
    guard
      let value = try container.decodeIfPresent(String.self, forKey: .reasoningSelection)
    else {
      return nil
    }
    switch value {
    case "off":
      return .off
    case "on":
      return .on
    case ReasoningEffort.low.rawValue:
      return .effort(.low)
    case ReasoningEffort.medium.rawValue:
      return .effort(.medium)
    case ReasoningEffort.xhigh.rawValue:
      return .effort(.xhigh)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .reasoningSelection,
        in: container,
        debugDescription: "Invalid reasoning selection in model settings schema version 4."
      )
    }
  }
}

private struct SettingsFile: Codable, Sendable {
  static let schemaVersion = 4

  var selectedModelID: String?
  var modelSettings: [String: PersistedModelSettings]
  let requiresMigration: Bool

  init(
    selectedModelID: String? = nil,
    modelSettings: [String: PersistedModelSettings]
  ) {
    self.selectedModelID = selectedModelID
    self.modelSettings = modelSettings
    requiresMigration = false
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: ModelSettingsFileCodingKeys.self)
    let schemaVersion: Int?
    if container.contains(.schemaVersion) {
      guard try !container.decodeNil(forKey: .schemaVersion) else {
        throw DecodingError.valueNotFound(
          Int.self,
          DecodingError.Context(
            codingPath: container.codingPath + [ModelSettingsFileCodingKeys.schemaVersion],
            debugDescription: "schemaVersion must be an integer."
          )
        )
      }
      schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    } else {
      schemaVersion = nil
    }
    switch schemaVersion {
    case nil:
      selectedModelID = nil
      modelSettings = try SettingsFileV1(from: decoder).migratedModelSettings
      requiresMigration = true
    case 2:
      selectedModelID = nil
      modelSettings = try SettingsFileV2(from: decoder).migratedModelSettings
      requiresMigration = true
    case 3:
      selectedModelID = nil
      modelSettings = try SettingsFileV3(from: decoder).migratedModelSettings
      requiresMigration = true
    case Self.schemaVersion:
      let current = try SettingsFileV4(from: decoder)
      selectedModelID = current.selectedModelID
      modelSettings = current.currentModelSettings
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
    try container.encodeIfPresent(selectedModelID, forKey: .selectedModelID)
    try container.encode(modelSettings, forKey: .modelSettings)
  }

  func hasSameContents(as other: Self) -> Bool {
    selectedModelID == other.selectedModelID && modelSettings == other.modelSettings
  }

  mutating func resolveReasoningSelections(availableModels: [ManagedModel]) {
    for model in availableModels where modelSettings[model.id] != nil {
      modelSettings[model.id]?.resolveReasoningSelections(
        for: model.reasoningCapability
      )
    }
  }
}

package actor ModelSettingsStore: ModelSettingsStoring {
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

  package func setSelectedModelID(_ modelID: String) async throws {
    let predecessor = settingsMutationTask
    let operation = Task { [self] in
      await predecessor?.value
      try await applySelectedModelID(modelID)
    }
    settingsMutationTask = Task {
      _ = try? await operation.value
    }
    try await operation.value
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
    var settingsFile = try await readSettingsFileIfPresent()
    let storedSelection = await readLegacySelection()
    let storedModelID: String?
    let shouldRemoveLegacySelection: Bool
    var shouldWriteSettingsFile = settingsFile?.requiresMigration == true

    if let selectedModelID = settingsFile?.selectedModelID {
      storedModelID = selectedModelID
      shouldRemoveLegacySelection = storedSelection != .missing
    } else {
      switch storedSelection {
      case .missing:
        storedModelID = nil
        shouldRemoveLegacySelection = false
      case .modelID(let modelID):
        storedModelID = modelID
        shouldRemoveLegacySelection = true
        if settingsFile == nil {
          settingsFile = SettingsFile(modelSettings: [:])
        }
        settingsFile?.selectedModelID = modelID
        shouldWriteSettingsFile = true
      case .invalid(let description):
        throw ModelSettingsRestoreError.invalidSelectedModel(description)
      }
    }

    if shouldWriteSettingsFile {
      settingsFile?.resolveReasoningSelections(availableModels: availableModels)
      if let settingsFile {
        try await write(settingsFile)
      }
    }
    if shouldRemoveLegacySelection {
      await removeLegacySelection()
    }

    let modelID = storedModelID ?? ManagedModelCatalog.defaultModelID
    guard !modelID.isEmpty else {
      throw ModelSettingsRestoreError.invalidSelectedModel(modelID)
    }
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
    if file.requiresMigration {
      file.resolveReasoningSelections(availableModels: ManagedModelCatalog.models)
    }
    var persisted = file.modelSettings[model.id] ?? PersistedModelSettings()
    persisted.resolveReasoningSelections(for: model.reasoningCapability)
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

  private func applySelectedModelID(_ modelID: String) async throws {
    var file = try await readSettingsFileIfPresent() ?? SettingsFile(modelSettings: [:])
    if file.requiresMigration {
      file.resolveReasoningSelections(availableModels: ManagedModelCatalog.models)
    }
    file.selectedModelID = modelID
    try await write(file)
    await removeLegacySelection()
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
    let verifiedFile = try JSONDecoder().decode(SettingsFile.self, from: data)
    guard file.hasSameContents(as: verifiedFile) else {
      throw ModelSettingsRestoreError.invalidSettings(
        "Encoded model settings did not round-trip."
      )
    }
    let settingsURL = settingsURL
    try await Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(
        at: settingsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: settingsURL, options: .atomic)
    }.value
  }

  private func readLegacySelection() async -> StoredModelSelection {
    let userDefaultsBox = userDefaultsBox
    let selectedModelKey = selectedModelKey
    return await Task.detached(priority: .utility) {
      guard let value = userDefaultsBox.userDefaults.object(forKey: selectedModelKey) else {
        return StoredModelSelection.missing
      }
      guard let modelID = value as? String, !modelID.isEmpty else {
        return StoredModelSelection.invalid(String(describing: value))
      }
      return StoredModelSelection.modelID(modelID)
    }.value
  }

  private func removeLegacySelection() async {
    let userDefaultsBox = userDefaultsBox
    let selectedModelKey = selectedModelKey
    await Task.detached(priority: .utility) {
      userDefaultsBox.userDefaults.removeObject(forKey: selectedModelKey)
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
