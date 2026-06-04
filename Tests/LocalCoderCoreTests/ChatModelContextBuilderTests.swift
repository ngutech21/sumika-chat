import Foundation
import Testing

@testable import LocalCoderCore

struct ChatModelContextBuilderTests {
  @Test
  func filtersTranscriptEntriesFromExcludedTurnsButKeepsLegacyEntries() throws {
    let includedTurnID = UUID()
    let excludedTurnID = UUID()
    let legacyEntry = try ModelFacingPromptRenderer.legacyEntry(role: .user, content: "legacy")
    let includedEntry = try ModelFacingPromptRenderer.assistantOutputEntry(
      turnID: includedTurnID,
      content: "included"
    )
    let excludedEntry = try ModelFacingPromptRenderer.userPromptEntry(
      turnID: excludedTurnID,
      prompt: "large listing"
    )
    let state = ChatSessionState(
      messages: [],
      modelFacingTranscript: ModelFacingTranscript(
        entries: [legacyEntry, includedEntry, excludedEntry]
      ),
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

    let transcript = ChatModelContextBuilder().transcript(from: state)

    #expect(transcript.entries == [legacyEntry, includedEntry])
  }

  @Test
  func includesExcludedTurnWhenItIsTheActiveTurn() throws {
    let turnID = UUID()
    let toolResult = try ModelFacingPromptRenderer.userPromptEntry(
      turnID: turnID,
      prompt: "README.md"
    )
    let state = ChatSessionState(
      messages: [],
      modelFacingTranscript: ModelFacingTranscript(entries: [toolResult]),
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

    let transcript = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    #expect(transcript.entries == [toolResult])
  }

  @Test
  func currentPromptSystemContextFreezesRenderedFocusedFileContextIntoUserPrompt() throws {
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

    let systemContext = ChatModelContextBuilder().currentPromptSystemContext(
      userInput: "summarize this",
      mode: .chat,
      focusedFileState: state
    )
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "summarize this",
      systemContext: ["System"] + systemContext
    )

    #expect(
      entry.body
        == .userPrompt(
          UserPromptContext(
            prompt: "summarize this",
            systemContext: ["System"] + systemContext
          )
        ))
    #expect(entry.frozenContent.content.contains("Current focused file: index.html"))
    #expect(entry.frozenContent.content.contains("Source: previous write_file"))
    #expect(entry.frozenContent.content.contains("Known content excerpt:"))
    #expect(entry.frozenContent.content.contains("<h1>Hello</h1>"))
  }

  @Test
  func toolResultAppendIsPrefixStableWhenTranscriptMutates() throws {
    let turnID = UUID()
    let sourceMessageID = UUID()
    let firstEntry = try ModelFacingPromptRenderer.assistantOutputEntry(
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      content: "<action name=\"read_file\"></action>"
    )
    var state = ChatSessionState(
      messages: [
        ChatMessage(id: sourceMessageID, assistantContent: "<action name=\"read_file\"></action>")
      ],
      modelFacingTranscript: ModelFacingTranscript(entries: [firstEntry]),
      turns: [ChatTurnRecord(id: turnID, status: .running)],
      attachments: [],
      systemPrompt: "System",
      generationSettings: .codingDefault
    )
    let before = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    ChatTranscriptMutator().annotateToolCall(
      ToolCallModelMessage(callID: UUID(), toolName: .readFile, arguments: []),
      for: sourceMessageID,
      in: &state
    )
    ChatTranscriptMutator().appendModelFacingEntry(
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "observation"),
      to: &state
    )
    let after = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    #expect(Array(after.entries.prefix(before.entries.count)) == before.entries)
    #expect(state.messages[0].kind == .toolCall)
    #expect(after.entries.last?.frozenContent.content == "observation")
  }
}
