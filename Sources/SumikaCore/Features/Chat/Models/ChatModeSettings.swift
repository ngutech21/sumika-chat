package struct ChatModeSettings: Codable, Equatable, Sendable {
  package var systemPrompt: String
  package var generationSettings: ChatGenerationSettings

  package init(
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
  }

  fileprivate enum CodingKeys: String, CodingKey {
    case systemPrompt
    case generationSettings
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      from: container,
      default: ChatModeSettings(
        systemPrompt: ChatPromptDefaults.agentSystemPrompt,
        generationSettings: .agentDefault
      )
    )
  }

  fileprivate init(
    from container: KeyedDecodingContainer<CodingKeys>,
    default defaultSettings: ChatModeSettings
  ) throws {
    systemPrompt = try container.decodeIfPresent(
      String.self,
      forKey: .systemPrompt,
      default: defaultSettings.systemPrompt
    )
    generationSettings = try container.decodeIfPresent(
      ChatGenerationSettings.self,
      forKey: .generationSettings,
      default: defaultSettings.generationSettings
    )
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(systemPrompt, forKey: .systemPrompt)
    try container.encode(generationSettings, forKey: .generationSettings)
  }
}

package struct ChatModeSettingsSet: Codable, Equatable, Sendable {
  package var chat: ChatModeSettings
  package var agent: ChatModeSettings

  package init(
    chat: ChatModeSettings,
    agent: ChatModeSettings
  ) {
    self.chat = chat
    self.agent = agent
  }

  private enum CodingKeys: String, CodingKey {
    case chat
    case agent
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.defaultSettings
    chat = try Self.decodeSettings(from: container, forKey: .chat, default: defaults.chat)
    agent = try Self.decodeSettings(from: container, forKey: .agent, default: defaults.agent)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(chat, forKey: .chat)
    try container.encode(agent, forKey: .agent)
  }

  private static func decodeSettings(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys,
    default defaultSettings: ChatModeSettings
  ) throws -> ChatModeSettings {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
      return defaultSettings
    }
    let nestedContainer = try container.nestedContainer(
      keyedBy: ChatModeSettings.CodingKeys.self,
      forKey: key
    )
    return try ChatModeSettings(from: nestedContainer, default: defaultSettings)
  }

  package subscript(mode: WorkspaceInteractionMode) -> ChatModeSettings {
    get {
      switch mode {
      case .chat:
        return chat
      case .agent:
        return agent
      }
    }
    set {
      switch mode {
      case .chat:
        chat = newValue
      case .agent:
        agent = newValue
      }
    }
  }

  package static let defaultSettings = ChatModeSettingsSet(
    chat: ChatModeSettings(
      systemPrompt: ChatPromptDefaults.chatSystemPrompt,
      generationSettings: .chatDefault
    ),
    agent: ChatModeSettings(
      systemPrompt: ChatPromptDefaults.agentSystemPrompt,
      generationSettings: .agentDefault
    )
  )
}
