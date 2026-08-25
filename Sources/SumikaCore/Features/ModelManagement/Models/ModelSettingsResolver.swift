struct GenerationSettingsOverride: Codable, Equatable, Sendable {
  var temperature: Double?
  var topP: Double?
  var topK: Int?
  var minP: Double?
  var maxTokens: Int?
  var repetitionPenalty: Double?
  var repetitionContextSize: Int?
  var presencePenalty: Double?
  var reasoningEnabled: Bool?

  init(
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    minP: Double? = nil,
    maxTokens: Int? = nil,
    repetitionPenalty: Double? = nil,
    repetitionContextSize: Int? = nil,
    presencePenalty: Double? = nil,
    reasoningEnabled: Bool? = nil
  ) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.minP = minP
    self.maxTokens = maxTokens
    self.repetitionPenalty = repetitionPenalty
    self.repetitionContextSize = repetitionContextSize
    self.presencePenalty = presencePenalty
    self.reasoningEnabled = reasoningEnabled
  }

  init(overriding settings: ChatGenerationSettings, includeMinP: Bool = true) {
    temperature = settings.temperature
    topP = settings.topP
    topK = settings.topK
    minP = includeMinP ? settings.minP : nil
    maxTokens = settings.maxTokens
    repetitionPenalty = settings.repetitionPenalty
    repetitionContextSize = settings.repetitionContextSize
    presencePenalty = settings.presencePenalty
    reasoningEnabled = settings.reasoningEnabled
  }

  var hasValues: Bool {
    temperature != nil || topP != nil || topK != nil || minP != nil || maxTokens != nil
      || repetitionPenalty != nil || repetitionContextSize != nil || presencePenalty != nil
      || reasoningEnabled != nil
  }

  func applying(to settings: ChatGenerationSettings) -> ChatGenerationSettings {
    var updated = settings
    if let temperature { updated.temperature = temperature }
    if let topP { updated.topP = topP }
    if let topK { updated.topK = topK }
    if let minP { updated.minP = minP }
    if let maxTokens { updated.maxTokens = maxTokens }
    if let repetitionPenalty { updated.repetitionPenalty = repetitionPenalty }
    if let repetitionContextSize { updated.repetitionContextSize = repetitionContextSize }
    if let presencePenalty { updated.presencePenalty = presencePenalty }
    if let reasoningEnabled { updated.reasoningEnabled = reasoningEnabled }
    return updated
  }

  mutating func recordChanges(
    from previous: ChatGenerationSettings,
    to updated: ChatGenerationSettings
  ) {
    if previous.temperature != updated.temperature {
      temperature = updated.temperature
    }
    if previous.topP != updated.topP {
      topP = updated.topP
    }
    if previous.topK != updated.topK {
      topK = updated.topK
    }
    if previous.minP != updated.minP {
      minP = updated.minP
    }
    if previous.maxTokens != updated.maxTokens {
      maxTokens = updated.maxTokens
    }
    if previous.repetitionPenalty != updated.repetitionPenalty {
      repetitionPenalty = updated.repetitionPenalty
    }
    if previous.repetitionContextSize != updated.repetitionContextSize {
      repetitionContextSize = updated.repetitionContextSize
    }
    if previous.presencePenalty != updated.presencePenalty {
      presencePenalty = updated.presencePenalty
    }
    if previous.reasoningEnabled != updated.reasoningEnabled {
      reasoningEnabled = updated.reasoningEnabled
    }
  }
}

struct ModeSettingsOverride: Codable, Equatable, Sendable {
  var systemPrompt: String?
  var generationSettings: GenerationSettingsOverride

  init(
    systemPrompt: String? = nil,
    generationSettings: GenerationSettingsOverride = GenerationSettingsOverride()
  ) {
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
  }

