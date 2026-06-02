import Foundation

nonisolated struct ChatSessionState: Equatable, Sendable {
  var messages: [ChatMessage]
  var toolCalls: [ToolCallRecord]
  var turns: [ChatTurnRecord]
  var attachments: [ChatAttachment]
  var systemPrompt: String
  var generationSettings: ChatGenerationSettings

  init(
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

  static let codingDefault = ChatSessionState(
    messages: [],
    toolCalls: [],
    turns: [],
    attachments: [],
    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
    generationSettings: .codingDefault
  )
}
