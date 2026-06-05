import Foundation

@dynamicMemberLookup
public struct ChatSessionState: Equatable, Sendable {
  public var transcript: ChatTranscriptState
  public var pendingAttachments: [ChatAttachment]

  public var modelFacingTranscript: ModelFacingTranscript {
    get { transcript.modelFacingTranscript }
    set { transcript.modelFacingTranscript = newValue }
  }

  public var toolCalls: [ToolCallRecord] {
    get { transcript.toolCalls }
    set { transcript.toolCalls = newValue }
  }

  public var turns: [ChatTurn] {
    get { transcript.turns }
    set { transcript.turns = newValue }
  }

  public var focusedFileState: FocusedFileState {
    get { transcript.focusedFileState }
    set { transcript.focusedFileState = newValue }
  }

  public var systemPrompt: String {
    get { transcript.systemPrompt }
    set { transcript.systemPrompt = newValue }
  }

  public var generationSettings: ChatGenerationSettings {
    get { transcript.generationSettings }
    set { transcript.generationSettings = newValue }
  }

  public var interactionMode: WorkspaceInteractionMode {
    get { transcript.interactionMode }
    set { transcript.interactionMode = newValue }
  }

  public subscript<Value>(dynamicMember keyPath: WritableKeyPath<ChatTranscriptState, Value>)
    -> Value
  {
    get { transcript[keyPath: keyPath] }
    set { transcript[keyPath: keyPath] = newValue }
  }

  public init(
    transcript: ChatTranscriptState,
    pendingAttachments: [ChatAttachment] = []
  ) {
    self.transcript = transcript
    self.pendingAttachments = pendingAttachments
  }

  public init(
    modelFacingTranscript: ModelFacingTranscript = ModelFacingTranscript(),
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurn] = [],
    pendingAttachments: [ChatAttachment],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode = .chat
  ) {
    self.transcript = ChatTranscriptState(
      modelFacingTranscript: modelFacingTranscript,
      toolCalls: toolCalls,
      turns: turns,
      focusedFileState: focusedFileState,
      systemPrompt: systemPrompt,
      generationSettings: generationSettings,
      interactionMode: interactionMode
    )
    self.pendingAttachments = pendingAttachments
  }

  public static let codingDefault = ChatSessionState(transcript: .codingDefault)

  public func turnID(containingToolCall toolCallID: ToolCallRecord.ID) -> ChatTurn.ID? {
    turns.first { turn in
      turn.items.contains { item in
        switch item {
        case .toolCall(let id), .toolResult(let id):
          id == toolCallID
        case .userMessage, .assistantMessage:
          false
        }
      }
    }?.id
  }
}
