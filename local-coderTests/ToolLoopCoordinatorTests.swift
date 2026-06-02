import Foundation
import Testing

@testable import local_coder

struct ToolLoopCoordinatorTests {
  @Test
  func parsesAndExecutesReadOnlyAction() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            kind: .assistant,
            content: """
              <action name="read_file">
              <path>README.md</path>
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.assistantMessageID == assistantMessageID)
    #expect(result?.toolCall.toolName == .readFile)
    #expect(result?.toolCallRecord.status == .completed)
    let toolResult = completedToolResult(from: result)
    #expect(toolResult?.toolName == .readFile)
    #expect(toolResult?.preview.text == "project notes")
  }

  @Test
  func recoversExtraneousTextAroundSingleAction() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            kind: .assistant,
            content: """
              I should inspect this.
              <action name="read_file">
              <path>README.md</path>
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName == .readFile)
    #expect(result?.toolCallRecord.status == .completed)
  }

  @Test
  func recoversSingleFencedActionBlock() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            kind: .assistant,
            content: """
              ```xml
              <action name="list_files">
              <path>.</path>
              </action>
              ```
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName == .listFiles)
    #expect(completedToolResult(from: result)?.preview.text.contains("README.md") == true)
  }

  @Test
  func returnsNoWorkWhenAssistantDidNotCallTool() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            kind: .assistant,
            content: "The answer does not need workspace context."
          )
        ]
      )
    )

    #expect(result == nil)
  }

  @Test
  func emitsFallbackResultPreviewWhenExecutorReturnsNoPreview() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator(
      toolOrchestrator: NoPreviewToolOrchestrator()
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            kind: .assistant,
            content: """
              <action name="read_file">
              <path>README.md</path>
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.toolCallRecord.resultPreview == nil)
    #expect(completedToolResult(from: result)?.preview.status == .failed)
    #expect(
      completedToolResult(from: result)?.preview.text == "Tool result unavailable for read_file.")
  }

  @Test
  func returnsAwaitingApprovalOutcomeWithoutFallbackToolResult() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator(
      toolOrchestrator: ToolOrchestrator(executorRegistry: .codingAgent)
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            kind: .assistant,
            content: """
              <action name="write_file">
              <path>movies.html</path>
              <content delimiter="LC_PAYLOAD_V1">
              <html></html>
              </content>
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName == .writeFile)
    #expect(result?.toolCallRecord.status == .awaitingApproval)
    #expect(result?.toolCallRecord.resultPreview == nil)
    #expect(result?.outcome == .awaitingApproval)
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "movies.html").path(percentEncoded: false)))
  }

  private func makeWorkspace(sessionID: CodingSession.ID) throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "project notes".write(
      to: rootURL.appending(path: "README.md"),
      atomically: true,
      encoding: .utf8
    )
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)),
      sessions: [
        CodingSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
  }

  private func completedToolResult(from result: ToolLoopResult?) -> ToolResultModelMessage? {
    guard case .completed(let toolResult, _) = result?.outcome else {
      return nil
    }
    return toolResult
  }
}

private struct NoPreviewToolOrchestrator: ToolOrchestrating {
  var toolRegistry: ToolRegistry {
    ToolExecutorRegistry.readOnly.toolRegistry
  }

  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolCallRecord {
    _ = workspace
    return ToolCallRecord(
      request: request,
      status: .failed,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .low
      )
    )
  }
}
