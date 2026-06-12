import Foundation
import Testing

@testable import LocalCoderCore

struct ChatSessionTests {
  @Test
  func decodingResolvesInterruptedStreamingTurns() throws {
    let completeID = UUID()
    let partialID = UUID()
    let placeholderID = UUID()
    let session = ChatSession(turns: [
      ChatTurn(
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: completeID, content: "Done", deliveryStatus: .complete)
          ),
          .assistantMessage(
            AssistantTurnMessage(id: partialID, content: "Half a thou", deliveryStatus: .streaming)
          ),
          .assistantMessage(
            AssistantTurnMessage(id: placeholderID, content: "", deliveryStatus: .streaming)
          ),
        ]
      )
    ])

    let decoded = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(session)
    )

    let items = decoded.turns[0].items
    // Empty streaming placeholder dropped; partial content marked cancelled.
    #expect(items.count == 2)
    #expect(
      items.contains(
        .assistantMessage(
          AssistantTurnMessage(id: completeID, content: "Done", deliveryStatus: .complete))))
    #expect(
      items.contains(
        .assistantMessage(
          AssistantTurnMessage(id: partialID, content: "Half a thou", deliveryStatus: .cancelled))))
    #expect(!items.contains { $0.messageID == placeholderID })
  }

  @Test
  func decodingPreservesNonStreamingTurns() throws {
    let session = ChatSession(turns: [
      ChatTurn(
        status: .completed,
        items: [
          .assistantMessage(AssistantTurnMessage(content: "All good", deliveryStatus: .complete)),
          .assistantMessage(AssistantTurnMessage(content: "Stopped", deliveryStatus: .cancelled)),
        ]
      )
    ])

    let decoded = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(session)
    )

    #expect(decoded.turns == session.turns)
  }
}
