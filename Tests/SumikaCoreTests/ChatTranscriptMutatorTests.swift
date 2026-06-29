import Foundation
import Testing

@testable import SumikaCore

struct ChatTranscriptMutatorTests {
  @Test
  func appendUserMessageKeepsContentAndAttachments() {
    var state = makeState(attachments: [makeAttachment(name: "README.md")])
    let sentAttachments = state.pendingAttachments
    let mutator = ChatTranscriptMutator()

    mutator.appendUserMessage("Inspect this file", attachments: sentAttachments, to: &state)

    let items = state.transcriptItemsForTesting
    #expect(items.count == 1)
    #expect(items[0].kindForTesting == .user)
    #expect(items[0].contentForTesting == "Inspect this file")
    #expect(items[0].attachmentsForTesting == sentAttachments)
  }

  @Test
  func appendAssistantPlaceholderUsesProvidedIDAndEmptyContent() {
    var state = makeState()
    let assistantID = UUID()
    let mutator = ChatTranscriptMutator()

    mutator.appendAssistantPlaceholder(id: assistantID, to: &state)

    let items = state.transcriptItemsForTesting
    #expect(items.count == 1)
    #expect(items[0].messageID == assistantID)
    #expect(items[0].kindForTesting == .assistant)
    #expect(items[0].contentForTesting.isEmpty)
    #expect(items[0].deliveryStatusForTesting == .streaming)
  }

  @Test
  func appendChunkUpdatesExistingMessageAndIgnoresMissingID() {
    let assistantID = UUID()
    var state = makeState(items: [
      .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Hel"))
    ]
    )
    let mutator = ChatTranscriptMutator()

    mutator.appendChunk("lo", to: assistantID, in: &state)
    mutator.appendChunk(" ignored", to: UUID(), in: &state)

    let items = state.transcriptItemsForTesting
    #expect(items.count == 1)
    #expect(items[0].contentForTesting == "Hello")
  }

  @Test
  func updateGenerationMetricsPreservesMessagePayload() {
    let attachment = makeAttachment(name: "main.swift")
    let assistantID = UUID()
    let metrics = ChatGenerationMetrics(
      generatedTokenCount: 12,
      tokensPerSecond: 4.5,
      durationMs: 2_666.67
    )
    var state = makeState(items: [
      .assistantMessage(
        AssistantTurnMessage(
          id: assistantID,
          content: "Answer",
          attachments: [attachment]
        ))
    ])
    let mutator = ChatTranscriptMutator()

    mutator.updateGenerationMetrics(metrics, for: assistantID, in: &state)

    let items = state.transcriptItemsForTesting
    #expect(items[0].messageID == assistantID)
    #expect(items[0].kindForTesting == .assistant)
    #expect(items[0].contentForTesting == "Answer")
    #expect(items[0].attachmentsForTesting == [attachment])
    #expect(items[0].generationMetricsForTesting == metrics)
    #expect(items[0].toolCallForTesting(records: state.toolCalls) == nil)
    #expect(items[0].toolResultForTesting(records: state.toolCalls) == nil)
  }

  @Test
  func annotateToolCallCreatesValidToolCallMessageAndKeepsContext() {
    let attachment = makeAttachment(name: "Package.swift")
    let assistantID = UUID()
    let metrics = ChatGenerationMetrics(
      generatedTokenCount: 20, tokensPerSecond: 8, durationMs: 250)
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .readFile,
      arguments: [ToolCallModelArgument(name: "path", value: "Package.swift")]
    )
    var state = makeState(items: [
      .assistantMessage(
        AssistantTurnMessage(
          id: assistantID,
          content: "I will read Package.swift.",
          attachments: [attachment],
          generationMetrics: metrics
        ))
    ])
    let mutator = ChatTranscriptMutator()

    mutator.annotateToolCall(toolCall, for: assistantID, in: &state)

