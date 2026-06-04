import Foundation
import Testing

@testable import LocalCoderCore

struct ChatTranscriptMutatorTests {
  @Test
  func appendUserMessageKeepsContentAndAttachments() {
    var state = makeState(attachments: [makeAttachment(name: "README.md")])
    let sentAttachments = state.attachments
    let mutator = ChatTranscriptMutator()

    mutator.appendUserMessage("Inspect this file", attachments: sentAttachments, to: &state)

    #expect(state.messages.count == 1)
    #expect(state.messages[0].kind == .user)
    #expect(state.messages[0].content == "Inspect this file")
    #expect(state.messages[0].attachments == sentAttachments)
  }

  @Test
  func appendAssistantPlaceholderUsesProvidedIDAndEmptyContent() {
    var state = makeState()
    let assistantID = UUID()
    let mutator = ChatTranscriptMutator()

    mutator.appendAssistantPlaceholder(id: assistantID, to: &state)

    #expect(state.messages.count == 1)
    #expect(state.messages[0].id == assistantID)
    #expect(state.messages[0].kind == .assistant)
    #expect(state.messages[0].content.isEmpty)
    #expect(state.messages[0].deliveryStatus == .streaming)
  }

  @Test
  func appendChunkUpdatesExistingMessageAndIgnoresMissingID() {
    let assistantID = UUID()
    var state = makeState(messages: [ChatMessage(id: assistantID, assistantContent: "Hel")]
    )
    let mutator = ChatTranscriptMutator()

    mutator.appendChunk("lo", to: assistantID, in: &state)
    mutator.appendChunk(" ignored", to: UUID(), in: &state)

    #expect(state.messages.count == 1)
    #expect(state.messages[0].content == "Hello")
  }

  @Test
  func updateGenerationMetricsPreservesMessagePayload() {
    let attachment = makeAttachment(name: "main.swift")
    let assistantID = UUID()
    let metrics = ChatGenerationMetrics(generatedTokenCount: 12, tokensPerSecond: 4.5)
    var state = makeState(messages: [
      ChatMessage(
        id: assistantID,
        assistantContent: "Answer",
        attachments: [attachment]
      )
    ])
    let mutator = ChatTranscriptMutator()

    mutator.updateGenerationMetrics(metrics, for: assistantID, in: &state)

    #expect(state.messages[0].id == assistantID)
    #expect(state.messages[0].kind == .assistant)
    #expect(state.messages[0].content == "Answer")
    #expect(state.messages[0].attachments == [attachment])
    #expect(state.messages[0].generationMetrics == metrics)
    #expect(state.messages[0].toolCall == nil)
    #expect(state.messages[0].toolResult == nil)
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
    var state = makeState(messages: [
      ChatMessage(
        id: assistantID,
        assistantContent: "<action>",
        attachments: [attachment],
        generationMetrics: metrics
      )
    ])
    let mutator = ChatTranscriptMutator()

    mutator.annotateToolCall(toolCall, for: assistantID, in: &state)

    #expect(state.messages[0].id == assistantID)
    #expect(state.messages[0].kind == .toolCall)
    #expect(state.messages[0].content.isEmpty)
    #expect(state.messages[0].attachments == [attachment])
    #expect(state.messages[0].generationMetrics == metrics)
    #expect(state.messages[0].toolCall == toolCall)
    #expect(state.messages[0].toolResult == nil)
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

    #expect(state.messages.count == 1)
    #expect(state.messages[0].kind == .toolResult)
    #expect(state.messages[0].content.isEmpty)
    #expect(state.messages[0].toolResult == toolResult)
  }

  @Test
  func removeTransientAssistantPlaceholdersKeepsRealAssistantMessages() {
    let emptyAssistantID = UUID()
    let filledAssistant = ChatMessage(assistantContent: "Done")
    let userMessage = ChatMessage(userContent: "Prompt")
    var state = makeState(messages: [
      userMessage,
      ChatMessage(
        id: emptyAssistantID,
        assistantContent: "",
        deliveryStatus: .streaming
      ),
      filledAssistant,
    ])
    let mutator = ChatTranscriptMutator()

    mutator.removeTransientAssistantPlaceholders(from: &state)

    #expect(state.messages == [userMessage, filledAssistant])
  }

  @Test
  func removeTransientAssistantPlaceholdersRemovesMessageIDsFromTurns() {
    let turnID = UUID()
    let userID = UUID()
    let emptyAssistantID = UUID()
    let filledAssistantID = UUID()
    var state = makeState(
      messages: [
        ChatMessage(id: userID, userContent: "Prompt", turnID: turnID),
        ChatMessage(
          id: emptyAssistantID,
          assistantContent: "",
          deliveryStatus: .streaming,
          turnID: turnID,
        ),
        ChatMessage(
          id: filledAssistantID,
          assistantContent: "Done",
          deliveryStatus: .complete,
          turnID: turnID
        ),
      ],
      turns: [
        ChatTurnRecord(
          id: turnID,
          status: .cancelled,
          messageIDs: [userID, emptyAssistantID, filledAssistantID]
        )
      ]
    )
    let mutator = ChatTranscriptMutator()

    mutator.removeTransientAssistantPlaceholders(from: &state)

    #expect(state.messages.map(\.id) == [userID, filledAssistantID])
    #expect(state.turns[0].messageIDs == [userID, filledAssistantID])
  }

  @Test
  func clearTranscriptClearsMessagesToolsTurnsAndAttachmentsOnly() {
    let attachment = makeAttachment(name: "notes.txt")
    let settings = ChatGenerationSettings(temperature: 0.2, topP: 0.8, topK: 10, maxTokens: 256)
    let turn = ChatTurnRecord(status: .completed)
    let toolCall = makeToolCallRecord()
    var state = makeState(
      messages: [ChatMessage(userContent: "Prompt")],
      toolCalls: [toolCall],
      turns: [turn],
      attachments: [attachment],
      systemPrompt: "Keep this prompt",
      generationSettings: settings
    )
    let mutator = ChatTranscriptMutator()

    mutator.clearTranscript(in: &state)

    #expect(state.messages.isEmpty)
    #expect(state.toolCalls.isEmpty)
    #expect(state.turns.isEmpty)
    #expect(state.attachments.isEmpty)
    #expect(state.systemPrompt == "Keep this prompt")
    #expect(state.generationSettings == settings)
  }

  @Test
  func removeMessageDeletesMatchingMessageOnly() {
    let removedID = UUID()
    let kept = ChatMessage(assistantContent: "Keep")
    var state = makeState(messages: [
      ChatMessage(id: removedID, userContent: "Remove"),
      kept,
    ])
    let mutator = ChatTranscriptMutator()

    mutator.removeMessage(id: removedID, from: &state)

    #expect(state.messages == [kept])
  }
}

private func makeState(
  messages: [ChatMessage] = [],
  toolCalls: [ToolCallRecord] = [],
  turns: [ChatTurnRecord] = [],
  attachments: [ChatAttachment] = [],
  systemPrompt: String = "System",
  generationSettings: ChatGenerationSettings = .codingDefault
) -> ChatSessionState {
  ChatSessionState(
    messages: messages,
    toolCalls: toolCalls,
    turns: turns,
    attachments: attachments,
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