  private enum CodingKeys: String, CodingKey {
    case systemPrompt
    case generationSettings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
    generationSettings =
      try container.decodeIfPresent(
        GenerationSettingsOverride.self,
        forKey: .generationSettings
      ) ?? GenerationSettingsOverride()
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
    if generationSettings.hasValues {
      try container.encode(generationSettings, forKey: .generationSettings)
    }
  }

  var hasValues: Bool {
    systemPrompt != nil || generationSettings.hasValues
  }

  func applying(to settings: ChatModeSettings) -> ChatModeSettings {
    var updated = settings
    if let systemPrompt { updated.systemPrompt = systemPrompt }
    updated.generationSettings = generationSettings.applying(to: updated.generationSettings)
    return updated
  }

  mutating func recordChanges(
    from previous: ChatModeSettings,
    to updated: ChatModeSettings
  ) {
    if previous.systemPrompt != updated.systemPrompt {
      systemPrompt = updated.systemPrompt
    }
    generationSettings.recordChanges(
      from: previous.generationSettings,
      to: updated.generationSettings
    )
  }
}

struct ModelSettingsOverrides: Equatable, Sendable {
  var chat: ModeSettingsOverride?
  var agent: ModeSettingsOverride?
  var contextTokenLimit: Int?

  init(
    chat: ModeSettingsOverride? = nil,
    agent: ModeSettingsOverride? = nil,
    contextTokenLimit: Int? = nil
  ) {
    self.chat = chat
    self.agent = agent
    self.contextTokenLimit = contextTokenLimit
  }
}

enum ModelGenerationProfile: Equatable, Sendable {
  case gemma4
  case qwen36
  case qwen38

  fileprivate var chatOverride: GenerationSettingsOverride {
    switch self {
    case .gemma4:
      GenerationSettingsOverride(temperature: 1, topP: 0.95, topK: 64)
    case .qwen36, .qwen38:
      GenerationSettingsOverride(temperature: 0.7, topP: 0.9, topK: 0, presencePenalty: 0)
    }
  }

  fileprivate var agentOverride: GenerationSettingsOverride {
    switch self {
    case .gemma4:
      GenerationSettingsOverride(temperature: 0.7, topP: 0.9, topK: 0)
    case .qwen36, .qwen38:
      GenerationSettingsOverride(temperature: 0.6, topP: 0.95, topK: 20, presencePenalty: 0)
    }
  }
}

enum ModelSettingsResolver {
  static func settings(
    for model: ManagedModel,
    generationConfig: GenerationSettingsOverride?,
    userOverrides: ModelSettingsOverrides
  ) -> StoredModelSettings {
    var settings = recommendedSettings(for: model, generationConfig: generationConfig)
    if let chat = userOverrides.chat {
      settings.modeSettings.chat = chat.applying(to: settings.modeSettings.chat)
    }
    if let agent = userOverrides.agent {
      settings.modeSettings.agent = agent.applying(to: settings.modeSettings.agent)
    }
    if let contextTokenLimit = userOverrides.contextTokenLimit {
      settings.contextTokenLimit = contextTokenLimit
    }
    return settings
  }

  static func recommendedSettings(
    for model: ManagedModel,
    generationConfig: GenerationSettingsOverride?
  ) -> StoredModelSettings {
    var modeSettings = model.defaultModeSettings
    if let generationConfig {
      modeSettings.chat.generationSettings = generationConfig.applying(
        to: modeSettings.chat.generationSettings)
      modeSettings.agent.generationSettings = generationConfig.applying(
        to: modeSettings.agent.generationSettings)
    }
    if let profile = model.generationProfile {
      modeSettings.chat.generationSettings = profile.chatOverride.applying(
        to: modeSettings.chat.generationSettings)
      modeSettings.agent.generationSettings = profile.agentOverride.applying(
        to: modeSettings.agent.generationSettings)
    }
    return StoredModelSettings(
      modeSettings: modeSettings,
      contextTokenLimit: model.defaultContextTokenLimit
    )
  }
}
