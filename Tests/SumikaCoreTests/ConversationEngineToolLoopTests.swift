import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ConversationEngineToolLoopTests {
  @Test
  func approveAllIgnoresConcurrentAndStaleInvocations() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        writeToolCall(path: "one.txt", content: "one"),
        writeToolCall(path: "two.txt", content: "two"),
      ],
      [.chunk("Wrote both files.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "write both files", in: workspace, sessionID: sessionID)

    try await waitUntil {
      engine.chatSession.toolCalls.count == 2
        && engine.chatSession.toolCalls.allSatisfy { $0.status == .awaitingApproval }
    }
    let anchorID = try #require(engine.chatSession.toolCalls.first?.id)

    engine.approveToolCallBatch(containing: anchorID, in: workspace)
    engine.approveToolCallBatch(containing: anchorID, in: workspace)
    try await waitUntil { engine.chatSession.turns.first?.status == .completed }

    engine.approveToolCallBatch(containing: anchorID, in: workspace)
    #expect(!engine.isGenerating)
    #expect(engine.chatSession.toolCalls.map(\.status) == [.completed, .completed])
    #expect(await runtime.capturedMessages.count == 2)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "one.txt"), encoding: .utf8)
        == "one")
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "two.txt"), encoding: .utf8)
        == "two")
  }

  @Test
  func reloadedPartialBatchApprovesOnlyWaitingRecords() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try "already written".write(
      to: workspace.rootURL.appending(path: "first.txt"),
      atomically: true,
      encoding: .utf8
    )
    let first = try makeWriteRecord(
      path: "first.txt",
      content: "must not run again",
      sessionID: sessionID,
      workspace: workspace,
      state: .completed(
        .writeFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "first.txt"),
            bytesWritten: 15
          )))
    )
    let second = try makeWriteRecord(
      path: "second.txt",
      content: "second",
      sessionID: sessionID,
      workspace: workspace,
      state: .awaitingApproval(preview: nil)
    )
    let third = try makeWriteRecord(
      path: "third.txt",
      content: "third",
      sessionID: sessionID,
      workspace: workspace,
      state: .awaitingApproval(preview: nil)
    )
    let persisted = ChatSession(
      id: sessionID,
      turns: [
        ChatTurn(
          status: .awaitingApproval,
          items: [
            .userMessage(UserTurnMessage(content: "Write three files.")),
            .tool(first),
            .assistantThinking(AssistantThinkingMessage(content: "Same response.")),
            .tool(second),
            .tool(third),
          ]
        )
      ],
      interactionMode: .agent
    )
    let decoded = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(persisted)
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("Finished the remaining writes.")]
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.loadSession(decoded)

    engine.approveToolCallBatch(containing: first.id, in: workspace)
    try await waitUntil { engine.chatSession.turns.first?.status == .completed }

    #expect(engine.chatSession.toolCalls.map(\.status) == [.completed, .completed, .completed])
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "first.txt"), encoding: .utf8)
        == "already written")
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "second.txt"), encoding: .utf8)
        == "second")
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "third.txt"), encoding: .utf8)
        == "third")
    #expect(await runtime.capturedMessages.count == 1)
  }

  @Test
  func reloadedApprovalUsesAlreadyConsumedTurnBatchBudget() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createListFixtureDirectories(in: workspace, count: budget - 1)
    let initialRuntime = ChatSessionFakeChatModelRuntime(
      eventTurns: listFileEventTurns(count: budget - 1)
        + [[writeToolCall(path: "final.txt", content: "final")]]
    )
    let initialController = ConversationEngine(
      runtime: initialRuntime,
      modelPath: "/tmp/model"
    )
    try initialController.loadSession(from: workspace, sessionID: sessionID)
    initialController.modelRuntime.modelState = .ready
    initialController.setInteractionMode(.agent)
    initialController.sendMessage(
      prompt: "inspect then write",
      in: workspace,
      sessionID: sessionID
    )
    try await waitUntil { initialController.hasPendingApproval && !initialController.isGenerating }

    #expect(initialController.chatSession.turns.first?.toolCallBatchCount == budget)
    let reloadedSession = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(initialController.chatSession)
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("Finished at the tool batch limit.")]
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.loadSession(reloadedSession)
    let pendingRecord = try #require(
      engine.chatSession.toolCalls.last(where: { $0.status == .awaitingApproval })
    )

    engine.approveToolCall(id: pendingRecord.id, in: workspace)
    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.turns.first?.toolCallBatchCount == budget)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "final.txt"),
        encoding: .utf8
      ) == "final"
    )
    let toolContexts = await runtime.capturedToolContexts
    #expect(toolContexts.count == 1)
    #expect(toolContexts[0] == nil)
  }

  @Test
  func askUserResumeUsesAlreadyConsumedTurnBatchBudget() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createListFixtureDirectories(in: workspace, count: budget - 1)
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: listFileEventTurns(count: budget - 1)
        + [
          [
            .toolCall(
              ChatRuntimeToolCall(
                name: "ask_user",
                arguments: [
                  "question": .string("Finish now?"),
                  "option1": .string("Finish"),
                  "option2": .string("Stop"),
                ]
              ))
          ],
          [.chunk("Finished after the answer at the tool batch limit.")],
        ]
    )
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "inspect and ask",
      in: workspace,
      sessionID: sessionID
    )
    try await waitUntil { engine.hasPendingUserAnswer && !engine.isGenerating }
    let askRecord = try #require(engine.chatSession.toolCalls.last)

    #expect(engine.chatSession.turns.first?.toolCallBatchCount == budget)
    engine.answerAskUserToolCall(id: askRecord.id, answer: "Finish", in: workspace)
    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.turns.first?.toolCallBatchCount == budget)
    let toolContexts = await runtime.capturedToolContexts
    #expect(toolContexts.count == budget + 1)
    #expect(toolContexts[budget] == nil)
  }

  @Test
  func sendMessageRunsReadOnlyToolsUntilBudgetThenStreamsFinalAssistantResponse() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createListFixtureDirectories(in: workspace, count: budget)
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: listFileEventTurns(count: budget)
        + [[.chunk("Tool limit reached. I stopped after the recorded file listings.")]]
    )
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "read the README repeatedly", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == budget)
    #expect(engine.chatSession.toolCalls.allSatisfy { $0.status == .completed })
    #expect(
      engine.chatSession.testMessages.last?.content
        == "Tool limit reached. I stopped after the recorded file listings.")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == budget + 1)
    #expect(!capturedSystemPrompts[1].contains("Available tools:"))
    #expect(!capturedSystemPrompts[budget - 1].contains("Available tools:"))
    #expect(!capturedSystemPrompts[budget].contains("Available tools:"))
    #expect(!capturedSystemPrompts[budget].contains("No more tools are available"))
    #expect(!capturedSystemPrompts[budget].contains("tool budget"))
    #expect(Set(capturedSystemPrompts).count == 1)

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == budget + 1)
    #expect(capturedPromptPlans[budget].stableInstructions == capturedSystemPrompts[0])
    #expect(
      capturedPromptPlans[budget].cacheIdentityInstructions.contains("[tool-schema-sha256:"))
    #expect(
      capturedPromptPlans[budget].cacheIdentityInstructions
        == capturedPromptPlans[0].cacheIdentityInstructions)
    #expect(
      capturedPromptPlans[budget].cacheIdentityInstructions != capturedSystemPrompts[0])
    #expect(capturedPromptPlans[budget].transientInstructions.isEmpty)

    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: budget)?
        .contains("No more tools are available for this generation") == true)

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == budget + 1)
    #expect(
      capturedToolContexts[0]?.cacheSystemPrompt
        == capturedPromptPlans[0].cacheIdentityInstructions)
    #expect(
      capturedToolContexts[1]?.cacheSystemPrompt
        == capturedPromptPlans[1].cacheIdentityInstructions)
    #expect(capturedSystemPrompts[0] == capturedSystemPrompts[1])
    #expect(
      capturedToolContexts[0]?.cacheSystemPrompt
        == capturedToolContexts[1]?.cacheSystemPrompt)
    #expect(capturedToolContexts[budget] == nil)
  }

  @Test
  func sendMessageFailsWhenBudgetFinalizationHasNoVisibleText() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createListFixtureDirectories(in: workspace, count: budget)
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: listFileEventTurns(count: budget) + [[]]
    )
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "read the README repeatedly", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == budget)
    #expect(engine.chatSession.toolCalls.allSatisfy { $0.status == .completed })
    #expect(engine.chatSession.turns.first?.status == .failed)
    #expect(engine.chatSession.turns.first?.modelContextPolicy == .excluded)
    #expect(engine.errorMessage == ChatGenerationError.emptyModelResponse.localizedDescription)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == budget + 1)
    #expect(Set(capturedSystemPrompts).count == 1)
    #expect(!capturedSystemPrompts[budget].contains("No more tools are available"))

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == budget + 1)
    #expect(capturedPromptPlans[budget].transientInstructions.isEmpty)
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: budget)?
        .contains("No more tools are available for this generation") == true)
    #expect(capturedMessages.count == budget + 1)

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == budget + 1)
    #expect(capturedToolContexts[budget] == nil)
  }

  @Test
  func approvedFailedRunCommandAddsRecoveryRuntimeNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: [
              "command": .string("false"),
              "timeoutSeconds": .number(1),
              "reason": .string("Exercise failed command recovery."),
            ]
          ))
      ],
      [.chunk("I've completed it.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: true)
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "run a failing command", in: workspace, sessionID: sessionID)

    try await waitUntil { engine.hasPendingApproval }
    let pending = try #require(engine.chatSession.toolCalls.first)
    engine.configureAgentTools(todoWriteEnabled: false)
    engine.approveToolCall(id: pending.id, in: workspace)

    try await waitUntil { !engine.isGenerating }

    let record = try #require(engine.chatSession.toolCalls.first)
    #expect(record.request.toolName == .runCommand)
    #expect(record.resultPreview?.status == .failed)
    #expect(
      engine.chatSession.testMessages.last?.content.contains(
        "The previous command failed."
      ) == true)
    #expect(engine.chatSession.testMessages.last?.content.contains("completed it") == false)

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 2)
    #expect(
      capturedPromptPlans.allSatisfy {
        $0.toolContext?.registry.definition(for: .todoWrite) != nil
      })
    #expect(capturedPromptPlans[1].transientInstructions.isEmpty)
    let capturedMessages = await runtime.capturedMessages
    let notice = try #require(latestToolFollowUpNotice(in: capturedMessages, at: 1))
    #expect(toolFollowUpNotices(in: capturedMessages[1]).count == 1)
    #expect(notice.contains("The latest run_command failed."))
    #expect(notice.contains("Command: false"))
    #expect(notice.contains("Exit code: 1"))
    #expect(notice.contains("Do not repeat the same command unchanged."))
    #expect(
      notice.contains(
        "Inspect stdout/stderr, run a corrected command, or call finish_task with status blocked and explain the blocker."
      )
    )
    #expect(!notice.contains("Continue using the latest tool observation"))
  }

  @Test
  func repeatedIdenticalFailingRunCommandForcesFinalEscalation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let failingCall = ChatRuntimeToolCall(
      name: "run_command",
      arguments: [
        "command": .string("false"),
        "timeoutSeconds": .number(1),
        "reason": .string("Exercise repeated failure escalation."),
      ]
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.toolCall(failingCall)],
      [.toolCall(failingCall)],
      [.chunk("The command keeps failing; please run it yourself.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "stage the changes", in: workspace, sessionID: sessionID)

    // First failing command → approve → the model re-proposes the identical command.
    try await waitUntil { engine.hasPendingApproval }
    let first = try #require(engine.chatSession.toolCalls.first)
    engine.approveToolCall(id: first.id, in: workspace)

    // Second identical failure → approve → the brake forces a tools-free final generation.
    try await waitUntil {
      engine.chatSession.toolCalls.count == 2 && engine.hasPendingApproval
    }
    let second = try #require(engine.chatSession.toolCalls.last)
    engine.approveToolCall(id: second.id, in: workspace)

    try await waitUntil { engine.chatSession.turns.first?.status == .completed }

    #expect(engine.chatSession.toolCalls.count == 2)
    #expect(!engine.hasPendingApproval)
    #expect(
      engine.chatSession.testMessages.last?.content
        == "The command keeps failing; please run it yourself.")

    // The final generation received the escalation notice, not the generic close.
    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 3)
    let escalation = try #require(latestToolFollowUpNotice(in: capturedMessages, at: 2))
    #expect(escalation.contains("failed both times"))
    #expect(escalation.contains("Command: false"))
    #expect(escalation.contains("run or fix the command manually"))
  }

  @Test
  func thinkingOnlyResponseWithoutToolCallFailsAndExcludesTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.thinkingChunk("I am reasoning but not answering.")]
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "answer visibly", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .failed)
    #expect(engine.chatSession.turns.first?.modelContextPolicy == .excluded)
    #expect(engine.errorMessage == ChatGenerationError.emptyModelResponse.localizedDescription)
  }

  @Test
  func duplicateToolCallObservationContinuesToNextModelIteration() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [.chunk("Continuing after the duplicate observation.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the project", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.toolCalls.count == 2)
    #expect(engine.chatSession.toolCalls.first?.request.toolName == .listFiles)
    let duplicatePayload = engine.chatSession.toolCalls.last?.resultPayload
    guard case .duplicateToolCall(let duplicate)? = duplicatePayload
    else {
      Issue.record("Expected second tool call to be duplicate observation.")
      return
    }
    #expect(duplicate.previousCallID == engine.chatSession.toolCalls.first?.id)
    #expect(
      engine.chatSession.testMessages.last?.content
        == "Continuing after the duplicate observation.")

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == 3)
    #expect(capturedToolContexts[0] != nil)
    #expect(capturedToolContexts[1] != nil)
    #expect(capturedToolContexts[2] != nil)

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 3)
    #expect(capturedPromptPlans[1].transientInstructions.isEmpty)
    #expect(capturedPromptPlans[2].transientInstructions.isEmpty)
    let capturedMessages = await runtime.capturedMessages
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 1) == genericToolFollowUpNotice)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)
        == duplicateReplayNotice(.listFiles)
    )
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)?
        .contains("Continue using the latest tool observation") == false
    )
    #expect(toolFollowUpNotices(in: capturedMessages[2]).count == 2)
  }

  @Test
  func normalSuccessfulToolResultAddsGenericFollowUpNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        )
      ],
      [.chunk("README contains project notes.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect README", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 2)
    #expect(capturedPromptPlans[1].transientInstructions.isEmpty)
    let capturedMessages = await runtime.capturedMessages
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 1) == genericToolFollowUpNotice)
    #expect(toolFollowUpNotices(in: capturedMessages[1]).count == 1)
  }

  @Test
  func finishTaskCompletesTurnWithoutSecondRuntimeCall() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let summary = "Implemented the requested change and verified the focused tests."
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "finish_task",
            arguments: [
              "status": .string("done"),
              "summary": .string(summary),
            ]
          ))
      ],
      [.chunk("UNEXPECTED_SECOND_GENERATION")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "finish the task", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.errorMessage == nil)
    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.toolCalls.count == 1)
    #expect(engine.chatSession.toolCalls.first?.request.toolName == .finishTask)
    #expect(engine.chatSession.toolCalls.first?.status == .completed)
    #expect(engine.chatSession.testMessages.last?.content == summary)
    #expect(
      !engine.chatSession.testMessages.contains { message in
        message.content.contains("UNEXPECTED_SECOND_GENERATION")
      })

    let capturedPromptPlans = await runtime.capturedPromptPlans
    let capturedMessages = await runtime.capturedMessages
    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedPromptPlans.count == 1)
    #expect(capturedMessages.count == 1)
    #expect(capturedToolContexts.count == 1)
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .finishTask) != nil)
  }

  @Test
  func invalidFinishTaskArgumentsRepairToValidFinish() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "finish_task",
            arguments: [
              "status": .string("complete"),
              "summary": .string("Invalid first attempt."),
            ]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "finish_task",
            arguments: [
              "status": .string("done"),
              "summary": .string("Repaired the finish call."),
            ]
          ))
      ],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "finish the task", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.toolCalls.map(\.request.toolName) == [.finishTask, .finishTask])
    #expect(engine.chatSession.toolCalls.map(\.status) == [.failed, .completed])
    #expect(engine.chatSession.testMessages.last?.content == "Repaired the finish call.")
    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.role == .tool
          && message.content.contains(
            "Invalid argument type for status. Expected done, blocked, or needs_user.")
      })
  }

  @Test
  func mixedFinishTaskBatchPersistsEveryFailedCallBeforeRepair() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        ),
        .toolCall(
          ChatRuntimeToolCall(
            name: "finish_task",
            arguments: [
              "status": .string("done"),
              "summary": .string("Invalid mixed batch."),
            ]
          )),
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "finish_task",
            arguments: [
              "status": .string("done"),
              "summary": .string("Finished after repairing the mixed batch."),
            ]
          ))
      ],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect and finish", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(
      engine.chatSession.toolCalls.map(\.request.toolName) == [
        .readFile, .finishTask, .finishTask,
      ])
    #expect(engine.chatSession.toolCalls.map(\.status) == [.failed, .failed, .completed])
    #expect(
      engine.chatSession.testMessages.last?.content
        == "Finished after repairing the mixed batch.")
    for record in engine.chatSession.toolCalls.prefix(2) {
      guard case .invalid(let invalidInput) = record.request.payload else {
        Issue.record("Expected every call in the mixed batch to be persisted as invalid.")
        return
      }
      #expect(
        invalidInput.reason.message
          == "finish_task must be the only native tool call in a response.")
    }
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 2)
  }

  @Test
  func invalidBatchAtToolBudgetBoundaryFinalizesWithoutToolCapableRepair() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let callsBeforeInvalidBatch = ChatToolLoopLimits.defaultMaxToolLoopIterations - 1
    try createListFixtureDirectories(in: workspace, count: callsBeforeInvalidBatch)
    let finalSummary = "The final mixed batch was invalid, so I stopped."
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: listFileEventTurns(count: callsBeforeInvalidBatch)
        + [
          [
            .toolCall(
              ChatRuntimeToolCall(
                name: "read_file",
                arguments: ["path": .string("README.md")]
              )),
            .toolCall(
              ChatRuntimeToolCall(
                name: "finish_task",
                arguments: [
                  "status": .string("done"),
                  "summary": .string("Invalid mixed batch."),
                ]
              )),
          ],
          [.chunk(finalSummary)],
        ]
    )
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect and finish", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.testMessages.last?.content == finalSummary)
    #expect(Array(engine.chatSession.toolCalls.suffix(2)).map(\.status) == [.failed, .failed])
    #expect(engine.chatSession.turns.first?.toolCallBatchCount == callsBeforeInvalidBatch + 1)
    let toolContexts = await runtime.capturedToolContexts
    #expect(toolContexts.count == ChatToolLoopLimits.defaultMaxToolLoopIterations + 1)
    #expect(toolContexts[ChatToolLoopLimits.defaultMaxToolLoopIterations] == nil)
  }

  @Test
  func secondConsecutiveDuplicateBlocksContentAndForcesFinal() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")])
        )
      ],
      [.chunk("I will answer from the existing README content.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect README", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    // original + 1st duplicate (replayed) + 2nd duplicate (blocked, forces final).
    #expect(engine.chatSession.toolCalls.count == 3)
    #expect(engine.chatSession.turns.first?.status == .completed)

    // 1st duplicate replays content and stays success; 2nd duplicate is blocked.
    guard
      case .duplicateToolCall(let firstDuplicate)? =
        engine.chatSession.toolCalls[1].resultPayload
    else {
      Issue.record("Expected the second call to be a replayed duplicate.")
      return
    }
    #expect(!firstDuplicate.blocked)
    #expect(firstDuplicate.replayedObservation != nil)

    guard
      case .duplicateToolCall(let secondDuplicate)? =
        engine.chatSession.toolCalls[2].resultPayload
    else {
      Issue.record("Expected the third call to be a blocked duplicate.")
      return
    }
    #expect(secondDuplicate.blocked)
    #expect(secondDuplicate.replayedObservation == nil)
    // Persisted/UI preview stays benign (not a failure).
    #expect(engine.chatSession.toolCalls[2].resultPayload?.status == .success)

    let capturedMessages = await runtime.capturedMessages
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 1) == genericToolFollowUpNotice)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)
        == duplicateReplayNotice(.readFile))
    // 2nd duplicate forces the tools-stripped final generation → final notice, not the
    // soft read-replay escalation.
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 3) == finalToolResultNotice)
  }

  @Test
  func repeatedListingsWithoutReadAddListingWanderingNoticeWithReplay() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")])
        )
      ],
      [.chunk("I will read Sources/App.swift next.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 3)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(listingWanderingNotice(in: capturedMessages[1]) == nil)
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 1) == genericToolFollowUpNotice)
    let notice = try #require(listingWanderingNotice(in: capturedMessages[2]))
    #expect(notice.contains(listingWanderingNoticeText))
    #expect(notice.contains("Latest entries or matches:"))
    #expect(notice.contains("- Sources/App.swift"))
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2) != genericToolFollowUpNotice
    )
    #expect(toolFollowUpNotices(in: capturedMessages[2]).count == 2)
  }

  @Test
  func listingWanderingNoticeTakesPriorityOverDuplicateReplayNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")])
        )
      ],
      [.chunk("I will stop listing and read a file.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    guard case .duplicateToolCall = engine.chatSession.toolCalls.last?.resultPayload else {
      Issue.record("Expected third list_files call to replay the previous observation.")
      return
    }
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(listingWanderingNotice(in: capturedMessages[3]) != nil)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 3) != duplicateReplayNotice(.listFiles)
    )
    #expect(toolFollowUpNotices(in: capturedMessages[3]).count == 3)
  }

  @Test
  func successfulReadFileClearsListingWanderingNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("Sources/App.swift")]
          ))
      ],
      [.chunk("I read the source file.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)?
        .contains(listingWanderingNoticeText) == true)
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 3) == genericToolFollowUpNotice)
  }

  @Test
  func unchangedReadFileClearsListingWanderingNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let appPath = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("Sources/App.swift")]
          ))
      ],
      [.chunk("The file was already in context.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: fixedReadFileOrchestrator(
        .unchanged(path: appPath, readKey: ReadKey(path: appPath))
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)?
        .contains(listingWanderingNoticeText) == true)
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 3) == genericToolFollowUpNotice)
  }

  @Test
  func failedReadFileDoesNotClearListingWanderingNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("missing.swift")]
          ))
      ],
      [.chunk("The file was missing.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)?
        .contains(listingWanderingNoticeText) == true)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 3)?
        .contains(listingWanderingNoticeText) == true)
  }

  @Test
  func repeatedReadWarningDoesNotClearListingWanderingNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string("Sources")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("Sources/App.swift")]
          ))
      ],
      [.chunk("I should stop looping.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: fixedReadFileOrchestrator(
        .repeatedReadWarning(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"), count: 4)
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)?
        .contains(listingWanderingNoticeText) == true)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 3)?
        .contains(listingWanderingNoticeText) == true)
  }

  @Test
  func duplicateListingDoesNotCountTowardListingWanderingNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [.chunk("Continuing after the duplicate listing.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    guard case .duplicateToolCall = engine.chatSession.toolCalls.last?.resultPayload else {
      Issue.record("Expected duplicate list_files replay.")
      return
    }
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 3)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)
        == duplicateReplayNotice(.listFiles))
  }

  @Test
  func mixedListingAndGlobStepsAddListingWanderingNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    try createSourcesAppFile(in: workspace)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "glob_files",
            arguments: ["pattern": .string("**/*.swift")]
          ))
      ],
      [.chunk("I found Swift files.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the app sources", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 3)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    let notice = try #require(latestToolFollowUpNotice(in: capturedMessages, at: 2))
    #expect(notice.contains(listingWanderingNoticeText))
    #expect(notice.contains("- Sources/App.swift"))
  }

  @Test
  func visibleTextWithToolCallRunsToolLoopInsteadOfCompletingTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .chunk("I will inspect the project."),
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        ),
      ],
      [.chunk("The project contains README.md.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the project", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.toolCalls.count == 1)
    #expect(engine.chatSession.toolCalls.first?.request.toolName == .listFiles)
    #expect(engine.chatSession.testMessages.last?.content == "The project contains README.md.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.role == .assistant && message.content == "I will inspect the project."
      })
    #expect(capturedMessages[1].contains { message in message.role == .tool })
  }

  @Test
  func toolBudgetExhaustionUsesFinalizationPath() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    // Distinct list_files calls (different paths) so the duplicate block never fires and
    // the loop runs to the iteration budget, then finalizes with tools stripped.
    var eventTurns = listFileEventTurns(count: budget)
    eventTurns.append([
      .chunk("Tool limit reached. I stopped after the recorded file listings.")
    ])
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: eventTurns)
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "list until the tool budget is exhausted", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.toolCalls.count == budget)
    #expect(engine.chatSession.toolCalls.first?.resultPayload?.status == .success)
    #expect(
      engine.chatSession.testMessages.last?.content
        == "Tool limit reached. I stopped after the recorded file listings.")

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == budget + 1)
    #expect(capturedToolContexts[budget] == nil)
  }

  @Test
  func todoWriteUpdatesSessionStateAndRendersPlanAsTransientContext() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "todo_write",
            arguments: [
              "item1": .string("Inspect files"),
              "done1": .bool(true),
              "item2": .string("Run tests"),
              "done2": .bool(false),
            ]
          ))
      ],
      [.chunk("Continuing with the plan.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(
      engine.chatSession.todoState?.items.map(\.content) == ["Inspect files", "Run tests"])
    #expect(engine.chatSession.testMessages.last?.content == "Continuing with the plan.")
    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 2)
    #expect(!capturedSystemPrompts[0].contains("Current plan:"))
    #expect(!capturedSystemPrompts[1].contains("Current plan:"))
    #expect(capturedSystemPrompts[0] == capturedSystemPrompts[1])
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 2)
    #expect(
      capturedPromptPlans[1].transientInstructions.contains {
        $0.contains("Current plan:") && $0.contains("- [pending] Run tests")
      })

    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect without plan", in: workspace, sessionID: sessionID)
    try await waitUntil { !engine.isGenerating }

    let promptsAfterSecondAgentTurn = await runtime.capturedSystemPrompts
    #expect(promptsAfterSecondAgentTurn.last?.contains("Current plan:") == false)
    let plansAfterSecondAgentTurn = await runtime.capturedPromptPlans
    #expect(
      plansAfterSecondAgentTurn.last?.transientInstructions.contains {
        $0.contains("Current plan:")
      } == true)
    #expect(engine.chatSession.todoState?.items.count == 2)
  }

  @Test
  func disabledTodoWriteRegistryHidesSchemaAndRejectsTodoWriteCalls() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "todo_write",
            arguments: [
              "item1": .string("Inspect files"),
              "done1": .bool(false),
              "item2": .string("Run tests"),
              "done2": .bool(false),
            ]
          ))
      ],
      [.chunk("Continuing without a todo plan.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false)
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let toolCall = try #require(engine.chatSession.toolCalls.first)
    #expect(toolCall.request.toolName == .todoWrite)
    #expect(toolCall.status == .failed)
    #expect(
      toolCall.resultPayload
        == .invalidTool(
          InvalidToolResult(originalName: "todo_write", reason: .unavailableToolName("todo_write"))
        ))
    #expect(engine.chatSession.todoState == nil)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.first?.contains("todo_write") == false)
    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .todoWrite) == nil)
  }

  @Test
  func enablingTodoWriteDuringGenerationDoesNotAffectActiveTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ControlledStreamingRuntime(
      eventTurns: [
        [
          .toolCall(
            ChatRuntimeToolCall(
              name: "todo_write",
              arguments: [
                "item1": .string("Inspect files"),
                "done1": .bool(false),
                "item2": .string("Run tests"),
                "done2": .bool(false),
              ]
            ))
        ],
        [.chunk("Continuing without a todo plan.")],
        [.chunk("Next turn can see todo_write.")],
      ],
      blockedCallIndexes: [0]
    )
    defer { Task { await runtime.releaseStream(callIndex: 0) } }
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false)
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }

    engine.configureAgentTools(todoWriteEnabled: true)
    await runtime.releaseStream(callIndex: 0)

    try await waitUntil { !engine.isGenerating }

    let toolCall = try #require(engine.chatSession.toolCalls.first)
    #expect(toolCall.status == .failed)
    #expect(
      toolCall.resultPayload
        == .invalidTool(
          InvalidToolResult(originalName: "todo_write", reason: .unavailableToolName("todo_write"))
        ))
    #expect(engine.chatSession.todoState == nil)

    let capturedToolContexts = await runtime.capturedToolContexts
    let activeTurnToolContexts = capturedToolContexts.prefix(2).compactMap { $0 }
    #expect(activeTurnToolContexts.count == 2)
    #expect(
      activeTurnToolContexts.allSatisfy {
        $0.registry.definition(for: .todoWrite) == nil
      })

    engine.sendMessage(prompt: "continue", in: workspace, sessionID: sessionID)
    try await waitUntil { !engine.isGenerating }

    let prompts = await runtime.capturedSystemPrompts
    #expect(prompts.last?.contains("todo_write") == true)
  }

  @Test
  func disablingTodoWriteDuringGenerationDoesNotAffectActiveTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ControlledStreamingRuntime(
      eventTurns: [
        [
          .toolCall(
            ChatRuntimeToolCall(
              name: "todo_write",
              arguments: [
                "item1": .string("Inspect files"),
                "done1": .bool(false),
                "item2": .string("Run tests"),
                "done2": .bool(false),
              ]
            ))
        ],
        [.chunk("Continuing with the plan.")],
        [.chunk("Next turn does not see todo_write.")],
      ],
      blockedCallIndexes: [0]
    )
    defer { Task { await runtime.releaseStream(callIndex: 0) } }
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: true)
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }

    engine.configureAgentTools(todoWriteEnabled: false)
    await runtime.releaseStream(callIndex: 0)

    try await waitUntil { !engine.isGenerating }

    let toolCall = try #require(engine.chatSession.toolCalls.first)
    #expect(toolCall.status == .completed)
    #expect(
      engine.chatSession.todoState?.items.map(\.content) == ["Inspect files", "Run tests"])

    let capturedToolContexts = await runtime.capturedToolContexts
    let activeTurnToolContexts = capturedToolContexts.prefix(2).compactMap { $0 }
    #expect(activeTurnToolContexts.count == 2)
    #expect(
      activeTurnToolContexts.allSatisfy {
        $0.registry.definition(for: .todoWrite) != nil
      })

    engine.sendMessage(prompt: "continue", in: workspace, sessionID: sessionID)
    try await waitUntil { !engine.isGenerating }

    let prompts = await runtime.capturedSystemPrompts
    #expect(prompts.last?.contains("todo_write") == false)
  }

  @Test
  func removingMCPToolDuringGenerationKeepsPausedTurnOrchestratorFrozen() async throws {
    let sessionID = UUID()
    let serverID = UUID()
    let toolName = MCPToolNaming.qualifiedName(serverSlug: "frozen", remoteToolName: "echo")
    let workspace = try makeWorkspace(sessionID: sessionID)
    let client = RecordingMCPToolClient()
    let runtime = ControlledStreamingRuntime(
      eventTurns: [
        [
          .toolCall(
            ChatRuntimeToolCall(
              name: toolName.rawValue,
              arguments: ["value": .string("hello")]
            ))
        ],
        [.chunk("MCP call completed.")],
      ],
      blockedCallIndexes: [0]
    )
    defer { Task { await runtime.releaseStream(callIndex: 0) } }
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(id: sessionID, interactionMode: .agent)
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.reconcileAgentTools(
      todoWriteEnabled: true,
      mcpExecutorGroups: [
        makeMCPExecutorGroup(serverID: serverID, serverSlug: "frozen", client: client)
      ],
      selectedMCPServerIDs: [serverID]
    )

    engine.sendMessage(prompt: "call the MCP tool", in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }

    engine.configureAgentTools(todoWriteEnabled: true, mcpExecutorGroups: [])
    await runtime.releaseStream(callIndex: 0)

    try await waitUntil { engine.hasPendingApproval && !engine.isGenerating }
    let pendingRecord = try #require(engine.chatSession.toolCalls.first)
    engine.approveToolCall(id: pendingRecord.id, in: workspace)

    try await waitUntil { !engine.isGenerating }

    #expect(await client.callCount == 1)
    let completedRecord = try #require(engine.chatSession.toolCalls.first)
    #expect(completedRecord.request.toolName == toolName)
    #expect(completedRecord.status == .completed)
    let capturedToolContexts = await runtime.capturedToolContexts.compactMap { $0 }
    #expect(capturedToolContexts.count == 2)
    #expect(capturedToolContexts.allSatisfy { $0.registry.definition(for: toolName) != nil })
  }

  @Test
  func askUserPausesThenAnswerResumesSameTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "ask_user",
            arguments: [
              "question": .string("Which implementation should I use?"),
              "option1": .string("Minimal fix"),
              "option2": .string("Broader refactor"),
            ]
          ))
      ],
      [.chunk("I'll make the minimal fix.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "implement the feature", in: workspace, sessionID: sessionID)

    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingUserAnswer }

    #expect(!engine.isGenerating)
    #expect(engine.hasPendingUserAnswer)
    #expect(engine.isInputBlocked)
    let record = try #require(engine.chatSession.toolCalls.first)
    #expect(record.request.toolName == .askUser)
    #expect(record.status == .awaitingUserAnswer)

    engine.answerAskUserToolCall(id: record.id, answer: "Minimal fix", in: workspace)

    try await waitUntil { !engine.isGenerating && !engine.hasPendingUserAnswer }

    #expect(engine.chatSession.turns.first?.status == .completed)
    let answeredRecord = try #require(engine.chatSession.toolCalls.first)
    #expect(answeredRecord.status == .completed)
    #expect(answeredRecord.resultPayload == .askUser(AskUserResult(answer: "Minimal fix")))
    #expect(engine.chatSession.testMessages.last?.content == "I'll make the minimal fix.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.role == .tool && message.content.contains("User answered: Minimal fix")
      })
  }

  @Test
  func sendingNewMessageDoesNotInterruptPendingAskUser() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "ask_user",
            arguments: [
              "question": .string("Which implementation should I use?"),
              "option1": .string("Minimal fix"),
              "option2": .string("Broader refactor"),
            ]
          ))
      ],
      [.chunk("I will follow the new instruction.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "implement the feature", in: workspace, sessionID: sessionID)
    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingUserAnswer }
    #expect(
      !engine.sendMessage(
        prompt: "ignore that question and use the broader refactor",
        in: workspace,
        sessionID: sessionID
      ))

    #expect(engine.chatSession.turns.count == 1)
    #expect(engine.chatSession.turns[0].status == .awaitingUserAnswer)
    #expect(engine.chatSession.toolCalls.first?.status == .awaitingUserAnswer)

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 1)
  }

  @Test
  func failedEditFileResultLetsModelRecoverWithReadFile() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "edit_file",
            arguments: [
              "path": .string("README.md"),
              "old_text": .string("missing text"),
              "new_text": .string("replacement"),
            ]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ))
      ],
      [.chunk("The file contains project notes.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "replace missing text in README", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 2)
    #expect(engine.chatSession.toolCalls[0].request.toolName == .editFile)
    #expect(engine.chatSession.toolCalls[0].status == .failed)
    #expect(
      engine.chatSession.toolCalls[0].resultPreview?.text.contains("not found") == true)
    #expect(engine.chatSession.toolCalls[1].request.toolName == .readFile)
    #expect(engine.chatSession.toolCalls[1].status == .completed)
    #expect(engine.chatSession.testMessages.last?.content == "The file contains project notes.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count >= 2)
    let recoveryPrompt = try #require(capturedMessages[1].last(where: { $0.role == .tool }))
    #expect(
      recoveryPrompt.content.contains("edit_file failed: old_text was not found in README.md"))
    #expect(recoveryPrompt.content.contains("Do not retry edit_file from memory"))
    #expect(recoveryPrompt.content.contains("First call read_file(path: \"README.md\")"))
  }

  @Test
  func subsequentUserTurnsCanUseToolsAgainInSameSession() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ))
      ],
      [.chunk("First answer.")],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "list_files",
            arguments: ["path": .string(".")]
          ))
      ],
      [.chunk("Second answer.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)

    engine.sendMessage(prompt: "read README.md", in: workspace, sessionID: sessionID)
    try await waitUntil { !engine.isGenerating }

    engine.sendMessage(prompt: "list files", in: workspace, sessionID: sessionID)
    try await waitUntil { !engine.isGenerating && engine.chatSession.toolCalls.count == 2 }

    #expect(engine.chatSession.turns.count == 2)
    #expect(engine.chatSession.turns.allSatisfy { $0.status == .completed })
    #expect(engine.chatSession.toolCalls.map(\.request.toolName) == [.readFile, .listFiles])
    #expect(engine.chatSession.testMessages.last?.content.contains("Files in `.`:") == true)
    #expect(engine.chatSession.testMessages.last?.content.contains("README.md") == true)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 3)
    #expect(capturedSystemPrompts[2].contains("list_files"))
  }

  @Test
  func runCommandAddsRuntimeNoticeAfterFirstCall() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [.chunk("I am blocked on repeated git status output.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 0)
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "check status", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 2)
    #expect(
      engine.chatSession.toolCalls.allSatisfy { record in
        record.request.toolName == .runCommand && record.status == .completed
      })
    #expect(
      engine.chatSession.toolCalls.allSatisfy { record in
        if case .duplicateToolCall = record.resultPayload {
          return false
        }
        return true
      })

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 3)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 1) == repeatedRunCommandNotice)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 1) != genericToolFollowUpNotice
    )
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 2) == repeatedRunCommandNotice)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2) != genericToolFollowUpNotice
    )
    #expect(toolFollowUpNotices(in: capturedMessages[2]).count == 2)
  }

  @Test
  func runCommandWithDifferentReasonsAddsRuntimeNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let command = "git add. && git commit -m \"Initial commit\""
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall(command, reason: "Stage all files and commit the changes.")],
      [runCommandToolCall(command, reason: "Stage all files with the corrected command.")],
      [runCommandToolCall(command, reason: "Stage all files with the correct syntax.")],
      [.chunk("I am blocked on repeated git add output.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 0)
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "commit the project", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 3)
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 2) == repeatedRunCommandNotice)
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 3) == repeatedRunCommandNotice)
  }

  @Test
  func failedRunCommandNoticeTakesPriorityOverRepeatedRuntimeNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [.chunk("The command is still failing.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 1)
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "check status", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 3)
    #expect(
      engine.chatSession.toolCalls.allSatisfy { record in
        guard record.request.toolName == .runCommand,
          case .runCommand(let result)? = record.resultPayload
        else {
          return false
        }
        return result.outcomeStatus == .failed
      })

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 3)?
        .contains("The latest run_command failed.") == true)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 3) != repeatedRunCommandNotice
    )
    #expect(toolFollowUpNotices(in: capturedMessages[3]).count == 3)
  }

  @Test
  func failedRunCommandNoticeDoesNotStackWithRepeatedCommandNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let command = "git add. && git commit -m \"Initial commit\""
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall(command)],
      [runCommandToolCall(command)],
      [.chunk("The command is blocked.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 1)
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "commit the project", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 2)
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 3)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2)?
        .contains("The latest run_command failed.") == true
    )
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 2) != repeatedRunCommandNotice
    )
    #expect(toolFollowUpNotices(in: capturedMessages[2]).count == 2)
  }

  @Test
  func differentRunCommandArgumentsEachAddRuntimeNoticeForLatestCommand() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall("git status")],
      [runCommandToolCall("git diff")],
      [runCommandToolCall("git status")],
      [.chunk("I inspected different command outputs.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 0)
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect git state", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 3)
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 1) == repeatedRunCommandNotice)
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 2) == repeatedRunCommandNotice)
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 3) == repeatedRunCommandNotice)
  }

  @Test
  func differentToolSignatureClearsRepeatedRunCommandRuntimeNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ],
      [.chunk("I switched to inspecting files.")],
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: ToolExecutorRegistry([
          AnyToolExecutor(AllowedRunCommandToolExecutor(exitCode: 0)),
          AnyToolExecutor(ListFilesToolExecutor()),
        ])
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "inspect the workspace", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(
      engine.chatSession.toolCalls.map(\.request.toolName) == [
        .runCommand, .runCommand, .runCommand, .listFiles,
      ])
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 5)
    #expect(capturedPromptPlans.allSatisfy { $0.transientInstructions.isEmpty })
    let capturedMessages = await runtime.capturedMessages
    #expect(latestToolFollowUpNotice(in: capturedMessages, at: 3) == repeatedRunCommandNotice)
    #expect(
      latestToolFollowUpNotice(in: capturedMessages, at: 4) != repeatedRunCommandNotice)
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !condition() {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func waitUntilAsync(
    timeout: Duration = .seconds(1),
    condition: @escaping () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for async condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func createListFixtureDirectories(in workspace: Workspace, count: Int) throws {
    for index in 1..<count {
      try FileManager.default.createDirectory(
        at: workspace.rootURL.appending(path: "dir-\(index)", directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
    }
  }

  private func createSourcesAppFile(in workspace: Workspace) throws {
    let sourcesURL = workspace.rootURL.appending(path: "Sources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
    try "struct App {}\n".write(
      to: sourcesURL.appending(path: "App.swift"),
      atomically: true,
      encoding: .utf8
    )
  }

  private var listingWanderingNoticeText: String {
    """
    You are looping on listings/searches. Stop listing.
    Choose one path from the latest entries or matches and call read_file, or call finish_task with the appropriate status and final summary.
    Do not call list_files, glob_files, or search_files again for broad exploration.
    Only use them again for one specific missing filename.
    """
  }

  private func listingWanderingNotice(in messages: [ProjectedModelContextEntry]) -> String? {
    toolFollowUpNotices(in: messages).first {
      $0.contains("You are looping on listings/searches. Stop listing.")
    }
  }

  private func latestToolFollowUpNotice(
    in capturedMessages: [[ProjectedModelContextEntry]],
    at index: Int
  ) -> String? {
    guard index >= 0, index < capturedMessages.count else {
      return nil
    }
    return capturedMessages[index].reversed().lazy.compactMap { message in
      guard message.role == .tool else {
        return nil
      }
      return toolFollowUpNotice(in: message.content)
    }.first
  }

  private func toolFollowUpNotices(
    in messages: [ProjectedModelContextEntry]
  ) -> [String] {
    messages.compactMap { message in
      guard message.role == .tool else {
        return nil
      }
      return toolFollowUpNotice(in: message.content)
    }
  }

  private func toolFollowUpNotice(in content: String) -> String? {
    guard let range = content.range(of: "TOOL_RESULT_JSON:\n") else {
      return nil
    }
    let remainder = content[range.upperBound...]
    guard let contentRange = remainder.range(of: "\n\nCONTENT:\n") else {
      return nil
    }
    let jsonText = String(remainder[..<contentRange.lowerBound])
    guard let data = jsonText.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let notice = object["next_step"] as? String
    else {
      return nil
    }
    let trimmed = notice.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var finalToolResultNotice: String {
    """
    No more tools are available for this generation. Produce visible final text. Do not call another tool.
    Mention completed changes, affected paths, and run or verification steps if useful.
    Do not include generated file contents, code blocks, diffs, or tool arguments unless the user explicitly asked to display them in chat.
    Never say files were changed unless a successful write_file or edit_file result exists in this turn.
    Failed or invalid write/edit tool results mean no workspace change happened.
    If more work is needed, briefly say what remains and ask the user to send another message.
    """
  }

  private var repeatedRunCommandNotice: String {
    """
    The latest run_command result is already available for this exact command.
    Do not call run_command again with the same command unchanged.
    Use the output to decide the next action, run a different corrected command, or call finish_task with the appropriate status and final summary.
    """
  }

  private var genericToolFollowUpNotice: String {
    "Use this tool result. Call another necessary tool, or finish_task if done."
  }

  private func duplicateReplayNotice(_ toolName: ToolName) -> String {
    """
    The latest \(toolName.rawValue) observation replays a result already available for identical arguments.
    Do not call \(toolName.rawValue) again with the same arguments unchanged.
    Use the replayed observation to answer the original user request, choose a different necessary tool call, or call finish_task with the appropriate status and final summary.
    """
  }

  private func runCommandToolCall(
    _ command: String,
    reason: String? = nil
  ) -> ChatModelStreamEvent {
    var arguments: ToolCallArguments = [
      "command": .string(command),
      "timeoutSeconds": .number(10),
    ]
    if let reason {
      arguments["reason"] = .string(reason)
    }
    return .toolCall(
      ChatRuntimeToolCall(
        name: "run_command",
        arguments: arguments
      ))
  }

  private func writeToolCall(path: String, content: String) -> ChatModelStreamEvent {
    .toolCall(
      ChatRuntimeToolCall(
        name: ToolName.writeFile.rawValue,
        arguments: [
          "path": .string(path),
          "content": .string(content),
        ]
      ))
  }

  private func makeWriteRecord(
    path: String,
    content: String,
    sessionID: ChatSession.ID,
    workspace: Workspace,
    state: ToolCallState
  ) throws -> ToolCallRecord {
    let resolvedPath = try workspace.resolveAllowedPath(path)
    let raw = RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: sessionID,
      toolName: .writeFile,
      arguments: [
        "path": .string(path),
        "content": .string(content),
      ]
    )
    return ToolCallRecord(
      request: .validated(
        raw: raw,
        payload: .writeFile(WriteFileInput(path: path, content: content))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Writing requires approval.",
        riskLevel: .high,
        normalizedPaths: [Workspace.normalizedPath(for: resolvedPath)],
        workspaceRelativePaths: [WorkspaceRelativePath(rawValue: path)]
      ),
      state: state
    )
  }

  private func allowedRunCommandOrchestrator(exitCode: Int32) -> ToolOrchestrator {
    ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([
        AnyToolExecutor(AllowedRunCommandToolExecutor(exitCode: exitCode))
      ])
    )
  }

  private func fixedReadFileOrchestrator(_ result: ReadFileResult) -> ToolOrchestrator {
    ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([
        AnyToolExecutor(ListFilesToolExecutor()),
        AnyToolExecutor(GlobFilesToolExecutor()),
        AnyToolExecutor(SearchFilesToolExecutor()),
        AnyToolExecutor(FixedReadFileToolExecutor(result: result)),
      ])
    )
  }

  private func makeMCPExecutorGroup(
    serverID: UUID,
    serverSlug: String,
    client: any MCPToolCalling
  ) -> MCPAgentToolExecutorGroup {
    MCPAgentToolExecutorGroup(
      serverID: serverID,
      executors: [
        AnyToolExecutor(
          dynamic: MCPToolExecutor(
            serverID: serverID,
            connectionToken: UUID(),
            serverName: serverSlug,
            serverSlug: serverSlug,
            remoteTool: MCPRemoteTool(
              name: "echo",
              description: "Echo a value."
            ),
            client: client
          )
        )
      ]
    )
  }

  private func listFileEventTurns(count: Int) -> [[ChatModelStreamEvent]] {
    (0..<count).map { index in
      let path = index == 0 ? "." : "dir-\(index)"
      return [
        .toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(path)])
        )
      ]
    }
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
}

