import Foundation
import Testing

@testable import SumikaCore

struct AssistantTurnMessageTests {
  @Test
  func assistantPlaceholderIsNotShownForEmptyCompletedMessages() {
    let message = AssistantTurnMessage(content: "")

    #expect(!message.shouldShowAssistantPlaceholder)
  }

  @Test
  func showsAssistantPlaceholderOnlyForStreamingMessages() {
    let streamingEmptyMessage = AssistantTurnMessage(
      content: "",
      deliveryStatus: .streaming
    )
    let streamingContent = AssistantTurnMessage(
      content: "Generating a normal response.",
      deliveryStatus: .streaming
    )
    let cancelledEmptyMessage = AssistantTurnMessage(
      content: "",
      deliveryStatus: .cancelled
    )

    #expect(streamingEmptyMessage.shouldShowAssistantPlaceholder)
    #expect(!streamingContent.shouldShowAssistantPlaceholder)
    #expect(!cancelledEmptyMessage.shouldShowAssistantPlaceholder)
  }

  @Test
  func assistantMessagesRoundtripWithoutPayloadWrapper() throws {
    let id = UUID()
    let message = AssistantTurnMessage(id: id, content: "Done")
    let decoded = try JSONDecoder().decode(
      AssistantTurnMessage.self,
      from: JSONEncoder().encode(message)
    )

    #expect(decoded == message)
  }
}
