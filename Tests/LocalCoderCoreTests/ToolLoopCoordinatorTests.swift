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
        turnID: UUID(),
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

    #expect(annotatedAssistantMessageID(from: result) == assistantMessageID)
    #expect(toolCall(from: result)?.toolName == .readFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(!hasRecoveredToolCallEvent(result))
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
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .readFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
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
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .readFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
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
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .readFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(hasRecoveredToolCallEvent(result))
  }

  @Test
  func recoversSingleFencedActionBlockAndRecordsDiagnosticEvent() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .listFiles)
    #expect(completedToolResult(from: result)?.preview.text.contains("README.md") == true)
    #expect(hasRecoveredToolCallEvent(result))
  }

  @Test
  func multipleTaggedActionsReturnInvalidObservationWithoutRecovery() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: UUID(),
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            assistantContent: """
              <action name="read_file">
              <path>README.md</path>
              </action>
              <action name="list_files">
              <path>.</path>
              </action>
              """
          )
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .invalid)
    #expect(toolCallRecord(from: result)?.status == .failed)
    #expect(completedToolResult(from: result)?.toolName == .invalid)
    #expect(completedToolResult(from: result)?.preview.text.contains("Only one action") == true)
    #expect(!hasRecoveredToolCallEvent(result))
  }

  @Test
  func incompleteTaggedActionReturnsInvalidObservationWithoutRecovery() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: UUID(),
        assistantMessageID: assistantMessageID,
        messages: [
          ChatMessage(
            id: assistantMessageID,
            assistantContent: """
              <action name="read_file">
              <path>README.md</path>
              """
          )
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .invalid)
    #expect(toolCallRecord(from: result)?.status == .failed)
    #expect(completedToolResult(from: result)?.toolName == .invalid)
    #expect(completedToolResult(from: result)?.preview.text.contains("closing </action>") == true)
    #expect(!hasRecoveredToolCallEvent(result))
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
        turnID: UUID(),
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
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName.rawValue == "deploy")
    #expect(toolCallRecord(from: result)?.status == .failed)
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
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .invalid)
    #expect(toolCall(from: result)?.arguments.first { $0.name == "tool" }?.value == "read_file")
    #expect(toolCallRecord(from: result)?.status == .failed)
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
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .invalid)
    #expect(toolCall(from: result)?.arguments.first { $0.name == "tool" }?.value == "edit_file")
    #expect(
      toolCallRecord(from: result)?.request.raw.rawText?.contains("Tool call edit_file") == true)
    #expect(toolCallRecord(from: result)?.status == .failed)
    #expect(completedToolResult(from: result)?.preview.text.contains("<action>") == true)
  }

  @Test
  func emitsFallbackResultPreviewWhenExecutorReturnsNoPreview() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator(
      agentToolOrchestrator: NoPreviewToolOrchestrator()
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: UUID(),
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

    #expect(toolCallRecord(from: result)?.resultPreview == nil)
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
      agentToolOrchestrator: ToolOrchestrator(executorRegistry: .codingAgent)
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .writeFile)
    #expect(toolCallRecord(from: result)?.status == .awaitingApproval)
    #expect(toolCallRecord(from: result)?.resultPreview == nil)
    #expect(result?.continuation == .awaitingApproval)
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
      agentToolOrchestrator: CompletedWriteFileToolOrchestrator()
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: UUID(),
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

    #expect(toolCall(from: result)?.toolName == .writeFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
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

  private func toolCall(from step: ChatWorkflowStep?) -> ToolCallModelMessage? {
    for event in step?.events ?? [] {
      guard
        case .assistantMessageAnnotatedAsToolCall(_, let toolCall) = event
      else {
        continue
      }
      return toolCall
    }
    return nil
  }

  private func annotatedAssistantMessageID(from step: ChatWorkflowStep?) -> ChatMessage.ID? {
    for event in step?.events ?? [] {
      guard
        case .assistantMessageAnnotatedAsToolCall(let assistantMessageID, _) = event
      else {
        continue
      }
      return assistantMessageID
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

  private func hasRecoveredToolCallEvent(_ step: ChatWorkflowStep?) -> Bool {
    toolCallRecord(from: step)?.events.contains { event in
      event.actor == .system
        && event.kind == .requested
        && event.message.contains("Recovered one complete tagged <action> block")
    } == true
  }

  private func completedToolResult(from step: ChatWorkflowStep?) -> ToolResultModelMessage? {
    guard case .resumeGeneration = step?.continuation else {
      return nil
    }
    return toolResult(from: step)
  }

  private func completedWithoutFollowUpToolResult(
    from step: ChatWorkflowStep?
  ) -> ToolResultModelMessage? {
    guard case .stopTurn = step?.continuation else {
      return nil
    }
    return toolResult(from: step)
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