private actor RecordingMCPToolClient: MCPToolCalling {
  private(set) var callCount = 0

  func callTool(
    serverID: UUID,
    connectionToken: UUID,
    name: String,
    arguments: ToolCallArguments
  ) async throws -> MCPToolResult {
    _ = serverID
    _ = connectionToken
    _ = arguments
    callCount += 1
    return MCPToolResult(
      serverName: "frozen",
      remoteToolName: name,
      content: [.text("ok")],
      isError: false
    )
  }
}

private struct AllowedRunCommandToolExecutor: TypedToolExecutor {
  static let codec = RunCommandToolExecutor.codec

  let exitCode: Int32

  func evaluatePermission(
    _ input: RunCommandInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = (input, context)
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for repeated command guard test.",
      riskLevel: .high,
      workspaceRelativePaths: [WorkspaceRelativePath(rawValue: ".")]
    )
  }

  func run(_ input: RunCommandInput, context: ToolContext) async -> ToolResultPayload {
    _ = context
    return .runCommand(
      RunCommandResult(
        command: input.command,
        timeoutSeconds: input.timeoutSeconds,
        exitCode: exitCode,
        durationMs: 10,
        stdout: ToolTextOutput(text: exitCode == 0 ? "ok\n" : ""),
        stderr: ToolTextOutput(text: exitCode == 0 ? "" : "failed\n")
      ))
  }
}

private struct FixedReadFileToolExecutor: TypedToolExecutor {
  static let codec = ReadFileToolExecutor.codec

  let result: ReadFileResult

  func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for listing wandering guard test.",
      riskLevel: .low,
      workspaceRelativePaths: [WorkspaceRelativePath(rawValue: input.path)]
    )
  }

  func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    _ = (input, context)
    return .readFile(result)
  }
}
