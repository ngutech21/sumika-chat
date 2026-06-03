import Foundation
import Testing

@testable import local_coder

struct ChatMessageTests {
  @Test
  func detectsStreamingToolCallMarkupPrefixes() {
    let partialMessages = [
      "<",
      "<act",
      "<action",
      "<action name=\"list_files\">",
    ]

    for content in partialMessages {
      let message = ChatMessage(assistantContent: content)

      #expect(message.containsStreamingToolCallMarkup)
    }
  }

  @Test
  func ignoresPlainAssistantContentWhenDetectingStreamingToolCallMarkup() {
    let message = ChatMessage(assistantContent: "Here are the files:")

    #expect(!message.containsStreamingToolCallMarkup)
  }

  @Test
  func ignoresToolCallMessagesWhenDetectingStreamingToolCallMarkup() {
    let message = ChatMessage(
      toolCall: ToolCallModelMessage(callID: UUID(), toolName: .listFiles, arguments: [])
    )

    #expect(!message.containsStreamingToolCallMarkup)
  }

  @Test
  func showsAssistantPlaceholderOnlyForStreamingMessages() {
    let streamingPartialToolCall = ChatMessage(
      assistantContent: "<action name=\"list_files\">",
      deliveryStatus: .streaming
    )
    let cancelledPartialToolCall = ChatMessage(
      assistantContent: "<action name=\"list_files\">",
      deliveryStatus: .cancelled
    )

    #expect(streamingPartialToolCall.shouldShowAssistantPlaceholder)
    #expect(!cancelledPartialToolCall.shouldShowAssistantPlaceholder)
  }

  @Test
  func encodesMessagesThroughTypedPayload() throws {
    let id = UUID()
    let message = ChatMessage(id: id, assistantContent: "Done")
    let encoded =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(message)
      ) as? [String: Any]

    #expect(encoded?["id"] as? String == id.uuidString)
    #expect(encoded?["kind"] == nil)
    #expect(encoded?["content"] == nil)

    let payload = try #require(encoded?["payload"] as? [String: Any])
    #expect(payload["kind"] as? String == "assistant")
    #expect(payload["user"] == nil)
    #expect(payload["toolCall"] == nil)

    let assistantPayload = try #require(payload["assistant"] as? [String: Any])
    #expect(assistantPayload["content"] as? String == "Done")
    #expect(assistantPayload["deliveryStatus"] as? String == "complete")
  }

  @Test
  func decodesMessagesThroughTypedPayload() throws {
    let message = ChatMessage(
      toolResult: ToolResultModelMessage(
        callID: UUID(),
        toolName: .listFiles,
        preview: ToolResultPreview(text: "README.md")
      ))
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))

    #expect(decoded == message)
    #expect(decoded.kind == .toolResult)
    #expect(decoded.content.isEmpty)
    #expect(decoded.toolResult?.preview.text == "README.md")
  }
}
