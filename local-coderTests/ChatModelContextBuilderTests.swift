import Foundation
import Testing

@testable import local_coder

struct ChatModelContextBuilderTests {
  @Test
  func filtersMessagesFromExcludedTurnsButKeepsLegacyMessages() {
    let includedTurnID = UUID()
    let excludedTurnID = UUID()
    let legacyMessage = ChatMessage(userContent: "legacy")
    let includedMessage = ChatMessage(assistantContent: "included", turnID: includedTurnID)
    let excludedMessage = ChatMessage(
      toolResult: ToolResultModelMessage(
        callID: UUID(),
        toolName: .listFiles,
        preview: ToolResultPreview(text: "large listing")
      ), turnID: excludedTurnID)
    let state = ChatSessionState(
      messages: [legacyMessage, includedMessage, excludedMessage],
      turns: [
        ChatTurnRecord(id: includedTurnID, status: .completed),
        ChatTurnRecord(
          id: excludedTurnID,
          status: .cancelled,
          modelContextPolicy: .excluded
        ),
      ],
      attachments: [],
      systemPrompt: "System",
      generationSettings: .codingDefault
    )

    let messages = ChatModelContextBuilder().messages(from: state)

    #expect(messages == [legacyMessage, includedMessage])
  }

  @Test
  func includesExcludedTurnWhenItIsTheActiveTurn() {
    let turnID = UUID()
    let toolResult = ChatMessage(
      toolResult: ToolResultModelMessage(
        callID: UUID(),
        toolName: .listFiles,
        preview: ToolResultPreview(text: "README.md")
      ), turnID: turnID)
    let state = ChatSessionState(
      messages: [toolResult],
      turns: [
        ChatTurnRecord(
          id: turnID,
          status: .cancelled,
          modelContextPolicy: .excluded
        )
      ],
      attachments: [],
      systemPrompt: "System",
      generationSettings: .codingDefault
    )

    let messages = ChatModelContextBuilder().messages(from: state, includingTurnID: turnID)

    #expect(messages == [toolResult])
  }
}
