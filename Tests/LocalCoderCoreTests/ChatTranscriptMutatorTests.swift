import Foundation
import Testing

@testable import LocalCoderCore

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
    let metrics = ChatGenerationMetrics(generatedTokenCount: 12, tokensPerSecond: 4.5)
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
          content: "<action>",
          attachments: [attachment],
          generationMetrics: metrics
        ))
    ])
    let mutator = ChatTranscriptMutator()

    mutator.annotateToolCall(toolCall, for: assistantID, in: &state)

    _ = assistantID
    let items = state.transcriptItemsForTesting
    #expect(items[0].kindForTesting == .toolCall)
    #expect(items[0].contentForTesting.isEmpty)
    _ = attachment
    _ = metrics
    #expect(state.turns[0].items == [.toolCall(toolCall.callID)])
    #expect(state.toolCalls.first?.id == toolCall.callID)
    #expect(items[0].toolCallForTesting(records: state.toolCalls) == toolCall)
    #expect(items[0].toolResultForTesting(records: state.toolCalls) == nil)
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
  func removeTransientAssistantPlaceholdersKeepsRealAssistantMessages() {
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

    #expect(
      state.transcriptItemsForTesting == [
        .userMessage(userMessage), .assistantMessage(filledAssistant),
      ])
  }

  @Test
  func removeTransientAssistantPlaceholdersRemovesMessageIDsFromTurns() {
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

    #expect(state.transcriptItemsForTesting.compactMap(\.messageID) == [userID, filledAssistantID])
    #expect(state.turns[0].items.map(testMessageID) == [userID, filledAssistantID])
  }

  @Test
  func clearTranscriptClearsMessagesToolsTurnsAndAttachmentsOnly() {
    let attachment = makeAttachment(name: "notes.txt")
    let settings = ChatGenerationSettings(temperature: 0.2, topP: 0.8, topK: 10, maxTokens: 256)
    let turn = ChatTurn(status: .completed)
    let toolCall = makeToolCallRecord()
    var state = makeState(
      items: [.userMessage(UserTurnMessage(content: "Prompt"))],
      toolCalls: [toolCall],
      turns: [turn],
      attachments: [attachment],
      systemPrompt: "Keep this prompt",
      generationSettings: settings
    )
    let mutator = ChatTranscriptMutator()

    mutator.clearTranscript(in: &state)

    #expect(state.transcriptItemsForTesting.isEmpty)
    #expect(state.toolCalls.isEmpty)
    #expect(state.turns.isEmpty)
    #expect(state.pendingAttachments.isEmpty)
    #expect(state.systemPrompt == "Keep this prompt")
    #expect(state.generationSettings == settings)
  }

  @Test
  func removeMessageDeletesMatchingMessageOnly() {
    let removedID = UUID()
    let kept = AssistantTurnMessage(content: "Keep")
    var state = makeState(items: [
      .userMessage(UserTurnMessage(id: removedID, content: "Remove")),
      .assistantMessage(kept),
    ])
    let mutator = ChatTranscriptMutator()

    mutator.removeMessage(id: removedID, from: &state)

    #expect(state.transcriptItemsForTesting == [.assistantMessage(kept)])
  }
}

private func makeState(
  items: [ChatTurnItem] = [],
  toolCalls: [ToolCallRecord] = [],
  turns: [ChatTurn] = [],
  attachments: [ChatAttachment] = [],
  systemPrompt: String = "System",
  generationSettings: ChatGenerationSettings = .codingDefault
) -> ChatSessionState {
  let resolvedTurns =
    turns.isEmpty && !items.isEmpty
    ? [ChatTurn(status: .running, items: items)]
    : turns
  return ChatSessionState(
    toolCalls: toolCalls,
    turns: resolvedTurns,
    pendingAttachments: attachments,
    systemPrompt: systemPrompt,
    generationSettings: generationSettings
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
