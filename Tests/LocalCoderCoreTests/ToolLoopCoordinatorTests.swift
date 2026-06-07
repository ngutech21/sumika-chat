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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="read_file">
                <path>README.md</path>
                </action>
                """
            ))
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
  func executesNativeRuntimeToolCallWithoutTaggedActionText() async throws {
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: assistantMessageID, content: "")
          )
        ],
        interactionMode: .agent,
        toolCallingPolicy: .nativeGemma4,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          )
        ]
      )
    )

    #expect(annotatedAssistantMessageID(from: result) == assistantMessageID)
    #expect(toolCall(from: result)?.toolName == .readFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(completedToolResult(from: result)?.preview.text == "1: project notes")
  }

  @Test
  func askUserActionPausesForUserAnswerWithoutToolResult() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let turnID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: turnID,
        assistantMessageID: assistantMessageID,
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="ask_user">
                <question>Which implementation should I use?</question>
                <option1>Minimal fix</option1>
                <option2>Broader refactor</option2>
                </action>
                """
            ))
        ]
      )
    )

    #expect(annotatedAssistantMessageID(from: result) == assistantMessageID)
    #expect(toolCall(from: result)?.toolName == .askUser)
    let record = try #require(toolCallRecord(from: result))
    #expect(record.turnID == turnID)
    #expect(record.status == .awaitingUserAnswer)
    #expect(result?.continuation == .awaitingUserAnswer)
    #expect(toolResult(from: result) == nil)
    #expect(record.events.map(\.kind).contains(.awaitingUserAnswer))
  }

  @Test
  func tracesNativeToolArgumentDiagnosticsAfterValidation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let turnID = UUID()
    let tracer = RecordingToolLoopTurnTracer()
    let coordinator = ToolLoopCoordinator(turnTracer: tracer)

    _ = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: turnID,
        assistantMessageID: assistantMessageID,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: assistantMessageID, content: "")
          )
        ],
        interactionMode: .agent,
        toolCallingPolicy: .nativeGemma4,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "todo_write",
            arguments: [
              "id": .string("setup"),
              "status": .string("pending"),
              "},{content.": .string("Create project files"),
            ]
          )
        ]
      )
    )

    let event = try #require(await tracer.events.last { $0.phase == .toolExecute })
    #expect(event.turnID == turnID)
    #expect(event.toolName == "todo_write")
    #expect(event.toolCallFormat == "native")
    #expect(event.toolValidationStatus == "invalid")
    #expect(event.toolValidationError != nil)
    #expect(Set(event.toolArgumentKeys ?? []) == Set(["},{content.", "id", "status"]))
    #expect(Set(event.toolArguments?.map(\.name) ?? []) == Set(["},{content.", "id", "status"]))
    #expect(
      event.toolArguments?.first { $0.name == "},{content." }?.preview
        == "Create project files"
    )
  }

  @Test
  func redactsWritePayloadsFromToolArgumentDiagnostics() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let assistantMessageID = UUID()
    let tracer = RecordingToolLoopTurnTracer()
    let coordinator = ToolLoopCoordinator(turnTracer: tracer)

    _ = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: UUID(),
        assistantMessageID: assistantMessageID,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: assistantMessageID, content: "")
          )
        ],
        interactionMode: .agent,
        toolCallingPolicy: .nativeGemma4,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("secret.txt"),
              "content": .string("secret source content"),
            ]
          )
        ]
      )
    )

    let event = try #require(await tracer.events.last { $0.phase == .toolExecute })
    #expect(event.toolName == "write_file")
    #expect(event.toolArguments?.first { $0.name == "path" }?.preview == "secret.txt")
    #expect(event.toolArguments?.first { $0.name == "content" }?.preview == "[redacted]")
  }

  @Test
  func executesMultipleNativeRuntimeToolCallsWhenModelPolicyAllowsIt() async throws {
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: assistantMessageID, content: "")
          )
        ],
        interactionMode: .agent,
        toolCallingPolicy: .nativeGemma4,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ),
          ChatRuntimeToolCall(
            name: "list_files",
            arguments: ["root": .string(".")]
          ),
        ]
      )
    )

    #expect(annotatedAssistantMessageID(from: result) == assistantMessageID)
    #expect(toolCallRecords(from: result).map(\.request.toolName) == [.readFile, .listFiles])
    #expect(toolResults(from: result).map(\.toolName) == [.readFile, .listFiles])
    #expect(result?.continuation != .awaitingApproval)
  }

  @Test
  func rejectsMultipleNativeRuntimeToolCallsWhenModelPolicyDisallowsIt() async throws {
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: assistantMessageID, content: "")
          )
        ],
        interactionMode: .agent,
        toolCallingPolicy: .taggedAction,
        nativeToolCalls: [
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ),
          ChatRuntimeToolCall(
            name: "list_files",
            arguments: ["root": .string(".")]
          ),
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .invalid)
    #expect(toolCallRecord(from: result)?.status == .failed)
    #expect(
      completedToolResult(from: result)?.preview.text.contains(
        "multiple native tool calls") == true)
  }

  @Test
  func showFileDisplayStopsWithoutModelFollowUp() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try #"print("Hello, World!")"#.write(
      to: workspace.rootURL.appending(path: "hello.py"),
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
        items: [
          .userMessage(UserTurnMessage(content: "show the content of README.md")),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="show_file">
                <path>hello.py</path>
                </action>
                """
            )),
        ],
        interactionMode: .agent
      )
    )

    #expect(result?.continuation == .stopTurn)
    #expect(toolResult(from: result)?.toolName == .showFile)
    let assistant = directAssistantMessage(from: result)
    #expect(assistant?.content.contains("Here is `hello.py`:") == true)
    #expect(assistant?.content.contains("```python\n1: print(\"Hello, World!\")\n```") == true)
    #expect(
      assistant?.modelContextContent
        == "Displayed show_file result for hello.py directly to the user.")
  }

  @Test
  func showFileDisplayStopsWithoutModelFollowUpInAgentMode() async throws {
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="show_file">
                <path>README.md</path>
                </action>
                """
            ))
        ],
        interactionMode: .agent
      )
    )

    #expect(result?.continuation == .stopTurn)
    #expect(toolResult(from: result)?.toolName == .showFile)
    #expect(directAssistantMessage(from: result)?.content.contains("1: project notes") == true)
  }

  @Test
  func readFileKeepsModelFollowUpEvenForDisplayRequests() async throws {
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
        items: [
          .userMessage(UserTurnMessage(content: "show README.md")),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="read_file">
                <path>README.md</path>
                </action>
                """
            )),
        ],
        interactionMode: .agent
      )
    )

    #expect(completedToolResult(from: result)?.toolName == .readFile)
    #expect(directAssistantMessage(from: result) == nil)
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func directListFilesRequestStopsWithoutModelFollowUpInAgentMode() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let turnID = UUID()
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: turnID,
        assistantMessageID: assistantMessageID,
        items: [
          .userMessage(UserTurnMessage(content: "list the files in this directory")),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="list_files">
                <path>.</path>
                </action>
                """
            )),
        ],
        interactionMode: .agent
      )
    )

    #expect(result?.continuation == .stopTurn)
    #expect(toolResult(from: result)?.toolName == .listFiles)
    let assistant = directAssistantMessage(from: result)
    #expect(assistant?.content.contains("Files in `.`:") == true)
    #expect(assistant?.content.contains("README.md") == true)
    #expect(
      assistant?.modelContextContent
        == "Displayed list_files result for . directly to the user.")
  }

  @Test
  func directWorkspaceDiffRequestStopsWithoutModelFollowUpInAgentMode() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let turnID = UUID()
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator(
      agentToolOrchestrator: CompletedWorkspaceDiffToolOrchestrator()
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: turnID,
        assistantMessageID: assistantMessageID,
        items: [
          .userMessage(UserTurnMessage(content: "show git diff")),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="workspace_diff">
                </action>
                """
            )),
        ],
        interactionMode: .agent
      )
    )

    #expect(result?.continuation == .stopTurn)
    #expect(toolResult(from: result)?.toolName == .workspaceDiff)
    let assistant = directAssistantMessage(from: result)
    #expect(assistant?.content.contains("Workspace changes:") == true)
    #expect(assistant?.content.contains("Untracked:") == true)
    #expect(assistant?.content.contains("index.html") == true)
    #expect(
      assistant?.modelContextContent
        == "Displayed workspace_diff result directly to the user.")
  }

  @Test
  func workspaceDiffWithFollowUpQuestionKeepsModelFollowUpInAgentMode() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let turnID = UUID()
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator(
      agentToolOrchestrator: CompletedWorkspaceDiffToolOrchestrator()
    )

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: turnID,
        assistantMessageID: assistantMessageID,
        items: [
          .userMessage(UserTurnMessage(content: "show git diff and explain it")),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="workspace_diff">
                </action>
                """
            )),
        ],
        interactionMode: .agent
      )
    )

    #expect(completedToolResult(from: result)?.toolName == .workspaceDiff)
    #expect(directAssistantMessage(from: result) == nil)
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
  }

  @Test
  func listFilesWithFollowUpQuestionKeepsModelFollowUpInAgentMode() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let turnID = UUID()
    let assistantMessageID = UUID()
    let coordinator = ToolLoopCoordinator()

    let result = try await coordinator.run(
      ToolLoopRequest(
        workspace: workspace,
        sessionID: sessionID,
        turnID: turnID,
        assistantMessageID: assistantMessageID,
        items: [
          .userMessage(
            UserTurnMessage(
              content: "list the files and tell me which one looks like the entry point"
            )),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="list_files">
                <path>.</path>
                </action>
                """
            )),
        ],
        interactionMode: .agent
      )
    )

    #expect(completedToolResult(from: result)?.toolName == .listFiles)
    #expect(directAssistantMessage(from: result) == nil)
    #expect(resumePromptMode(from: result) == .afterToolResultCanContinue)
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="Read">
                <path>README.md</path>
                </action>
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="read_file">
                <path>README.md</path>
                <offset>2</offset>
                <limit>1</limit>
                </action>
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                I should inspect this.
                <action name="read_file">
                <path>README.md</path>
                </action>
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                ```xml
                <action name="list_files">
                <path>.</path>
                </action>
                ```
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="read_file">
                <path>README.md</path>
                </action>
                <action name="list_files">
                <path>.</path>
                </action>
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="read_file">
                <path>README.md</path>
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: "The answer does not need workspace context."
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="Deploy">
                <path>.</path>
                </action>
                """
            ))
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName.rawValue == "deploy")
    #expect(toolCallRecord(from: result)?.status == .failed)
    #expect(completedToolResult(from: result)?.toolName.rawValue == "deploy")
    #expect(completedToolResult(from: result)?.preview.status == .failed)
    #expect(
      completedToolResult(from: result)?.preview.text
        == "The tool call was invalid: Unknown tool: deploy.")
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="read_file">
                <path>README.md
                </action>
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                Tool call edit_file requested.
                Path:
                index.html
                Old text:
                <body>
                New text:
                <body style="background: blue">
                """
            ))
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="read_file">
                <path>README.md</path>
                </action>
                """
            ))
        ]
      )
    )

    #expect(toolCallRecord(from: result)?.resultPreview?.status == .failed)
    #expect(completedToolResult(from: result)?.preview.status == .failed)
    #expect(
      completedToolResult(from: result)?.preview.text
        == "read_file failed: Failed for test.")
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="write_file">
                <path>movies.html</path>
                <content delimiter="LC_PAYLOAD_V1">
                <html></html>
                </content>
                </action>
                """
            ))
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
  func completedWriteFileActionRequestsFinalFollowUp() async throws {
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="write_file">
                <path>movies.html</path>
                <content delimiter="LC_PAYLOAD_V1">
                <html></html>
                </content>
                </action>
                """
            ))
        ]
      )
    )

    #expect(toolCall(from: result)?.toolName == .writeFile)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(completedToolResult(from: result)?.toolName == .writeFile)
    #expect(completedToolResult(from: result)?.preview.status == .success)
    guard case .resumeGeneration(_, let promptMode) = result?.continuation else {
      Issue.record("Expected completed write_file to request a final follow-up.")
      return
    }
    #expect(promptMode == .afterToolResultFinal)
  }

  @Test
  func todoWriteUpdatesTodoStateAndKeepsObservationMinimal() async throws {
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
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantMessageID,
              content: """
                <action name="todo_write">
                <items delimiter="LC_PAYLOAD_V1">
                [
                  {"id":"inspect","content":"Inspect files","status":"completed"},
                  {"id":"verify","content":"Run tests","status":"inProgress"}
                ]
                LC_PAYLOAD_V1
                </items>
                </action>
                """
            ))
        ],
        interactionMode: .agent
      )
    )

    #expect(toolCall(from: result)?.toolName == .todoWrite)
    #expect(toolCallRecord(from: result)?.status == .completed)
    #expect(completedToolResult(from: result)?.preview.text == "Plan updated.")
    let todoState = todoStateChanged(from: result)
    #expect(todoState?.items.map(\.content) == ["Inspect files", "Run tests"])
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

  private func annotatedAssistantMessageID(from step: ChatWorkflowStep?) -> UUID? {
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
    toolCallRecords(from: step).first
  }

  private func toolCallRecords(from step: ChatWorkflowStep?) -> [ToolCallRecord] {
    var records: [ToolCallRecord] = []
    for event in step?.events ?? [] {
      guard case .toolCallAppended(let record, _) = event else {
        continue
      }
      records.append(record)
    }
    return records
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

  private func resumePromptMode(from step: ChatWorkflowStep?) -> ToolPromptMode? {
    guard case .resumeGeneration(_, let promptMode) = step?.continuation else {
      return nil
    }
    return promptMode
  }

  private func toolResult(from step: ChatWorkflowStep?) -> ToolResultModelMessage? {
    toolResults(from: step).first
  }

  private func toolResults(from step: ChatWorkflowStep?) -> [ToolResultModelMessage] {
    var results: [ToolResultModelMessage] = []
    for event in step?.events ?? [] {
      guard case .toolResultAppended(let toolResult, _) = event else {
        continue
      }
      results.append(toolResult)
    }
    return results
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
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .low
      ),
      state: .failed(
        .failure(
          ToolFailure(
            toolName: request.toolName, path: nil, reason: .executionError("Failed for test."))
        ))
    )
  }
}

private struct CompletedWorkspaceDiffToolOrchestrator: ToolOrchestrating {
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
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .low
      ),
      state: .completed(
        .workspaceDiff(
          .success(
            path: nil,
            content: ToolTextOutput(text: "Status:\nUntracked:\n  index.html")
          )
        )
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
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .high
      ),
      state: .completed(
        .writeFile(
          .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 19)
        ))
    )
  }
}

private actor RecordingToolLoopTurnTracer: TurnTracing {
  private(set) var events: [TurnTraceEvent] = []

  func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    events.append(event)
  }
}
