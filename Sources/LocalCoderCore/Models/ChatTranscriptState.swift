import Foundation

public struct ChatTranscriptState: Codable, Equatable, Sendable {
  public var modelFacingTranscript: ModelFacingTranscript
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurn]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode

  public init(
    messages: [ChatMessage] = [],
    modelFacingTranscript: ModelFacingTranscript = ModelFacingTranscript(),
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurn] = [],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode = .chat
  ) {
    let projectedTurns: [ChatTurn]
    if turns.isEmpty, !messages.isEmpty {
      projectedTurns = [
        ChatTurn(status: .completed, items: messages.map(ChatTurnItem.init(projectedMessage:)))
      ]
    } else if !messages.isEmpty {
      projectedTurns = turns.enumerated().map { index, turn in
        guard index == 0 else {
          return turn
        }
        var updatedTurn = turn
        updatedTurn.items.append(contentsOf: messages.map(ChatTurnItem.init(projectedMessage:)))
        return updatedTurn
      }
    } else {
      projectedTurns = turns
    }
    self.modelFacingTranscript = modelFacingTranscript
    self.toolCalls = toolCalls
    self.turns = projectedTurns
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
  }

  public static let codingDefault = ChatTranscriptState(
    modelFacingTranscript: ModelFacingTranscript(),
    toolCalls: [],
    turns: [],
    focusedFileState: .empty,
    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
    generationSettings: .codingDefault,
    interactionMode: .chat
  )
}
