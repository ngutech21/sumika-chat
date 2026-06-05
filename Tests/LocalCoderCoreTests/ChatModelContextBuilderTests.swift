import Foundation
import Testing

@testable import LocalCoderCore

struct ChatModelContextBuilderTests {
  @Test
  func filtersTranscriptEntriesFromExcludedTurnsButKeepsEntriesWithoutTurnID() throws {
    let includedTurnID = UUID()
    let excludedTurnID = UUID()
    let unscopedEntry = try ModelFacingPromptRenderer.userPromptEntry(prompt: "unscoped")
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
        entries: [unscopedEntry, includedEntry, excludedEntry]
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

    #expect(transcript.entries == [unscopedEntry, includedEntry])
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

    let currentPromptContext = ChatModelContextBuilder().currentPromptContext(
      userInput: "summarize this",
      mode: .chat,
      focusedFileState: state
    )
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "summarize this",
      systemContext: ["System"] + currentPromptContext.renderedBlocks,
      currentPromptContext: currentPromptContext.consumedContext
    )

    #expect(
      entry.body
        == .userPrompt(
          UserPromptContext(
            prompt: "summarize this",
            systemContext: ["System"] + currentPromptContext.renderedBlocks,
            currentPromptContext: currentPromptContext.consumedContext
          )
        ))
    guard case .userPrompt(let userPromptContext) = entry.body,
      case .selected(let consumedSelection) = userPromptContext.currentPromptContext,
      case .focusedFile(let consumedFocusedFile) = consumedSelection.blocks.values[0]
    else {
      Issue.record("Expected typed focused file context snapshot.")
      return
    }
    #expect(consumedFocusedFile.path == path)
    #expect(consumedFocusedFile.source == .writeFile)
    #expect(consumedFocusedFile.contentHash == "hash")
    #expect(consumedFocusedFile.excerpt?.text == "<h1>Hello</h1>")
    #expect(entry.frozenContent.content.contains("Current focused file: index.html"))
    #expect(entry.frozenContent.content.contains("Source: previous write_file"))
    #expect(entry.frozenContent.content.contains("Known content excerpt:"))
    #expect(entry.frozenContent.content.contains("<h1>Hello</h1>"))
  }

  @Test
  func currentPromptSystemContextFreezesRenderedAttachedFileContextIntoUserPrompt() throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/project/Sources/Foo.swift"),
      displayName: "Foo.swift",
      kind: .text,
      content: "func attached() {}"
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory)
    )

    let currentPromptContext = ChatModelContextBuilder().currentPromptContext(
      userInput: "explain attached",
      mode: .inspect,
      focusedFileState: .empty,
      attachments: [attachment],
      workspace: workspace
    )
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "explain attached",
      attachments: [attachment],
      systemContext: ["System"] + currentPromptContext.renderedBlocks,
      currentPromptContext: currentPromptContext.consumedContext
    )

    #expect(
      entry.body
        == .userPrompt(
          UserPromptContext(
            prompt: "explain attached",
            attachmentNames: ["Foo.swift"],
            systemContext: ["System"] + currentPromptContext.renderedBlocks,
            currentPromptContext: currentPromptContext.consumedContext
          )
        ))
    guard case .userPrompt(let userPromptContext) = entry.body,
      case .selected(let consumedSelection) = userPromptContext.currentPromptContext,
      case .attachedFile(let consumedAttachment) = consumedSelection.blocks.values[0]
    else {
      Issue.record("Expected typed attached file context snapshot.")
      return
    }
    #expect(consumedAttachment.path == WorkspaceRelativePath(rawValue: "Sources/Foo.swift"))
    #expect(consumedAttachment.displayName == "Foo.swift")
    #expect(consumedAttachment.excerpt?.text == "func attached() {}")
    #expect(entry.frozenContent.content.contains("Attached file: Sources/Foo.swift"))
    #expect(entry.frozenContent.content.contains("Attached content excerpt:"))
    #expect(entry.frozenContent.content.contains("func attached() {}"))
    #expect(entry.frozenContent.content.contains("Attached context:") == false)
    #expect(entry.frozenContent.content.contains("File: Foo.swift") == false)
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
