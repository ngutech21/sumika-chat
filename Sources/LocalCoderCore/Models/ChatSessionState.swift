import Foundation

public struct ChatSessionState: Equatable, Sendable {
  public var messages: [ChatMessage]
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurnRecord]
  public var attachments: [ChatAttachment]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings

  public init(
    messages: [ChatMessage],
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurnRecord] = [],
    attachments: [ChatAttachment],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    self.messages = messages
    self.toolCalls = toolCalls
    self.turns = turns
    self.attachments = attachments
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
  }

  public static let codingDefault = ChatSessionState(
    messages: [],
    toolCalls: [],
    turns: [],
    attachments: [],
    focusedFileState: .empty,
    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
    generationSettings: .codingDefault
  )
}
