import Foundation
import Testing

@testable import local_coder

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

    #expect(state.messages == [ChatMessage(id: assistantID, kind: .assistant, content: "")])
  }

  @Test
  func appendChunkUpdatesExistingMessageAndIgnoresMissingID() {
    let assistantID = UUID()
    var state = makeState(messages: [ChatMessage(id: assistantID, kind: .assistant, content: "Hel")]
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
        kind: .assistant,
        content: "Answer",
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
    let metrics = ChatGenerationMetrics(generatedTokenCount: 20, tokensPerSecond: 8)
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .readFile,
      arguments: [ToolCallModelArgument(name: "path", value: "Package.swift")]
    )
    var state = makeState(messages: [
      ChatMessage(
        id: assistantID,
        kind: .assistant,
        content: "<action>",
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
      preview: ToolResultPreview(text: "README.md")
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
    let filledAssistant = ChatMessage(kind: .assistant, content: "Done")
    let userMessage = ChatMessage(kind: .user, content: "Prompt")
    var state = makeState(messages: [
      userMessage,
      ChatMessage(id: emptyAssistantID, kind: .assistant, content: ""),
      filledAssistant,
    ])
    let mutator = ChatTranscriptMutator()

    mutator.removeTransientAssistantPlaceholders(from: &state)

    #expect(state.messages == [userMessage, filledAssistant])
  }

  @Test
  func clearTranscriptClearsMessagesAndAttachmentsOnly() {
    let attachment = makeAttachment(name: "notes.txt")
    let settings = ChatGenerationSettings(temperature: 0.2, topP: 0.8, topK: 10, maxTokens: 256)
    var state = makeState(
      messages: [ChatMessage(kind: .user, content: "Prompt")],
      attachments: [attachment],
      systemPrompt: "Keep this prompt",
      generationSettings: settings
    )
    let mutator = ChatTranscriptMutator()

    mutator.clearTranscript(in: &state)

    #expect(state.messages.isEmpty)
    #expect(state.attachments.isEmpty)
    #expect(state.systemPrompt == "Keep this prompt")
    #expect(state.generationSettings == settings)
  }

  @Test
  func removeMessageDeletesMatchingMessageOnly() {
    let removedID = UUID()
    let kept = ChatMessage(kind: .assistant, content: "Keep")
    var state = makeState(messages: [
      ChatMessage(id: removedID, kind: .user, content: "Remove"),
      kept,
    ])
    let mutator = ChatTranscriptMutator()

    mutator.removeMessage(id: removedID, from: &state)

    #expect(state.messages == [kept])
  }
}

private func makeState(
  messages: [ChatMessage] = [],
  attachments: [ChatAttachment] = [],
  systemPrompt: String = "System",
  generationSettings: ChatGenerationSettings = .codingDefault
) -> ChatSessionState {
  ChatSessionState(
    messages: messages,
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