    let items = state.transcriptItemsForTesting
    #expect(items.count == 2)
    #expect(items[0].kindForTesting == .assistant)
    #expect(items[1].kindForTesting == .toolCall)
    #expect(items[1].contentForTesting.isEmpty)
    #expect(state.toolCalls.first?.id == toolCall.callID)
    #expect(items[1].toolCallForTesting(records: state.toolCalls) == toolCall)
    #expect(items[1].toolResultForTesting(records: state.toolCalls) == nil)
  }

  @Test
  func annotateEditFileToolCallRedactsPayloadFromModelHistory() throws {
    let assistantID = UUID()
    let oldText = "if ball.left <= 0:\n    pass"
    let newText = "if ball.left <= 0:\n    ball.center = (SCREEN_WIDTH/2, SCREEN_HEIGHT/2)"
    let nativeBoundary = NativeToolCallBoundaryRenderer.renderGemma4(
      toolName: ToolName.editFile.rawValue,
      arguments: [
        "path": .string("pong.py"),
        "old_text": .string(oldText),
        "new_text": .string(newText),
      ]
    )
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .editFile,
      arguments: [
        ToolCallModelArgument(name: "new_text", value: newText),
        ToolCallModelArgument(name: "old_text", value: oldText),
        ToolCallModelArgument(name: "path", value: "pong.py"),
      ],
      rawText: nativeBoundary
    )
    var state = makeState(items: [
      .assistantMessage(AssistantTurnMessage(id: assistantID, content: "I will edit pong.py."))
    ])
    try ChatTranscriptMutator().appendModelContextEntry(
      ModelFacingPromptRenderer.assistantOutputEntry(
        sourceMessageID: assistantID,
        content: "I will edit pong.py.\n\n\(nativeBoundary)"
      ),
      to: &state
    )

    ChatTranscriptMutator().annotateToolCall(toolCall, for: assistantID, in: &state)

    let content = try #require(state.modelContextSnapshot.entries.first?.frozenContent.content)
    #expect(content.contains("I will edit pong.py."))
    #expect(content.contains("Tool call edit_file requested."))
    #expect(content.contains("Path:\npong.py"))
    #expect(content.contains("Payload omitted from history."))
    #expect(!content.contains(oldText))
    #expect(!content.contains(newText))
    #expect(!content.contains("old_text:"))
    #expect(!content.contains("new_text:"))
    #expect(state.toolCalls.first?.request.rawArguments["old_text"] == .string(oldText))
    #expect(state.toolCalls.first?.request.rawArguments["new_text"] == .string(newText))
  }

  @Test
  func annotateWriteFileToolCallRedactsContentFromModelHistory() throws {
    let assistantID = UUID()
    let fileContent = "<html><body><h1>Large generated file</h1></body></html>"
    let nativeBoundary = NativeToolCallBoundaryRenderer.renderGemma4(
      toolName: ToolName.writeFile.rawValue,
      arguments: [
        "path": .string("index.html"),
        "content": .string(fileContent),
      ]
    )
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .writeFile,
      arguments: [
        ToolCallModelArgument(name: "content", value: fileContent),
        ToolCallModelArgument(name: "path", value: "index.html"),
      ],
      rawText: nativeBoundary
    )
    var state = makeState(items: [
      .assistantMessage(AssistantTurnMessage(id: assistantID, content: "I will write index.html."))
    ])
    try ChatTranscriptMutator().appendModelContextEntry(
      ModelFacingPromptRenderer.assistantOutputEntry(
        sourceMessageID: assistantID,
        content: nativeBoundary
      ),
      to: &state
    )

    ChatTranscriptMutator().annotateToolCall(toolCall, for: assistantID, in: &state)

    let content = try #require(state.modelContextSnapshot.entries.first?.frozenContent.content)
    #expect(content.contains("Tool call write_file requested."))
    #expect(content.contains("Path:\nindex.html"))
    #expect(content.contains("Payload omitted from history."))
    #expect(!content.contains(fileContent))
    #expect(!content.contains("content:"))
    #expect(state.toolCalls.first?.request.rawArguments["content"] == .string(fileContent))
  }

  @Test
  func annotateTodoToolCallDoesNotMutateModelHistory() throws {
    let assistantID = UUID()
    let nativeBoundary = NativeToolCallBoundaryRenderer.renderGemma4(
      toolName: ToolName.todoWrite.rawValue,
      arguments: [
        "item1": .string("Inspect affected files"),
        "done1": .bool(false),
        "item2": .string("Run tests"),
        "done2": .bool(false),
      ]
    )
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .todoWrite,
      arguments: [
        ToolCallModelArgument(
          name: "item1",
          value: "Inspect affected files"
        ),
        ToolCallModelArgument(
          name: "done1",
          value: "false"
        ),
        ToolCallModelArgument(
          name: "item2",
          value: "Run tests"
        ),
        ToolCallModelArgument(
          name: "done2",
          value: "false"
        ),
      ],
      rawText: nativeBoundary
    )
    var state = makeState(items: [
      .assistantMessage(AssistantTurnMessage(id: assistantID, content: "I will update the plan."))
    ])
    try ChatTranscriptMutator().appendModelContextEntry(
      ModelFacingPromptRenderer.assistantOutputEntry(
        sourceMessageID: assistantID,
        content: nativeBoundary
      ),
      to: &state
    )

    ChatTranscriptMutator().annotateToolCall(toolCall, for: assistantID, in: &state)

    let content = try #require(state.modelContextSnapshot.entries.first?.frozenContent.content)
    #expect(content == nativeBoundary)
  }

  @Test
  func appendToolResultCreatesToolResultMessage() {
    var state = makeState()
    let toolResult = ToolResultModelMessage(
      callID: UUID(),
      toolName: .listFiles,
      payload: .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "README.md"), kind: .file)
          ]
        ))
    )
    let mutator = ChatTranscriptMutator()

    mutator.appendToolResult(toolResult, to: &state)

    let items = state.transcriptItemsForTesting
    #expect(items.count == 1)
    #expect(items[0].kindForTesting == .toolResult)
    #expect(items[0].contentForTesting.isEmpty)
    #expect(items[0].toolResultForTesting(records: state.toolCalls) == toolResult)
  }

  @Test
  func removeTransientAssistantPlaceholdersCancelsEmptyStreamingMessages() {
    let emptyAssistantID = UUID()
    let filledAssistant = AssistantTurnMessage(content: "Done")
    let userMessage = UserTurnMessage(content: "Prompt")
    var state = makeState(items: [
      .userMessage(userMessage),
      .assistantMessage(
        AssistantTurnMessage(
          id: emptyAssistantID,
          content: "",
          deliveryStatus: .streaming
        )),
      .assistantMessage(filledAssistant),
    ])
    let mutator = ChatTranscriptMutator()

    mutator.removeTransientAssistantPlaceholders(from: &state)

    let items = state.transcriptItemsForTesting
    #expect(items.count == 3)
    #expect(items[0] == .userMessage(userMessage))
    #expect(items[1].deliveryStatusForTesting == .cancelled)
    #expect(items[2] == .assistantMessage(filledAssistant))
  }

  @Test
  func removeTransientAssistantPlaceholdersPreservesTurnOrdering() {
    let turnID = UUID()
    let userID = UUID()
    let emptyAssistantID = UUID()
    let filledAssistantID = UUID()
    var state = makeState(
      turns: [
        ChatTurn(
          id: turnID,
          status: .cancelled,
          items: [
            .userMessage(UserTurnMessage(id: userID, content: "Prompt")),
            .assistantMessage(
              AssistantTurnMessage(
                id: emptyAssistantID,
                content: "",
                deliveryStatus: .streaming
              )),
            .assistantMessage(
              AssistantTurnMessage(
                id: filledAssistantID,
                content: "Done",
                deliveryStatus: .complete
              )),
          ]
        )
      ]
    )
    let mutator = ChatTranscriptMutator()

    mutator.removeTransientAssistantPlaceholders(from: &state)

    #expect(
      state.transcriptItemsForTesting.compactMap(\.messageID) == [
        userID, emptyAssistantID, filledAssistantID,
      ])
    #expect(
      state.turns[0].items.map(testMessageID) == [userID, emptyAssistantID, filledAssistantID])
    #expect(state.turns[0].items[1].deliveryStatusForTesting == .cancelled)
  }

  @Test
  func clearTranscriptClearsMessagesToolsTurnsAttachmentsAndTodoStateOnly() {
    let attachment = makeAttachment(name: "notes.txt")
    let settings = ChatGenerationSettings(temperature: 0.2, topP: 0.8, topK: 10, maxTokens: 256)
    let turn = ChatTurn(status: .completed)
    let toolCall = makeToolCallRecord()
    var state = makeState(
      turns: [
        ChatTurn(
          id: turn.id,
          status: .completed,
          items: [.userMessage(UserTurnMessage(content: "Prompt")), .tool(toolCall)]
        )
      ],
      attachments: [attachment],
      todoState: TodoState(items: [
        TodoItem(id: "inspect", content: "Inspect files", status: .completed),
        TodoItem(id: "verify", content: "Run tests", status: .pending),
      ]),
      systemPrompt: "Keep this prompt",
      generationSettings: settings
    )
    let mutator = ChatTranscriptMutator()

    mutator.clearTranscript(in: &state)

    #expect(state.transcriptItemsForTesting.isEmpty)
    #expect(state.toolCalls.isEmpty)
    #expect(state.turns.isEmpty)
    #expect(state.pendingAttachments.isEmpty)
    #expect(state.todoState == nil)
    #expect(state.systemPrompt == "Keep this prompt")
    #expect(state.generationSettings == settings)
  }

  @Test
  func removeMessageDoesNotDeletePersistedItems() {
    let removedID = UUID()
    let kept = AssistantTurnMessage(content: "Keep")
    var state = makeState(items: [
      .userMessage(UserTurnMessage(id: removedID, content: "Remove")),
      .assistantMessage(kept),
    ])
    let mutator = ChatTranscriptMutator()

    mutator.removeMessage(id: removedID, from: &state)

    #expect(
      state.transcriptItemsForTesting == [
        .userMessage(UserTurnMessage(id: removedID, content: "Remove")),
        .assistantMessage(kept),
      ])
  }
}

