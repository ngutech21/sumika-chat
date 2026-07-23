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
  func thinkingChunkAndCompletionTimestampsYieldReasoningDuration() throws {
    let thinkingID = UUID()
    let firstChunkAt = Date(timeIntervalSinceReferenceDate: 100)
    var turn = ChatTurn(
      status: .running,
      items: [
        .assistantThinking(
          AssistantThinkingMessage(id: thinkingID, content: "", deliveryStatus: .streaming))
      ]
    )

    turn.appendAssistantThinkingChunk("Weighing options.", to: thinkingID, at: firstChunkAt)
    turn.appendAssistantThinkingChunk(
      " More evidence.", to: thinkingID, at: firstChunkAt.addingTimeInterval(5))
    turn.updateAssistantThinkingDeliveryStatus(
      .complete, for: thinkingID, at: firstChunkAt.addingTimeInterval(12))

    guard case .assistantThinking(let message) = try #require(turn.items.first) else {
      Issue.record("Expected assistant thinking item.")
      return
    }
    #expect(message.startedAt == firstChunkAt)
    #expect(message.completedAt == firstChunkAt.addingTimeInterval(12))
    #expect(message.reasoningDuration == 12)
  }

  @Test
  func cancelledThinkingRecordsCompletionTimestamp() throws {
    let thinkingID = UUID()
    let cancelledAt = Date(timeIntervalSinceReferenceDate: 250)
    var turn = ChatTurn(
      status: .running,
      items: [
        .assistantThinking(
          AssistantThinkingMessage(id: thinkingID, content: "Partial", deliveryStatus: .streaming))
      ]
    )

    turn.markStreamingAssistantMessagesCancelled(at: cancelledAt)

    guard case .assistantThinking(let message) = try #require(turn.items.first) else {
      Issue.record("Expected assistant thinking item.")
      return
    }
    #expect(message.deliveryStatus == .cancelled)
    #expect(message.completedAt == cancelledAt)
    #expect(message.reasoningDuration == nil)
  }

  @Test
  func updateGenerationMetricsPreservesMessagePayload() {
    let attachment = makeAttachment(name: "main.swift")
    let assistantID = UUID()
    let metrics = ChatGenerationMetrics(
      generatedTokenCount: 12,
      tokensPerSecond: 4.5
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
    let metrics = ChatGenerationMetrics(generatedTokenCount: 20, tokensPerSecond: 8)
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
