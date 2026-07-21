import Foundation
import Testing

@testable import SumikaCore

struct AssistantTurnMessageTests {
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

  @Test
  func assistantModelProjectionPolicyRoundTripsWithOverride() throws {
    let message = AssistantTurnMessage(
      id: UUID(),
      content: "Here is the full visible answer.",
      modelProjectionPolicy: .override("Short model-facing receipt.")
    )
    let decoded = try JSONDecoder().decode(
      AssistantTurnMessage.self,
      from: JSONEncoder().encode(message)
    )

    #expect(decoded == message)
    #expect(decoded.modelProjectedContent == "Short model-facing receipt.")
  }

  @Test
  func assistantModelProjectionPolicyCanExcludeAssistantFromModelContext() {
    let message = AssistantTurnMessage(
      content: "Visible only.",
      modelProjectionPolicy: .excluded
    )

    #expect(message.modelProjectedContent == nil)
  }
}