private func makeState(
  items: [ChatTurnItem] = [],
  turns: [ChatTurn] = [],
  attachments: [ChatAttachment] = [],
  todoState: TodoState? = nil,
  systemPrompt: String = "System",
  generationSettings: ChatGenerationSettings = .agentDefault
) -> ChatSession {
  let resolvedTurns =
    turns.isEmpty && !items.isEmpty
    ? [ChatTurn(status: .running, items: items)]
    : turns
  return ChatSession(
    turns: resolvedTurns,
    pendingAttachments: attachments,
    modeSettings: testModeSettings(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings
    ),
    todoState: todoState
  )
}

private func makeAttachment(name: String) -> ChatAttachment {
  ChatAttachment(
    url: URL(fileURLWithPath: "/tmp/\(name)"),
    displayName: name,
    kind: .text,
    content: "content"
  )
}

private func makeToolCallRecord() -> ToolCallRecord {
  let rawRequest = RawToolCallRequest(
    workspaceID: UUID(),
    sessionID: UUID(),
    toolName: .listFiles
  )
  let request = ToolCallRequest.validated(
    raw: rawRequest,
    payload: .listFiles(ListFilesInput(path: nil))
  )
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .completed(
      .listFiles(ListFilesResult(root: WorkspaceRelativePath(rawValue: "."), entries: [])))
  )
}
