import Foundation
import Testing

@testable import LocalCoderCore

struct ChatModelContextBuilderTests {
  @Test
  func filtersModelContextMessagesFromExcludedTurnsButKeepsLegacyMessages() {
    let includedTurnID = UUID()
    let excludedTurnID = UUID()
    let legacyMessage = ChatModelContextMessage(role: .user, content: "legacy")
    let includedMessage = ChatModelContextMessage(
      turnID: includedTurnID,
      role: .assistant,
      content: "included"
    )
    let excludedMessage = ChatModelContextMessage(
      turnID: excludedTurnID,
      role: .user,
      content: "large listing"
    )
    let state = ChatSessionState(
      messages: [],
      modelContextMessages: [legacyMessage, includedMessage, excludedMessage],
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
    let toolResult = ChatModelContextMessage(
      turnID: turnID,
      role: .user,
      content: "README.md"
    )
    let state = ChatSessionState(
      messages: [],
      modelContextMessages: [toolResult],
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

  @Test
  func focusedFileContextMessageRendersActivePath() throws {
    let path = WorkspaceRelativePath(rawValue: "index.html")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(
          path: path,
          source: .writeFile,
          confidence: .active,
          updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          path: path,
          contentHash: "hash",
          excerpt: "<h1>Hello</h1>",
          fullContentAvailable: true
        )
      ]
    )

    let message = try #require(ChatModelContextBuilder().focusedFileContextMessage(from: state))

    #expect(message.role == .system)
    #expect(message.content.contains("Current focused file: index.html"))
    #expect(message.content.contains("Source: previous write_file"))
    #expect(message.content.contains("Known content excerpt:"))
    #expect(message.content.contains("<h1>Hello</h1>"))
  }

  @Test
  func focusedFileContextMessageRendersAmbiguousRecentFilesWithoutActivePath() throws {
    let state = FocusedFileState(
      activePath: nil,
      recentPaths: [
        FocusedPath(
          path: WorkspaceRelativePath(rawValue: "index.html"),
          source: .attachment,
          confidence: .ambiguous
        ),
        FocusedPath(
          path: WorkspaceRelativePath(rawValue: "style.css"),
          source: .attachment,
          confidence: .ambiguous
        ),
      ]
    )

    let message = try #require(ChatModelContextBuilder().focusedFileContextMessage(from: state))

    #expect(message.role == .system)
    #expect(message.content.contains("Recent files are ambiguous:"))
    #expect(message.content.contains("Current focused file:") == false)
    #expect(message.content.contains("- index.html"))
    #expect(message.content.contains("- style.css"))
  }

  @Test
  func toolResultAppendIsPrefixStableWhenTranscriptMutates() {
    let turnID = UUID()
    let sourceMessageID = UUID()
    var state = ChatSessionState(
      messages: [
        ChatMessage(id: sourceMessageID, assistantContent: "<action name=\"read_file\"></action>")
      ],
      modelContextMessages: [
        ChatModelContextMessage(
          turnID: turnID,
          sourceMessageID: sourceMessageID,
          role: .assistant,
          content: "<action name=\"read_file\"></action>"
        )
      ],
      turns: [ChatTurnRecord(id: turnID, status: .running)],
      attachments: [],
      systemPrompt: "System",
      generationSettings: .codingDefault
    )
    let before = ChatModelContextBuilder().messages(from: state, includingTurnID: turnID)

    ChatTranscriptMutator().annotateToolCall(
      ToolCallModelMessage(callID: UUID(), toolName: .readFile, arguments: []),
      for: sourceMessageID,
      in: &state
    )
    ChatTranscriptMutator().appendModelContextMessage(
      ChatModelContextMessage(turnID: turnID, role: .user, content: "observation"),
      to: &state
    )
    let after = ChatModelContextBuilder().messages(from: state, includingTurnID: turnID)

    #expect(Array(after.prefix(before.count)) == before)
    #expect(state.messages[0].kind == .toolCall)
    #expect(after.last?.content == "observation")
  }
}
