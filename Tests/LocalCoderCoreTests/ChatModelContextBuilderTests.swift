import Foundation
import Testing

@testable import LocalCoderCore

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

  @Test
  func prependsFocusedFileContextWhenActivePathIsKnown() {
    let path = WorkspaceRelativePath(rawValue: "index.html")
    let userMessage = ChatMessage(userContent: "make it nicer")
    let state = ChatSessionState(
      messages: [userMessage],
      attachments: [],
      focusedFileState: FocusedFileState(
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
      ),
      systemPrompt: "System",
      generationSettings: .codingDefault
    )

    let messages = ChatModelContextBuilder().messages(from: state)

    #expect(messages.count == 2)
    #expect(messages[0].kind == .system)
    #expect(messages[0].content.contains("Current focused file: index.html"))
    #expect(messages[0].content.contains("Source: previous write_file"))
    #expect(messages[0].content.contains("Known content excerpt:"))
    #expect(messages[0].content.contains("<h1>Hello</h1>"))
    #expect(messages[1] == userMessage)
  }

  @Test
  func rendersAmbiguousRecentFilesWithoutActivePath() {
    let state = ChatSessionState(
      messages: [ChatMessage(userContent: "change the file again")],
      attachments: [],
      focusedFileState: FocusedFileState(
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
      ),
      systemPrompt: "System",
      generationSettings: .codingDefault
    )

    let messages = ChatModelContextBuilder().messages(from: state)

    #expect(messages.first?.kind == .system)
    #expect(messages.first?.content.contains("Recent files are ambiguous:") == true)
    #expect(messages.first?.content.contains("Current focused file:") == false)
    #expect(messages.first?.content.contains("- index.html") == true)
    #expect(messages.first?.content.contains("- style.css") == true)
  }
}
