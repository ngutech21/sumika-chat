import Foundation
import Testing

@testable import LocalCoderCore

struct FinalModeActionDetectorTests {
  @Test
  func returnsNilWhenFinalMessageContainsNoToolAttempt() async throws {
    let assistantMessageID = UUID()
    let request = makeRequest(
      assistantMessageID: assistantMessageID,
      messages: [
        ChatMessage(id: assistantMessageID, assistantContent: "Done.")
      ],
      reason: .finalMode
    )

    let step = try await FinalModeActionDetector().detect(request)

    #expect(step == nil)
  }

  @Test
  func recordsTaggedActionAsFinalModeFailureWithoutWorkspaceExecution() async throws {
    let assistantMessageID = UUID()
    let request = makeRequest(
      assistantMessageID: assistantMessageID,
      messages: [
        ChatMessage(
          id: assistantMessageID,
          assistantContent: """
            <action name="read_file">
            <path>README.md</path>
            </action>
            """
        )
      ],
      reason: .finalMode
    )

    let step = try await FinalModeActionDetector().detect(request)

    #expect(toolCall(from: step)?.toolName == .readFile)
    #expect(toolCallRecord(from: step)?.status == .failed)
    guard case .failure(let failure) = toolResult(from: step)?.payload else {
      Issue.record("Expected final-mode action to be recorded as a structured failure.")
      return
    }
    #expect(failure.reason == .finalModeToolAttempt(requestedTool: .readFile))
  }

  @Test
  func recordsNonTaggedActionAsBudgetFailureWithInferredToolName() async throws {
    let assistantMessageID = UUID()
    let request = makeRequest(
      assistantMessageID: assistantMessageID,
      messages: [
        ChatMessage(
          id: assistantMessageID,
          assistantContent: """
            Tool call edit_file requested.
            Path:
            README.md
            Old text:
            before
            New text:
            after
            """
        )
      ],
      reason: .toolBudgetExceeded(iterationLimit: 6)
    )

    let step = try await FinalModeActionDetector().detect(request)

    #expect(toolCall(from: step)?.toolName == .invalid)
    #expect(toolCallRecord(from: step)?.status == .failed)
    guard case .failure(let failure) = toolResult(from: step)?.payload else {
      Issue.record("Expected over-budget action to be recorded as a structured failure.")
      return
    }
    #expect(failure.reason == .toolBudgetExceeded(requestedTool: .editFile, iterationLimit: 6))
  }

  private func makeRequest(
    assistantMessageID: ChatMessage.ID,
    messages: [ChatMessage],
    reason: FinalModeActionDetectionReason
  ) -> FinalModeActionDetectionRequest {
    FinalModeActionDetectionRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      turnID: UUID(),
      assistantMessageID: assistantMessageID,
      messages: messages,
      interactionMode: .agent,
      reason: reason
    )
  }

  private func toolCall(from step: ChatWorkflowStep?) -> ToolCallModelMessage? {
    for event in step?.events ?? [] {
      guard case .assistantMessageAnnotatedAsToolCall(_, let toolCall) = event else {
        continue
      }
      return toolCall
    }
    return nil
  }

  private func toolCallRecord(from step: ChatWorkflowStep?) -> ToolCallRecord? {
    for event in step?.events ?? [] {
      guard case .toolCallAppended(let record, _) = event else {
        continue
      }
      return record
    }
    return nil
  }

  private func toolResult(from step: ChatWorkflowStep?) -> ToolResultModelMessage? {
    for event in step?.events ?? [] {
      guard case .toolResultAppended(let toolResult, _, _) = event else {
        continue
      }
      return toolResult
    }
    return nil
  }
}
