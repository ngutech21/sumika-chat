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
  func decodingInterruptedStreamingTurnsIsDeterministic() throws {
    let partialID = UUID()
    let placeholderID = UUID()
    let updatedAt = Date(timeIntervalSinceReferenceDate: 42)
    let session = ChatSession(turns: [
      ChatTurn(
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: partialID, content: "Half a thou", deliveryStatus: .streaming)
          ),
          .assistantMessage(
            AssistantTurnMessage(id: placeholderID, content: "", deliveryStatus: .streaming)
          ),
        ],
        updatedAt: updatedAt
      )
    ])
    let encoded = try JSONEncoder().encode(session)

    let first = try JSONDecoder().decode(ChatSession.self, from: encoded)
    let second = try JSONDecoder().decode(ChatSession.self, from: encoded)

    #expect(first.turns == second.turns)
    #expect(first.turns[0].updatedAt == updatedAt)
    #expect(first.turns[0].events.count == session.turns[0].events.count + 2)
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

  @Test
  func toolCallUpdatedEventDoesNotCreateRecord() {
    let record = makeToolCallRecord(status: .completed)
    let session = ChatSession(turns: [
      ChatTurn(events: [
        ChatTurnEvent(payload: .toolCallUpdated(record))
      ])
    ])

    #expect(session.toolCalls.isEmpty)
    #expect(session.toolCallRecord(id: record.id) == nil)
  }

  @Test
  func toolCallUpdatedEventUpdatesRecordedRecord() {
    let existing = makeToolCallRecord(status: .awaitingApproval)
    let updated = makeToolCallRecord(request: existing.request, status: .completed)
    let session = ChatSession(turns: [
      ChatTurn(events: [
        ChatTurnEvent(payload: .toolCallRecorded(existing)),
        ChatTurnEvent(payload: .toolCallUpdated(updated)),
      ])
    ])

    #expect(session.toolCalls == [updated])
    #expect(session.toolCallRecord(id: existing.id) == updated)
  }
}

private func makeToolCallRecord(
  request: ToolCallRequest? = nil,
  status: ToolCallStatus
) -> ToolCallRecord {
  let resolvedRequest =
    request
    ?? ToolCallRequest.validated(
      raw: RawToolCallRequest(
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .listFiles
      ),
      payload: .listFiles(ListFilesInput(path: nil))
    )
  return ToolCallRecord(
    request: resolvedRequest,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: toolCallState(status: status)
  )
}

private func toolCallState(status: ToolCallStatus) -> ToolCallState {
  switch status {
  case .pending:
    return .pending
  case .awaitingApproval:
    return .awaitingApproval(preview: nil)
  case .awaitingUserAnswer:
    return .awaitingUserAnswer
  case .running:
    return .running
  case .completed:
    return .completed(
      .listFiles(ListFilesResult(root: WorkspaceRelativePath(rawValue: "."), entries: [])))
  case .denied:
    return .denied(
      .failure(ToolFailure(toolName: .listFiles, path: nil, reason: .permissionDenied)))
  case .failed:
    return .failed(
      .failure(ToolFailure(toolName: .listFiles, path: nil, reason: .executionError("Failed."))))
  case .cancelled:
    return .cancelled
  }
}
