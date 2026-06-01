import Foundation

nonisolated struct ChatSessionState: Equatable, Sendable {
  var messages: [ChatMessage]
  var toolCalls: [ToolCallRecord]
  var attachments: [ChatAttachment]
  var systemPrompt: String
  var generationSettings: ChatGenerationSettings

  init(
    messages: [ChatMessage],
    toolCalls: [ToolCallRecord] = [],
    attachments: [ChatAttachment],
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    self.messages = messages
    self.toolCalls = toolCalls
    self.attachments = attachments
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
  }

  static let codingDefault = ChatSessionState(
    messages: [],
    toolCalls: [],
    attachments: [],
    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
    generationSettings: .codingDefault
  )
}
