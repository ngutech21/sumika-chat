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
    #expect(result?.toolResult.toolName == .readFile)
    #expect(result?.toolResult.preview.text == "project notes")
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
    #expect(result?.toolResult.preview.text.contains("README.md") == true)
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
    #expect(result?.toolResult.preview.status == .failed)
    #expect(result?.toolResult.preview.text == "Tool result unavailable for read_file.")
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
