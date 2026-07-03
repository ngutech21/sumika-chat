import Foundation
import Testing

@testable import SumikaCore

struct ChatModelContextBuilderTests {
  @Test
  func filtersProjectionEntriesFromExcludedTurns() throws {
    let includedTurnID = UUID()
    let excludedTurnID = UUID()
    let state = ChatSession(
      turns: [
        ChatTurn(
          id: includedTurnID,
          status: .completed,
          items: [
            .userMessage(UserTurnMessage(content: "included prompt")),
            .assistantMessage(AssistantTurnMessage(content: "included")),
          ]),
        ChatTurn(
          id: excludedTurnID,
          status: .cancelled,
          modelContextPolicy: .excluded,
          items: [.userMessage(UserTurnMessage(content: "large listing"))]
        ),
      ],
      pendingAttachments: [],
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      )
    )

    let transcript = ChatModelContextBuilder().transcript(from: state)

    #expect(transcript.entries.map(\.frozenContent.role) == [.user, .assistant])
    #expect(transcript.entries[0].frozenContent.content == "included prompt")
    #expect(transcript.entries[1].frozenContent.content == "included")
  }

  @Test
  func includesExcludedTurnWhenItIsTheActiveTurn() throws {
    let turnID = UUID()
    let state = ChatSession(
      turns: [
        ChatTurn(
          id: turnID,
          status: .cancelled,
          modelContextPolicy: .excluded,
          items: [.userMessage(UserTurnMessage(content: "README.md"))]
        )
      ],
      pendingAttachments: [],
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      )
    )

    let transcript = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    #expect(transcript.entries.map(\.frozenContent.content) == ["README.md"])
  }

  @Test
  func assistantProjectionPolicyOverridesOrExcludesVisibleContent() throws {
    let state = ChatSession(
      turns: [
        ChatTurn(
          status: .completed,
          items: [
            .assistantMessage(AssistantTurnMessage(content: "Visible content.")),
            .assistantMessage(
              AssistantTurnMessage(
                content: "Large direct tool response.",
                modelProjectionPolicy: .override("Displayed direct tool result.")
              )),
            .assistantMessage(
              AssistantTurnMessage(
                content: "Visible but excluded from model context.",
                modelProjectionPolicy: .excluded
              )),
          ])
      ]
    )

    let transcript = ChatModelContextBuilder().transcript(from: state)

    #expect(transcript.entries.map(\.frozenContent.role) == [.assistant, .assistant])
    #expect(
      transcript.entries.map(\.frozenContent.content) == [
        "Visible content.",
        "Displayed direct tool result.",
      ])
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
      mode: .agent,
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
    #expect(consumedAttachment.path == WorkspaceRelativePath(rawValue: "Foo.swift"))
    #expect(consumedAttachment.displayName == "Foo.swift")
    #expect(consumedAttachment.excerpt?.text == "func attached() {}")
    #expect(entry.frozenContent.content.contains("Attached file: Foo.swift"))
    #expect(entry.frozenContent.content.contains("Attached content excerpt:"))
    #expect(entry.frozenContent.content.contains("func attached() {}"))
    #expect(entry.frozenContent.content.contains("Attached context:") == false)
    #expect(entry.frozenContent.content.contains("File: Foo.swift") == false)
  }

  @Test
  func toolResultAppendIsPrefixStableWhenTranscriptMutates() throws {
    let turnID = UUID()
    let sourceMessageID = UUID()
    let toolRecord = makeCompletedReadFileRecord()
    var state = ChatSession(
      turns: [
        ChatTurn(
          id: turnID,
          status: .running,
          items: [
            .assistantMessage(
              AssistantTurnMessage(
                id: sourceMessageID,
                content: "I will read README.md."
              ))
          ]
        )
      ],
      pendingAttachments: [],
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      )
    )
    let before = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    ChatTranscriptMutator().recordToolCall(toolRecord, turnID: turnID, in: &state)
    let after = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    #expect(
      Array(after.entries.prefix(before.entries.count)).map(\.frozenContent)
        == before.entries.map(\.frozenContent))
    #expect(
      Array(after.entries.prefix(before.entries.count)).map(\.sourceMessageID)
        == before.entries.map(\.sourceMessageID))
    #expect(state.transcriptItemsForTesting.map(\.kindForTesting) == [.assistant, .toolResult])
    #expect(after.entries.last?.sourceMessageID == toolRecord.id)
  }

  private func makeCompletedReadFileRecord() -> ToolCallRecord {
    let path = WorkspaceRelativePath(rawValue: "README.md")
    let rawRequest = RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .readFile,
      arguments: ["path": .string(path.rawValue)]
    )
    let request = ToolCallRequest.validated(
      raw: rawRequest,
      payload: .readFile(ReadFileInput(path: path.rawValue))
    )
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed in test.",
        riskLevel: .low
      ),
      state: .completed(
        .readFile(
          .success(
            path: path,
            content: ToolTextOutput(text: "contents", truncated: false, redacted: false)
          )))
    )
  }
}
