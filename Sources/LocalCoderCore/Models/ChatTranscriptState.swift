import Foundation

public struct ChatTranscriptState: Codable, Equatable, Sendable {
  public var messages: [ChatMessage]
  public var modelFacingTranscript: ModelFacingTranscript
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurnRecord]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode

  public init(
    messages: [ChatMessage],
    modelFacingTranscript: ModelFacingTranscript = ModelFacingTranscript(),
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurnRecord] = [],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode = .chat
  ) {
    self.messages = messages
    self.modelFacingTranscript = modelFacingTranscript
    self.toolCalls = toolCalls
    self.turns = turns
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
  }

  public static let codingDefault = ChatTranscriptState(
    messages: [],
    modelFacingTranscript: ModelFacingTranscript(),
    toolCalls: [],
    turns: [],
    focusedFileState: .empty,
    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
    generationSettings: .codingDefault,
    interactionMode: .chat
  )
}
