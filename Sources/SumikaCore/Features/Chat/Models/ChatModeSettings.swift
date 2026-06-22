import Foundation

public struct ChatModeSettings: Codable, Equatable, Sendable {
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings

  public init(
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
  }
}

public struct ChatModeSettingsSet: Codable, Equatable, Sendable {
  public var chat: ChatModeSettings
  public var agent: ChatModeSettings

  public init(
    chat: ChatModeSettings,
    agent: ChatModeSettings
  ) {
    self.chat = chat
    self.agent = agent
  }

  public subscript(mode: WorkspaceInteractionMode) -> ChatModeSettings {
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

  public static let defaultSettings = ChatModeSettingsSet(
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
