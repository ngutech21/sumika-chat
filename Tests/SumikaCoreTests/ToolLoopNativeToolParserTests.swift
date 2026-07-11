import Foundation
import Testing

@testable import SumikaCore

struct ToolLoopNativeToolParserTests {
  @Test
  func reservedSessionIDIsRewrittenBeforeBatchAnchorIsDerived() throws {
    let reservedID = try #require(
      UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")
    )
    let secondID = try #require(
      UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")
    )
    let workspaceID = UUID()
    let sessionID = UUID()
    let registry = ToolRegistry(tools: [.readFile, .listFiles])

    let action = ToolLoopNativeToolParser.parse(
      [
        ChatRuntimeToolCall(
          id: RuntimeToolCallID.string(for: reservedID),
          name: ToolName.readFile.rawValue,
          arguments: ["path": .string("README.md")]
        ),
        ChatRuntimeToolCall(
          id: RuntimeToolCallID.string(for: secondID),
          name: ToolName.listFiles.rawValue
        ),
      ],
      policy: .nativeMLX,
      registry: registry,
      workspaceID: workspaceID,
      sessionID: sessionID,
      reservedIDs: [reservedID]
    )
    guard case .toolCalls(let outputs) = action else {
      Issue.record("Expected parsed tool calls.")
      return
    }

    #expect(outputs.count == 2)
    #expect(outputs[0].request.id != reservedID)
    #expect(outputs[1].request.id == secondID)
    #expect(Set(outputs.map(\.request.id)).count == 2)
    #expect(!outputs.map(\.request.id).contains(reservedID))

    let validator = ToolCallRequestValidator()
    let records = outputs.map { output in
      ToolCallRecord(
        request: validator.validate(output.request, registry: registry),
        evaluation: ToolPermissionEvaluation(
          decision: .requiresApproval,
          reason: "Approval required for test.",
          riskLevel: .medium
        ),
        state: .awaitingApproval(preview: nil)
      )
    }
    let turn = ChatTurn(status: .awaitingApproval, items: records.map(ChatTurnItem.tool))
    let batch = try #require(turn.toolCallBatch(containing: records[1].id))

    #expect(batch.anchorID == outputs[0].request.id)
    #expect(batch.anchorID != reservedID)
  }

  @Test
  func defaultReservationPreservesUniqueNativeID() throws {
    let nativeID = try #require(
      UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")
    )
    let action = ToolLoopNativeToolParser.parse(
      [
        ChatRuntimeToolCall(
          id: RuntimeToolCallID.string(for: nativeID),
          name: ToolName.readFile.rawValue,
          arguments: ["path": .string("README.md")]
        )
      ],
      policy: .nativeMLX,
      registry: ToolRegistry(tools: [.readFile]),
      workspaceID: UUID(),
      sessionID: UUID()
    )
    guard case .toolCalls(let outputs) = action else {
      Issue.record("Expected one parsed tool call.")
      return
    }

    #expect(outputs.map(\.request.id) == [nativeID])
  }

  @Test
  func askUserPreservesEntireBatchForExclusiveCallValidation() {
    let action = ToolLoopNativeToolParser.parse(
      [
        ChatRuntimeToolCall(
          name: ToolName.writeFile.rawValue,
          arguments: [
            "path": .string("README.md"),
            "content": .string("hello"),
          ]
        ),
        ChatRuntimeToolCall(
          name: ToolName.askUser.rawValue,
          arguments: ["question": .string("Continue?")]
        ),
      ],
      policy: ToolCallingPolicy(isEnabled: true, allowsMultipleToolCalls: false),
      registry: ToolRegistry(tools: [.writeFile, .askUser]),
      workspaceID: UUID(),
      sessionID: UUID()
    )
    guard case .toolCalls(let outputs) = action else {
      Issue.record("Expected parsed tool calls.")
      return
    }

    #expect(outputs.map(\.request.toolName) == [.writeFile, .askUser])
  }
}
