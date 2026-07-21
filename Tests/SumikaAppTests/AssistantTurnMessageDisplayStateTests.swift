import SumikaCore
import Testing

@testable import SumikaApp

struct AssistantTurnMessageDisplayStateTests {
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
}
