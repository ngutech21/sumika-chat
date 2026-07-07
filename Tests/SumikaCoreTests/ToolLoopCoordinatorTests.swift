import Foundation
import Testing

@testable import SumikaCore

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
  func nativeRuntimeToolCallIDSeedsRawRequestID() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let callID = UUID()

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            id: RuntimeToolCallID.string(for: callID),
            name: "read_file",
            arguments: ["path": .string("README.md")]
          )
        ]
      )
    )

    #expect(toolCallRecord(from: result)?.id == callID)
    #expect(completedToolResult(from: result)?.callID == callID)
    #expect(annotatedNativeToolCalls(from: result).first?.callID == callID)
  }

  @Test
  func duplicateNativeRuntimeToolCallIDsDoNotCreateDuplicateRequests() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let callID = UUID()

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            id: RuntimeToolCallID.string(for: callID),
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ),
          ChatRuntimeToolCall(
            id: RuntimeToolCallID.string(for: callID),
            name: "list_files",
            arguments: ["path": .string(".")]
          ),
        ]
      )
    )

    let ids = toolCallRecords(from: result).map(\.id)
    #expect(ids.count == 2)
    #expect(Set(ids).count == 2)
    #expect(ids.first == callID)
  }

  @Test
  func duplicateReadFileInSameTurnAppendsDuplicateRecordWithoutExecutingAgain() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let previousRequest = RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: sessionID,
      toolName: .readFile,
      arguments: ["path": .string("README.md")]
    )
    let previousRecord = ToolCallRecord(
      request: .validated(
        raw: previousRequest,
        payload: .readFile(ReadFileInput(path: "README.md"))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading files inside the workspace is allowed.",
        riskLevel: .low
      ),
      state: .completed(
        .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "1: project notes")
          )))
    )
    let orchestrator = CountingToolOrchestrator()
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect README",
        additionalItems: [.tool(previousRecord)],
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        ]
      )
    )

    #expect(await orchestrator.executionCount == 0)
    let record = try #require(toolCallRecord(from: result))
    guard let payload = record.resultPayload,
      case .duplicateToolCall(let duplicate) = payload
    else {
      Issue.record("Expected duplicate tool call payload.")
      return
    }
    #expect(record.id != previousRecord.id)
    #expect(duplicate.previousCallID == previousRecord.id)
    #expect(duplicate.message.contains(RuntimeToolCallID.string(for: previousRecord.id)))
    #expect(completedToolResult(from: result)?.callID == record.id)
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func repeatedDuplicateReadFileReferencesOriginalCompletedRecord() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let previousRequest = RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: sessionID,
      toolName: .readFile,
      arguments: ["path": .string("README.md")]
    )
    let previousRecord = ToolCallRecord(
      request: .validated(
        raw: previousRequest,
        payload: .readFile(ReadFileInput(path: "README.md"))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading files inside the workspace is allowed.",
        riskLevel: .low
      ),
      state: .completed(
        .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "1: project notes")
          )))
    )
    let duplicateRequest = RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: sessionID,
      toolName: .readFile,
      arguments: ["path": .string("README.md")]
    )
    let previousDuplicateRecord = ToolCallRecord(
      request: .validated(
        raw: duplicateRequest,
        payload: .readFile(ReadFileInput(path: "README.md"))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Identical read_file already completed in this turn.",
        riskLevel: .low,
        workspaceRelativePaths: [WorkspaceRelativePath(rawValue: "README.md")]
      ),
      state: .completed(
        .duplicateToolCall(
          DuplicateToolCallResult(
            previousCallID: previousRecord.id,
            message: "Duplicate of \(RuntimeToolCallID.string(for: previousRecord.id)).",
            affectedPaths: [WorkspaceRelativePath(rawValue: "README.md")]
          )))
    )
    let orchestrator = CountingToolOrchestrator()
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect README",
        additionalItems: [.tool(previousRecord), .tool(previousDuplicateRecord)],
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        ]
      )
    )

    #expect(await orchestrator.executionCount == 0)
    let record = try #require(toolCallRecord(from: result))
    guard case .duplicateToolCall(let duplicate)? = record.resultPayload else {
      Issue.record("Expected repeated read_file to be a duplicate observation.")
      return
    }
    #expect(duplicate.previousCallID == previousRecord.id)
    #expect(duplicate.previousCallID != previousDuplicateRecord.id)
    #expect(duplicate.message.contains(RuntimeToolCallID.string(for: previousRecord.id)))
  }

  @Test
  func duplicateReadFileInSameNativeBatchExecutesOnlyOnce() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let orchestrator = CountingToolOrchestrator()
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect README",
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")]),
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")]),
        ]
      )
    )

    #expect(await orchestrator.executionCount == 1)
    let records = toolCallRecords(from: result)
    #expect(records.count == 2)
    guard case .readFile(.success) = records.first?.resultPayload else {
      Issue.record("Expected first read_file to execute normally.")
      return
    }
    guard let payload = records.last?.resultPayload,
      case .duplicateToolCall(let duplicate) = payload
    else {
      Issue.record("Expected second read_file to be a duplicate observation.")
      return
    }
    #expect(duplicate.previousCallID == records.first?.id)
    #expect(toolResults(from: result).map(\.callID) == records.map(\.id))
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func readFileWithDifferentRangeExecutesAgain() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let orchestrator = CountingToolOrchestrator()
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect README",
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md"), "limit": .number(5)]
          ),
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md"), "limit": .number(10)]
          ),
        ]
      )
    )

    #expect(await orchestrator.executionCount == 2)
    let records = toolCallRecords(from: result)
    #expect(records.count == 2)
    #expect(
      records.allSatisfy {
        if let payload = $0.resultPayload, case .readFile(.success) = payload {
          return true
        }
        return false
      })
  }

  @Test
  func duplicateListFilesInSameTurnAppendsDuplicateRecordWithoutExecutingAgain() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let previousRequest = RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: sessionID,
      toolName: .listFiles,
      arguments: ["path": .string(".")]
    )
    let previousRecord = ToolCallRecord(
      request: .validated(
        raw: previousRequest,
        payload: .listFiles(ListFilesInput(path: "."))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Listing files inside the workspace is allowed.",
        riskLevel: .low
      ),
      state: .completed(
        .listFiles(
          ListFilesResult(
            root: WorkspaceRelativePath(rawValue: "."),
            entries: [
              WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "README.md"), kind: .file)
            ]
          )))
    )
    let orchestrator = CountingToolOrchestrator(tools: [.listFiles])
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect project",
        additionalItems: [.tool(previousRecord)],
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        ]
      )
    )

    #expect(await orchestrator.executionCount == 0)
    let record = try #require(toolCallRecord(from: result))
    guard let payload = record.resultPayload,
      case .duplicateToolCall(let duplicate) = payload
    else {
      Issue.record("Expected duplicate tool call payload.")
      return
    }
    #expect(duplicate.previousCallID == previousRecord.id)
    #expect(duplicate.affectedPaths == [WorkspaceRelativePath(rawValue: ".")])
    #expect(completedToolResult(from: result)?.callID == record.id)
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func duplicateListFilesInSameNativeBatchReplaysPreviousObservationToModel() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let orchestrator = CountingToolOrchestrator(tools: [.listFiles])
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect project",
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")]),
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")]),
        ]
      )
    )

    #expect(await orchestrator.executionCount == 1)
    let records = toolCallRecords(from: result)
    #expect(records.count == 2)
    let originalRecord = try #require(records.first)
    let duplicateRecord = try #require(records.dropFirst().first)
    guard case .listFiles = originalRecord.resultPayload else {
      Issue.record("Expected first list_files to execute normally.")
      return
    }
    guard case .duplicateToolCall(let duplicate)? = duplicateRecord.resultPayload else {
      Issue.record("Expected second list_files to be a duplicate observation.")
      return
    }

    #expect(duplicate.previousCallID == originalRecord.id)
    #expect(
      duplicate.replayedObservation?.blocks == [
        .fileList(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "README.md"), kind: .file)
          ],
          totalCount: 1,
          truncated: false,
        )
      ])

    let duplicateToolResult = try #require(toolResults(from: result).last)
    let entry = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: duplicateToolResult,
      request: duplicateRecord.request,
      originalUserRequest: nil
    )
    guard case .toolObservation(let context) = entry.body else {
      Issue.record("Expected duplicate result to render as a model-facing tool observation.")
      return
    }
    #expect(context.callID == duplicateRecord.id)
    #expect(context.content.contains("README.md"))
    #expect(context.content.contains("not re-executed"))
    #expect(context.content.contains("call read_file"))
    #expect(context.content.contains("Do not call list_files again"))
  }

  @Test
  func duplicateListFilesInSameNativeBatchExecutesOnceAndBlocksSecondDuplicate() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let orchestrator = CountingToolOrchestrator(tools: [.listFiles])
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect project",
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")]),
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")]),
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")]),
        ]
      )
    )

    #expect(await orchestrator.executionCount == 1)
    let records = toolCallRecords(from: result)
    #expect(records.count == 3)
    guard case .listFiles = records.first?.resultPayload else {
      Issue.record("Expected first list_files to execute normally.")
      return
    }
    let originalID = try #require(records.first?.id)
    let duplicates = records.dropFirst().compactMap { record -> DuplicateToolCallResult? in
      guard case .duplicateToolCall(let duplicate)? = record.resultPayload else {
        return nil
      }
      return duplicate
    }
    #expect(duplicates.count == 2)
    #expect(duplicates.map(\.previousCallID) == [originalID, originalID])
    // 1st duplicate replays content; the 2nd consecutive duplicate is blocked and forces
    // the tools-stripped final generation.
    #expect(duplicates.map(\.blocked) == [false, true])
    #expect(duplicates.first?.replayedObservation != nil)
    #expect(duplicates.last?.replayedObservation == nil)
    #expect(toolResults(from: result).map(\.callID) == records.map(\.id))
    #expect(resumePromptMode(from: result) == .afterToolResultFinal)
  }

  @Test
  func listFilesWithDifferentPathExecutesAgain() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let orchestrator = CountingToolOrchestrator(tools: [.listFiles])
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "inspect project",
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")]),
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")]),
        ]
      )
    )

    #expect(await orchestrator.executionCount == 2)
    let roots = toolCallRecords(from: result).compactMap { record -> WorkspaceRelativePath? in
      guard let payload = record.resultPayload,
        case .listFiles(let result) = payload
      else {
        return nil
      }
      return result.root
    }
    #expect(
      roots == [
        WorkspaceRelativePath(rawValue: "."),
        WorkspaceRelativePath(rawValue: "Sources"),
      ])
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func identicalRunCommandCallsExecuteWithoutDuplicateReplay() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let orchestrator = CountingToolOrchestrator(tools: [.runCommand])
    let coordinator = ToolLoopCoordinator(agentToolOrchestrator: orchestrator)

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        userContent: "check git status repeatedly",
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: ["command": .string("git status")]
          ),
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: ["command": .string("git status")]
          ),
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: ["command": .string("git status")]
          ),
        ]
      )
    )

    #expect(await orchestrator.executionCount == 3)
    let records = toolCallRecords(from: result)
    #expect(records.count == 3)
    #expect(
      records.allSatisfy { record in
        if case .runCommand = record.resultPayload {
          return true
        }
        return false
      })
    #expect(
      records.allSatisfy { record in
        if case .duplicateToolCall = record.resultPayload {
          return false
        }
        return true
      })
    #expect(toolResults(from: result).map(\.callID) == records.map(\.id))
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
  func chatWebProfileExecutesWebSearchOnly() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let coordinator = ToolLoopCoordinator(
      chatWebToolOrchestrator: ToolOrchestrator(
        executorRegistry: .chatWeb,
        webSearcher: FakeSearchService(),
        webAccessSettingsProvider: {
          WebAccessSettings(policy: .allow, provider: .duckDuckGo)
        }
      ))

    let result = try await coordinator.run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        interactionMode: .chat,
        toolProfile: .chatWeb,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "web_search",
            arguments: ["query": .string("Swift concurrency")]
          )
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .webSearch)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(resumePromptMode(from: result) == .afterChatWebToolResultCanContinue)
  }

  @Test
  func chatWebProfileDoesNotExposeWorkspaceTools() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)

    let result = try await ToolLoopCoordinator().run(
      request(
        workspace: workspace,
        sessionID: sessionID,
        interactionMode: .chat,
        toolProfile: .chatWeb,
        nativeToolCalls: [
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        ]
      )
    )

    let record = try #require(toolCallRecord(from: result))
    #expect(record.request.toolName == .readFile)
    #expect(record.status == .failed)
    #expect(
      completedToolResult(from: result)?.preview.text.contains(
        "Tool is not available in the active registry: read_file."
      ) == true)
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

    let boundary = annotatedNativeToolCalls(from: result)
      .map(\.modelContextContent)
      .joined(separator: "\n")
    #expect(boundary.contains("Tool call read_file requested."))
    #expect(boundary.contains("path: README.md"))
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
      assistant?.modelProjectionPolicy
        == .override("Displayed show_file result for README.md directly to the user."))
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
      assistant?.modelProjectionPolicy
        == .override("Displayed workspace_diff result directly to the user."))
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
            arguments: [
              "item1": .string("Inspect files"),
              "done1": .bool(true),
              "item2": .string("Run tests"),
              "done2": .bool(false),
            ]
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
    additionalItems: [ChatTurnItem] = [],
    interactionMode: WorkspaceInteractionMode = .agent,
    toolProfile: ToolExecutionProfile = .agent,
    nativeToolCalls: [ChatRuntimeToolCall]
  ) -> ToolLoopRequest {
    var items: [ChatTurnItem] = []
    if let userContent {
      items.append(.userMessage(UserTurnMessage(content: userContent)))
    }
    items.append(contentsOf: additionalItems)
    items.append(.assistantMessage(AssistantTurnMessage(id: assistantMessageID, content: "")))
    let followUpPromptMode: ToolPromptMode
    switch toolProfile {
    case .disabled:
      followUpPromptMode = .disabled
    case .chatWeb:
      followUpPromptMode = .afterChatWebToolResultCanContinue
    case .agent:
      followUpPromptMode = .afterToolResultCanContinue
    }

    return ToolLoopRequest(
      workspace: workspace,
      sessionID: sessionID,
      turnID: UUID(),
      assistantMessageID: assistantMessageID,
      items: items,
      interactionMode: interactionMode,
      toolProfile: toolProfile,
      followUpPromptMode: followUpPromptMode,
      toolCallingPolicy: .nativeMLX,
      nativeToolCalls: nativeToolCalls
    )
  }

  private func makeWorkspace(sessionID: ChatSession.ID) throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-tests-\(UUID().uuidString)",
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
          modeSettings: testModeSettings(
            systemPrompt: ChatPromptDefaults.agentSystemPrompt,
            generationSettings: .agentDefault
          )
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
    content: String, modelProjectionPolicy: AssistantModelProjectionPolicy
  )? {
    for event in step?.events ?? [] {
      guard case .assistantMessageAppended(let content, let modelProjectionPolicy, _, _) = event
      else {
        continue
      }
      return (content, modelProjectionPolicy)
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

private actor CountingToolOrchestrator: ToolOrchestrating {
  private var count = 0
  nonisolated let toolRegistry: ToolRegistry

  var executionCount: Int {
    count
  }

  init(tools: [ToolDefinition] = [.readFile]) {
    toolRegistry = ToolRegistry(tools: tools)
  }

  func execute(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    count += 1

    let request = ToolCallRequestValidator().validate(rawRequest, registry: toolRegistry)
    let payload: ToolResultPayload
    switch request.payload {
    case .readFile(let input):
      payload = .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: input.path),
          content: ToolTextOutput(text: "1: project notes")
        ))
    case .listFiles(let input):
      let root = input.path ?? "."
      payload = .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: root),
          entries: [
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(
                rawValue: root == "." ? "README.md" : "\(root)/README.md"),
              kind: .file
            )
          ]
        ))
    case .runCommand(let input):
      payload = .runCommand(
        RunCommandResult(
          command: input.command,
          timeoutSeconds: input.timeoutSeconds,
          exitCode: 0,
          durationMs: 10,
          stdout: ToolTextOutput(text: "ok\n"),
          stderr: ToolTextOutput(text: "")
        ))
    default:
      payload = .failure(
        ToolFailure(
          toolName: rawRequest.toolName,
          path: nil,
          reason: .executionError("Unsupported counting tool.")
        ))
    }
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .low
      ),
      state: .completed(payload)
    )
  }
}

private struct FakeSearchService: WebSearching {
  func search(_ request: WebSearchRequest) async -> WebSearchToolResult {
    WebSearchToolResult(
      query: request.query,
      provider: request.settings.provider,
      results: [
        WebSearchResult(
          title: "Swift Concurrency",
          url: "https://www.swift.org/documentation/",
          snippet: "Swift docs fixture."
        )
      ]
    )
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
