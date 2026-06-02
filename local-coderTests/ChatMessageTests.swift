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
      let message = ChatMessage(kind: .assistant, content: content)

      #expect(message.containsStreamingToolCallMarkup)
    }
  }

  @Test
  func ignoresPlainAssistantContentWhenDetectingStreamingToolCallMarkup() {
    let message = ChatMessage(kind: .assistant, content: "Here are the files:")

    #expect(!message.containsStreamingToolCallMarkup)
  }

  @Test
  func ignoresToolCallMessagesWhenDetectingStreamingToolCallMarkup() {
    let message = ChatMessage(
      kind: .toolCall,
      content: "",
      toolCall: ToolCallModelMessage(callID: UUID(), toolName: .listFiles, arguments: [])
    )

    #expect(!message.containsStreamingToolCallMarkup)
  }

  @Test
  func showsAssistantPlaceholderOnlyForStreamingMessages() {
    let streamingPartialToolCall = ChatMessage(
      kind: .assistant,
      content: "<action name=\"list_files\">",
      deliveryStatus: .streaming
    )
    let cancelledPartialToolCall = ChatMessage(
      kind: .assistant,
      content: "<action name=\"list_files\">",
      deliveryStatus: .cancelled
    )

    #expect(streamingPartialToolCall.shouldShowAssistantPlaceholder)
    #expect(!cancelledPartialToolCall.shouldShowAssistantPlaceholder)
  }
}
