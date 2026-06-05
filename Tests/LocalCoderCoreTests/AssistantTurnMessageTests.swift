import Foundation
import Testing

@testable import LocalCoderCore

struct AssistantTurnMessageTests {
  @Test
  func detectsStreamingToolCallMarkupPrefixes() {
    let partialMessages = [
      "<",
      "<act",
      "<action",
      "<action name=\"list_files\">",
    ]

    for content in partialMessages {
      let message = AssistantTurnMessage(content: content)

      #expect(message.containsStreamingToolCallMarkup)
    }
  }

  @Test
  func ignoresPlainAssistantContentWhenDetectingStreamingToolCallMarkup() {
    let message = AssistantTurnMessage(content: "Here are the files:")

    #expect(!message.containsStreamingToolCallMarkup)
  }

  @Test
  func assistantPlaceholderIsNotShownForEmptyCompletedMessages() {
    let message = AssistantTurnMessage(content: "")

    #expect(!message.shouldShowAssistantPlaceholder)
  }

  @Test
  func showsAssistantPlaceholderOnlyForStreamingMessages() {
    let streamingPartialToolCall = AssistantTurnMessage(
      content: "<action name=\"list_files\">",
      deliveryStatus: .streaming
    )
    let cancelledPartialToolCall = AssistantTurnMessage(
      content: "<action name=\"list_files\">",
      deliveryStatus: .cancelled
    )

    #expect(streamingPartialToolCall.shouldShowAssistantPlaceholder)
    #expect(!cancelledPartialToolCall.shouldShowAssistantPlaceholder)
  }

  @Test
  func decodesLegacyGenerationMetricsWithoutDuration() throws {
    let json = Data(
      """
      {
        "generatedTokenCount": 12,
        "tokensPerSecond": 4.5
      }
      """.utf8)

    let metrics = try JSONDecoder().decode(ChatGenerationMetrics.self, from: json)

    #expect(metrics.generatedTokenCount == 12)
    #expect(metrics.tokensPerSecond == 4.5)
    #expect(metrics.durationMs == nil)
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
