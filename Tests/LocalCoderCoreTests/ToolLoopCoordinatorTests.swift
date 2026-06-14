import Foundation
import Testing

@testable import LocalCoderCore

@Suite(.serialized)
struct ToolLoopCoordinatorTests {
  @Test
  func nativeReadFileExecutesAndRequestsFollowUp() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        assistantMessageID: assistantMessageID,
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        ]
      )
    )

    #expect(annotatedNativeAssistantMessageID(from: result) == assistantMessageID)
    #expect(toolCall(from: result)?.toolName == .readFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(completedToolResult(from: result)?.preview.text == "1: project notes")
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func nativeToolNameRepairKeepsOriginalName() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "READ-FILE", arguments: ["path": .string("README.md")])
        ]
      )
    )

    let record = try #require(toolCallRecord(from: result))
    #expect(record.request.toolName == .readFile)
    #expect(record.request.raw.originalToolName == "READ-FILE")
    #expect(record.status == .completed)
    #expect(
      record.events.contains {
        $0.message == "Tool name normalized: READ-FILE -> read_file."
      })
  }

  @Test
  func nativeUnknownToolNameFailsWithoutExecution() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "run", arguments: ["command": .string("date")])
        ]
      )
    )

    let record = try #require(toolCallRecord(from: result))
    #expect(record.request.toolName == ToolName(rawValue: "run"))
    #expect(record.request.raw.originalToolName == "run")
    #expect(record.status == .failed)
    #expect(completedToolResult(from: result)?.preview.text.contains("Unknown tool: run.") == true)
  }

  @Test
  func nativeMultipleIndependentToolCallsExecuteTogether() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")]),
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")]),
        ]
      )
    )

    #expect(toolCallRecords(from: result).map(\.request.toolName) == [.readFile, .listFiles])
    #expect(toolResults(from: result).map(\.toolName) == [.readFile, .listFiles])
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func nativeMultipleToolCallBoundaryRedactsSecondEditFilePayload() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let oldText = "project notes"
    let newText = "updated project notes"

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")]),
          ChatRuntimeToolCall(
            name: "edit_file",
            arguments: [
              "path": .string("README.md"),
              "old_text": .string(oldText),
              "new_text": .string(newText),
            ]
          ),
        ]
      )
    )

    let boundary = try #require(nativeAssistantBoundary(from: result))
    #expect(boundary.contains("<|tool_call>call:read_file{path:<|\"|>README.md<|\"|>}<tool_call|>"))
    #expect(boundary.contains("Tool call edit_file requested."))
    #expect(boundary.contains("Path:\nREADME.md"))
    #expect(boundary.contains("Payload omitted from history."))
    #expect(!boundary.contains("old_text:"))
    #expect(!boundary.contains("new_text:"))
    #expect(!boundary.contains(newText))
    #expect(annotatedNativeToolCalls(from: result).map(\.toolName) == [.readFile, .editFile])
    #expect(toolCallRecords(from: result).map(\.request.toolName) == [.readFile, .editFile])
    #expect(result?.continuation == .awaitingApproval)
  }

  @Test
  func noNativeToolCallsDoesNothing() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(workspace: workspace, sessionID: sessionID, nativeToolCalls: [])
    )

    #expect(result == nil)
  }

  @Test
  func askUserPausesWithoutToolResult() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "ask_user",
            arguments: [
              "question": .string("Which fix?"),
              "option1": .string("Minimal"),
              "option2": .string("Broad"),
            ]
          )
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .askUser)
    #expect(toolCallRecord(from: result)?.status == .awaitingUserAnswer)
    #expect(result?.continuation == .awaitingUserAnswer)
    #expect(toolResults(from: result).isEmpty)
  }

  @Test
  func showFileDisplaysDirectlyWithoutModelFollowUp() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "show_file", arguments: ["path": .string("README.md")])
        ]
      )
    )

    #expect(result?.continuation == .stopTurn)
    #expect(completedToolResult(from: result)?.toolName == .showFile)
    let assistant = directAssistantMessage(from: result)
    #expect(assistant?.content.contains("Here is `README.md`:") == true)
    #expect(assistant?.content.contains("1: project notes") == true)
    #expect(
      assistant?.modelContextContent
        == "Displayed show_file result for README.md directly to the user.")
  }

  @Test
  func workspaceDiffDisplaysDirectlyWithoutModelFollowUp() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let coordinator = ToolLoopCoordinator(
      agentToolOrchestrator: WorkspaceDiffToolOrchestrator(
        content: ToolTextOutput(text: "diff --git a/README.md b/README.md")
      ))

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "show git diff",
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "workspace_diff", arguments: [:])
        ]
      )
    )

    #expect(result?.continuation == .stopTurn)
    #expect(completedToolResult(from: result)?.toolName == .workspaceDiff)
    let assistant = directAssistantMessage(from: result)
    #expect(assistant?.content.contains("Workspace changes:") == true)
    #expect(assistant?.content.contains("    diff --git a/README.md b/README.md") == true)
    #expect(
      assistant?.modelContextContent
        == "Displayed workspace_diff result directly to the user.")
  }

  @Test
  func writeFileAwaitsApprovalWithoutFallbackToolResult() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("notes.txt"),
              "content": .string("new notes\n"),
            ]
          )
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .writeFile)
    #expect(toolCallRecord(from: result)?.status == .awaitingApproval)
    #expect(result?.continuation == .awaitingApproval)
    #expect(toolResults(from: result).isEmpty)
  }

  @Test
  func todoWriteUpdatesTodoStateAndKeepsObservationMinimal() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "todo_write",
            arguments: ["items": .string("Inspect files:true\nRun tests:false")]
          )
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .todoWrite)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(completedToolResult(from: result)?.preview.text == "Plan updated.")
    #expect(todoStateChanged(from: result)?.items.map(\.content) == ["Inspect files", "Run tests"])
  }

  private func request(
    workspace: Workspace,
    sessionID: ChatSession.ID,
    assistantMessageID: UUID = UUID(),
    userContent: String? = nil,
    nativeToolCalls: [ChatRuntimeToolCall]
  ) -> ToolLoopRequest {
    var items: [ChatTurnItem] = []
    if let userContent {
      items.append(.userMessage(UserTurnMessage(content: userContent)))
    }
    items.append(.assistantMessage(AssistantTurnMessage(id: assistantMessageID, content: "")))

    return ToolLoopRequest(
      workspace: workspace,
      sessionID: sessionID,
      turnID: UUID(),
      assistantMessageID: assistantMessageID,
      items: items,
      interactionMode: .agent,
      toolCallingPolicy: .nativeGemma4,
      nativeToolCalls: nativeToolCalls
    )
  }

  private func makeWorkspace(sessionID: ChatSession.ID) throws -> Workspace {
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
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
  }

  private func annotatedNativeAssistantMessageID(from step: ChatWorkflowStep?) -> UUID? {
    for event in step?.events ?? [] {
      guard case .assistantAnnotatedAsNativeToolCall(let assistantMessageID, _) = event
      else {
        continue
      }
      return assistantMessageID
    }
    return nil
  }

  private func toolCall(from step: ChatWorkflowStep?) -> ToolCallModelMessage? {
    for event in step?.events ?? [] {
      guard case .assistantAnnotatedAsNativeToolCall(_, let toolCall) = event else {
        continue
      }
      return toolCall
    }
    return nil
  }

  private func annotatedNativeToolCalls(from step: ChatWorkflowStep?) -> [ToolCallModelMessage] {
    (step?.events ?? []).compactMap { event in
      guard case .assistantAnnotatedAsNativeToolCall(_, let toolCall) = event else {
        return nil
      }
      return toolCall
    }
  }

  private func nativeAssistantBoundary(from step: ChatWorkflowStep?) -> String? {
    for event in step?.events ?? [] {
      guard case .nativeAssistantBoundaryAppended(let content, _, _) = event else {
        continue
      }
      return content
    }
    return nil
  }

  private func toolCallRecord(from step: ChatWorkflowStep?) -> ToolCallRecord? {
    toolCallRecords(from: step).first
  }

  private func toolCallRecords(from step: ChatWorkflowStep?) -> [ToolCallRecord] {
    (step?.events ?? []).compactMap { event in
      guard case .toolCallAppended(let record, _) = event else {
        return nil
      }
      return record
    }
  }

  private func completedToolResult(from step: ChatWorkflowStep?) -> ToolResultModelMessage? {
    toolResults(from: step).first
  }

  private func toolResults(from step: ChatWorkflowStep?) -> [ToolResultModelMessage] {
    (step?.events ?? []).compactMap { event in
      guard case .toolResultAppended(let toolResult, _) = event else {
        return nil
      }
      return toolResult
    }
  }

  private func resumePromptMode(from step: ChatWorkflowStep?) -> ToolPromptMode? {
    guard case .resumeGeneration(_, let promptMode) = step?.continuation else {
      return nil
    }
    return promptMode
  }

  private func directAssistantMessage(from step: ChatWorkflowStep?) -> (
    content: String, modelContextContent: String
  )? {
    for event in step?.events ?? [] {
      guard case .assistantMessageAppended(let content, let modelContextContent, _, _) = event
      else {
        continue
      }
      return (content, modelContextContent)
    }
    return nil
  }

  private func todoStateChanged(from step: ChatWorkflowStep?) -> TodoState? {
    for event in step?.events ?? [] {
      guard case .todoStateChanged(let todoState) = event else {
        continue
      }
      return todoState
    }
    return nil
  }
}

private struct WorkspaceDiffToolOrchestrator: ToolOrchestrating {
  let content: ToolTextOutput

  var toolRegistry: ToolRegistry {
    ToolRegistry(tools: [.workspaceDiff])
  }

  func execute(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    let request = ToolCallRequest.validated(
      raw: rawRequest,
      payload: .workspaceDiff(WorkspaceDiffInput())
    )
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .low
      ),
      state: .completed(.workspaceDiff(.success(path: nil, content: content)))
    )
  }
}
