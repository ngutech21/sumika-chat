import Foundation

public struct ChatSessionState: Equatable, Sendable {
  public var messages: [ChatMessage]
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurnRecord]
  public var attachments: [ChatAttachment]
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings

  public init(
    messages: [ChatMessage],
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurnRecord] = [],
    attachments: [ChatAttachment],
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    self.messages = messages
    self.toolCalls = toolCalls
    self.turns = turns
    self.attachments = attachments
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
  }

  public static let codingDefault = ChatSessionState(
    messages: [],
    toolCalls: [],
    turns: [],
    attachments: [],
    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
    generationSettings: .codingDefault
  )
}
