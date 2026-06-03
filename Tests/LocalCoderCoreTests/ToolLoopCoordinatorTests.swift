import Foundation
import Testing

@testable import LocalCoderCore

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
            assistantContent: """
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
    #expect(toolResult?.preview.text == "1: project notes")
  }

  @Test
  func repairsExactReadAliasAndExecutesReadFile() async throws {
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
            assistantContent: """
              <action name="Read">
              <path>README.md</path>
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName == .readFile)
    #expect(result?.toolCallRecord.status == .completed)
    #expect(completedToolResult(from: result)?.preview.text == "1: project notes")
  }

  @Test
  func parsesAndExecutesReadFilePaginationArguments() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try """
    one
    two
    three
    """.write(
      to: workspace.rootURL.appending(path: "README.md"),
      atomically: true,
      encoding: .utf8
    )
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
            assistantContent: """
              <action name="read_file">
              <path>README.md</path>
              <offset>2</offset>
              <limit>1</limit>
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName == .readFile)
    #expect(result?.toolCallRecord.status == .completed)
    #expect(completedToolResult(from: result)?.preview.text == "2: two")
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
            assistantContent: """
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
            assistantContent: """
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
            assistantContent: "The answer does not need workspace context."
          )
        ]
      )
    )

    #expect(result == nil)
  }

  @Test
  func unknownTaggedToolReturnsFailedObservationForFollowUp() async throws {
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
            assistantContent: """
              <action name="Deploy">
              <path>.</path>
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName.rawValue == "deploy")
    #expect(result?.toolCallRecord.status == .failed)
    #expect(completedToolResult(from: result)?.toolName.rawValue == "deploy")
    #expect(completedToolResult(from: result)?.preview.status == .failed)
    #expect(completedToolResult(from: result)?.preview.text == "Unknown tool: deploy.")
  }

  @Test
  func malformedTaggedToolCallReturnsInvalidObservationForFollowUp() async throws {
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
            assistantContent: """
              <action name="read_file">
              <path>README.md
              </action>
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName == .invalid)
    #expect(result?.toolCall.arguments.first { $0.name == "tool" }?.value == "read_file")
    #expect(result?.toolCallRecord.status == .failed)
    #expect(completedToolResult(from: result)?.toolName == .invalid)
    #expect(completedToolResult(from: result)?.preview.status == .failed)
    #expect(completedToolResult(from: result)?.preview.text.contains("invalid") == true)
  }

  @Test
  func naturalLanguageToolIntentReturnsInvalidObservationForFollowUp() async throws {
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
            assistantContent: """
              Tool call edit_file requested.
              Path:
              index.html
              Old text:
              <body>
              New text:
              <body style="background: blue">
              """
          )
        ]
      )
    )

    #expect(result?.toolCall.toolName == .invalid)
    #expect(result?.toolCall.arguments.first { $0.name == "tool" }?.value == "edit_file")
    #expect(result?.toolCallRecord.status == .failed)
    #expect(completedToolResult(from: result)?.preview.text.contains("<action>") == true)
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
            assistantContent: """
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
            assistantContent: """
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

  @Test
  func completedWriteFileActionDoesNotRequestFollowUp() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator(
      toolOrchestrator: CompletedWriteFileToolOrchestrator()
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            assistantContent: """
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
    #expect(result?.toolCallRecord.status == .completed)
    #expect(completedWithoutFollowUpToolResult(from: result)?.toolName == .writeFile)
    #expect(completedWithoutFollowUpToolResult(from: result)?.preview.status == .success)
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

  private func completedWithoutFollowUpToolResult(
    from result: ToolLoopResult?
  ) -> ToolResultModelMessage? {
    guard case .completedWithoutFollowUp(let toolResult) = result?.outcome else {
      return nil
    }
    return toolResult
  }
}

private struct NoPreviewToolOrchestrator: ToolOrchestrating {
  var toolRegistry: ToolRegistry {
    ToolExecutorRegistry.readOnly.toolRegistry
  }

  func execute(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    _ = workspace
    let request = ToolCallRequestValidator().validate(
      rawRequest,
      registry: toolRegistry
    )
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

private struct CompletedWriteFileToolOrchestrator: ToolOrchestrating {
  var toolRegistry: ToolRegistry {
    ToolExecutorRegistry.codingAgent.toolRegistry
  }

  func execute(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    _ = workspace
    let request = ToolCallRequestValidator().validate(
      rawRequest,
      registry: toolRegistry
    )
    return ToolCallRecord(
      request: request,
      status: .completed,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .high
      ),
      resultPreview: ToolResultPreview(status: .success, text: "Wrote test content.")
    )
  }
}
