import Foundation
import Testing

@testable import SumikaCore

struct ToolCallBatchTests {
  @Test
  func batchUsesCanonicalRecordOrderAndTreatsThinkingAsTransparent() throws {
    let first = makeBatchRecord(state: .awaitingApproval(preview: nil))
    let second = makeBatchRecord(state: .pending)
    let separate = makeBatchRecord(state: .awaitingUserAnswer)
    let turn = ChatTurn(
      status: .awaitingApproval,
      items: [
        .assistantMessage(AssistantTurnMessage(content: "Calling tools.")),
        .tool(first),
        .assistantThinking(AssistantThinkingMessage(content: "Continuing the same response.")),
        .tool(second),
        .assistantMessage(AssistantTurnMessage(content: "A later response.")),
        .tool(separate),
      ]
    )

    let batch = try #require(turn.toolCallBatch(containing: second.id))
    let separateBatch = try #require(turn.toolCallBatch(containing: separate.id))

    #expect(batch.anchorID == first.id)
    #expect(batch.records.map(\.id) == [first.id, second.id])
    #expect(batch.pendingApprovalRecords.map(\.id) == [first.id])
    #expect(!batch.hasPendingUserAnswer)
    #expect(!batch.isModelReady)
    #expect(separateBatch.anchorID == separate.id)
    #expect(separateBatch.records.map(\.id) == [separate.id])
    #expect(separateBatch.hasPendingUserAnswer)
    #expect(turn.toolCallBatches.map(\.anchorID) == [first.id, separate.id])
    #expect(turn.toolCallBatchCount == 2)
    #expect(turn.toolCallBatch(containing: UUID()) == nil)
  }

  @Test
  func userMessageSeparatesAdjacentToolBatches() throws {
    let beforeUserMessage = makeBatchRecord(state: .pending)
    let afterUserMessage = makeBatchRecord(state: .pending)
    let turn = ChatTurn(
      status: .running,
      items: [
        .tool(beforeUserMessage),
        .userMessage(UserTurnMessage(content: "New request")),
        .tool(afterUserMessage),
      ]
    )

    #expect(
      try #require(turn.toolCallBatch(containing: beforeUserMessage.id)).records.map(\.id)
        == [beforeUserMessage.id]
    )
    #expect(
      try #require(turn.toolCallBatch(containing: afterUserMessage.id)).records.map(\.id)
        == [afterUserMessage.id]
    )
  }

  @Test
  func batchReconstructsAfterRoundTripAndIgnoresTurnStatusChanges() throws {
    let denied = makeBatchRecord(
      state: .denied(
        .failure(
          ToolFailure(toolName: .readFile, path: nil, reason: .userDenied)
        ))
    )
    let completed = makeBatchRecord(
      state: .completed(
        .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "contents")
          ))
      )
    )
    let original = ChatTurn(
      status: .awaitingApproval,
      items: [
        .tool(denied),
        .assistantThinking(AssistantThinkingMessage(content: "Reasoning row")),
        .tool(completed),
      ]
    )

    let data = try JSONEncoder().encode(original)
    var decoded = try JSONDecoder().decode(ChatTurn.self, from: data)
    let restored = try #require(decoded.toolCallBatch(containing: completed.id))

    #expect(restored.anchorID == denied.id)
    #expect(restored.records.map(\.id) == [denied.id, completed.id])
    #expect(restored.pendingApprovalRecords.isEmpty)
    #expect(!restored.hasPendingUserAnswer)
    #expect(restored.isModelReady)
    #expect(decoded.toolCallBatchCount == 1)

    decoded.updateStatus(.completed)
    let afterStatusChange = try #require(decoded.toolCallBatch(containing: denied.id))
    #expect(afterStatusChange.anchorID == denied.id)
    #expect(afterStatusChange.records.map(\.id) == [denied.id, completed.id])
  }
}

private func makeBatchRecord(state: ToolCallState) -> ToolCallRecord {
  let raw = RawToolCallRequest(
    workspaceID: UUID(),
    sessionID: UUID(),
    toolName: .readFile,
    arguments: ["path": .string("README.md")]
  )
  return ToolCallRecord(
    request: .validated(
      raw: raw,
      payload: .readFile(ReadFileInput(path: "README.md"))
    ),
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: state
  )
}
