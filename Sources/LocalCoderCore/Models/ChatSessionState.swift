import Foundation

public struct ChatSessionState: Equatable, Sendable {
  public var messages: [ChatMessage]
  public var modelContextMessages: [ChatModelContextMessage]
  public var modelFacingTranscript: ModelFacingTranscript
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurnRecord]
  public var attachments: [ChatAttachment]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode

  public init(
    messages: [ChatMessage],
    modelContextMessages: [ChatModelContextMessage] = [],
    modelFacingTranscript: ModelFacingTranscript? = nil,
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurnRecord] = [],
    attachments: [ChatAttachment],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode = .chat
  ) {
    self.messages = messages
    self.modelContextMessages = modelContextMessages
    self.modelFacingTranscript =
      modelFacingTranscript
      ?? ModelFacingTranscriptBackfill.transcript(
        from: modelContextMessages,
        fallbackSystemPrompt: systemPrompt
      )
    self.toolCalls = toolCalls
    self.turns = turns
    self.attachments = attachments
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
  }

  public static let codingDefault = ChatSessionState(
    messages: [],
    modelContextMessages: [],
    modelFacingTranscript: ModelFacingTranscript(),
    toolCalls: [],
    turns: [],
    attachments: [],
    focusedFileState: .empty,
    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
    generationSettings: .codingDefault,
    interactionMode: .chat
  )
}
