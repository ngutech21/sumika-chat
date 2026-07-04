import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ChatSessionControllerToolLoopTests {
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "read the README repeatedly", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == budget)
    #expect(controller.chatSession.toolCalls.allSatisfy { $0.status == .completed })
    #expect(
      controller.chatSession.testMessages.last?.content
        == "Tool limit reached. I stopped after the recorded file listings.")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == budget + 1)
    #expect(capturedSystemPrompts[1].contains("Available tools:"))
    #expect(capturedSystemPrompts[budget - 1].contains("Available tools:"))
    #expect(capturedSystemPrompts[budget].contains("Available tools:"))
    #expect(!capturedSystemPrompts[budget].contains("No more tools are available"))
    #expect(!capturedSystemPrompts[budget].contains("tool budget"))
    #expect(Set(capturedSystemPrompts).count == 1)

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == budget + 1)
    #expect(capturedPromptPlans[budget].stableInstructions == capturedSystemPrompts[0])
    #expect(capturedPromptPlans[budget].cacheIdentityInstructions == capturedSystemPrompts[0])
    #expect(
      capturedPromptPlans[budget].transientInstructions.contains {
        $0.contains("No more tools are available for this generation")
      })

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == budget + 1)
    #expect(capturedToolContexts[0]?.cacheSystemPrompt == capturedSystemPrompts[0])
    #expect(capturedToolContexts[1]?.cacheSystemPrompt == capturedSystemPrompts[1])
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "read the README repeatedly", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == budget)
    #expect(controller.chatSession.toolCalls.allSatisfy { $0.status == .completed })
    #expect(controller.chatSession.turns.first?.status == .failed)
    #expect(controller.chatSession.turns.first?.modelContextPolicy == .excluded)
    #expect(controller.errorMessage == ChatGenerationError.emptyModelResponse.localizedDescription)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == budget + 1)
    #expect(Set(capturedSystemPrompts).count == 1)
    #expect(!capturedSystemPrompts[budget].contains("No more tools are available"))

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == budget + 1)
    #expect(
      capturedPromptPlans[budget].transientInstructions.contains {
        $0.contains("No more tools are available for this generation")
      })

    let capturedMessages = await runtime.capturedMessages
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "run a failing command", in: workspace, sessionID: sessionID)

    try await waitUntil { controller.hasPendingApproval }
    let pending = try #require(controller.chatSession.toolCalls.first)
    controller.approveToolCall(id: pending.id, in: workspace)

    try await waitUntil { !controller.isGenerating }

    let record = try #require(controller.chatSession.toolCalls.first)
    #expect(record.request.toolName == .runCommand)
    #expect(record.resultPreview?.status == .failed)
    #expect(
      controller.chatSession.testMessages.last?.content.contains(
        "The previous command failed."
      ) == true)
    #expect(controller.chatSession.testMessages.last?.content.contains("completed it") == false)

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 2)
    let notice = try #require(
      capturedPromptPlans[1].transientInstructions.first {
        $0.contains("The previous run_command result in this turn failed.")
      }
    )
    #expect(notice.contains("Command: false"))
    #expect(notice.contains("Exit code: 1"))
    #expect(notice.contains("You MUST NOT report the requested task as complete"))
    #expect(notice.contains("Do not infer workspace state from this failure alone"))
    #expect(!notice.contains("committed"))
  }

  @Test
  func thinkingOnlyResponseWithoutToolCallFailsAndExcludesTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.thinkingChunk("I am reasoning but not answering.")]
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "answer visibly", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.turns.first?.status == .failed)
    #expect(controller.chatSession.turns.first?.modelContextPolicy == .excluded)
    #expect(controller.errorMessage == ChatGenerationError.emptyModelResponse.localizedDescription)
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "inspect the project", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.turns.first?.status == .completed)
    #expect(controller.chatSession.toolCalls.count == 2)
    #expect(controller.chatSession.toolCalls.first?.request.toolName == .listFiles)
    let duplicatePayload = controller.chatSession.toolCalls.last?.resultPayload
    guard case .duplicateToolCall(let duplicate)? = duplicatePayload
    else {
      Issue.record("Expected second tool call to be duplicate observation.")
      return
    }
    #expect(duplicate.previousCallID == controller.chatSession.toolCalls.first?.id)
    #expect(
      controller.chatSession.testMessages.last?.content
        == "Continuing after the duplicate observation.")

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == 3)
    #expect(capturedToolContexts[0] != nil)
    #expect(capturedToolContexts[1] != nil)
    #expect(capturedToolContexts[2] != nil)
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "inspect the project", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.turns.first?.status == .completed)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls.first?.request.toolName == .listFiles)
    #expect(controller.chatSession.testMessages.last?.content == "The project contains README.md.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.role == .assistant && message.content == "I will inspect the project."
      })
    #expect(capturedMessages[1].contains { message in message.role == .tool })
  }

  @Test
  func duplicateOnLastBudgetIterationUsesToolLimitFinalizationPath() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    var eventTurns = (0..<budget).map { _ in
      [
        ChatModelStreamEvent.toolCall(
          ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
        )
      ]
    }
    eventTurns.append([
      .chunk("Tool limit reached. I stopped after the recorded file listings.")
    ])
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: eventTurns)
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "list until the tool budget is exhausted", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.turns.first?.status == .completed)
    #expect(controller.chatSession.toolCalls.count == budget)
    #expect(controller.chatSession.toolCalls.first?.resultPayload?.status == .success)
    let duplicatePayload = controller.chatSession.toolCalls.last?.resultPayload
    guard case .duplicateToolCall(let duplicate)? = duplicatePayload
    else {
      Issue.record("Expected last budget iteration to append duplicate observation.")
      return
    }
    #expect(duplicate.previousCallID == controller.chatSession.toolCalls.first?.id)
    #expect(duplicate.previousCallID != controller.chatSession.toolCalls.dropLast().last?.id)
    #expect(
      controller.chatSession.testMessages.last?.content
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(
      controller.chatSession.todoState?.items.map(\.content) == ["Inspect files", "Run tests"])
    #expect(controller.chatSession.testMessages.last?.content == "Continuing with the plan.")
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

    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "inspect without plan", in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating }

    let promptsAfterSecondAgentTurn = await runtime.capturedSystemPrompts
    #expect(promptsAfterSecondAgentTurn.last?.contains("Current plan:") == false)
    let plansAfterSecondAgentTurn = await runtime.capturedPromptPlans
    #expect(
      plansAfterSecondAgentTurn.last?.transientInstructions.contains {
        $0.contains("Current plan:")
      } == true)
    #expect(controller.chatSession.todoState?.items.count == 2)
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
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false)
      )
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let toolCall = try #require(controller.chatSession.toolCalls.first)
    #expect(toolCall.request.toolName == .todoWrite)
    #expect(toolCall.status == .failed)
    #expect(
      toolCall.resultPayload
        == .invalidTool(
          InvalidToolResult(originalName: "todo_write", reason: .unavailableToolName("todo_write"))
        ))
    #expect(controller.chatSession.todoState == nil)

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
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false)
      )
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }

    controller.configureAgentTools(todoWriteEnabled: true)
    await runtime.releaseStream(callIndex: 0)

    try await waitUntil { !controller.isGenerating }

    let toolCall = try #require(controller.chatSession.toolCalls.first)
    #expect(toolCall.status == .failed)
    #expect(
      toolCall.resultPayload
        == .invalidTool(
          InvalidToolResult(originalName: "todo_write", reason: .unavailableToolName("todo_write"))
        ))
    #expect(controller.chatSession.todoState == nil)

    let capturedToolContexts = await runtime.capturedToolContexts
    let firstToolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(firstToolContext.registry.definition(for: .todoWrite) == nil)

    controller.sendMessage(prompt: "continue", in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating }

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
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: true)
      )
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "make a focused change", in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }

    controller.configureAgentTools(todoWriteEnabled: false)
    await runtime.releaseStream(callIndex: 0)

    try await waitUntil { !controller.isGenerating }

    let toolCall = try #require(controller.chatSession.toolCalls.first)
    #expect(toolCall.status == .completed)
    #expect(
      controller.chatSession.todoState?.items.map(\.content) == ["Inspect files", "Run tests"])

    let capturedToolContexts = await runtime.capturedToolContexts
    let firstToolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(firstToolContext.registry.definition(for: .todoWrite) != nil)

    controller.sendMessage(prompt: "continue", in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating }

    let prompts = await runtime.capturedSystemPrompts
    #expect(prompts.last?.contains("todo_write") == false)
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "implement the feature", in: workspace, sessionID: sessionID)

    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingUserAnswer }

    #expect(!controller.isGenerating)
    #expect(controller.hasPendingUserAnswer)
    #expect(controller.isInputBlocked)
    let record = try #require(controller.chatSession.toolCalls.first)
    #expect(record.request.toolName == .askUser)
    #expect(record.status == .awaitingUserAnswer)

    controller.answerAskUserToolCall(id: record.id, answer: "Minimal fix", in: workspace)

    try await waitUntil { !controller.isGenerating && !controller.hasPendingUserAnswer }

    #expect(controller.chatSession.turns.first?.status == .completed)
    let answeredRecord = try #require(controller.chatSession.toolCalls.first)
    #expect(answeredRecord.status == .completed)
    #expect(answeredRecord.resultPayload == .askUser(AskUserResult(answer: "Minimal fix")))
    #expect(controller.chatSession.testMessages.last?.content == "I'll make the minimal fix.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.role == .tool && message.content.contains("User answered: Minimal fix")
      })
  }

  @Test
  func sendingNewMessageInterruptsPendingAskUserWithoutResumingOldTurn() async throws {
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "implement the feature", in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingUserAnswer }
    let record = try #require(controller.chatSession.toolCalls.first)

    controller.sendMessage(
      prompt: "ignore that question and use the broader refactor", in: workspace,
      sessionID: sessionID)

    try await waitUntil {
      controller.chatSession.turns.count == 2 && !controller.isGenerating
    }

    #expect(controller.chatSession.turns[0].status == .cancelled)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .excluded)
    #expect(controller.chatSession.toolCalls.first?.status == .cancelled)
    #expect(controller.chatSession.turns[1].status == .completed)
    #expect(
      controller.chatSession.testMessages.last?.content == "I will follow the new instruction.")

    controller.answerAskUserToolCall(id: record.id, answer: "Minimal fix", in: workspace)
    await Task.yield()

    #expect(controller.chatSession.toolCalls.first?.status == .cancelled)
    #expect(controller.chatSession.turns[0].status == .cancelled)

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.role == .user
          && message.content.contains("ignore that question and use the broader refactor")
      })
    #expect(
      !capturedMessages[1].contains { message in
        message.role == .user && message.content.contains("User answered:")
      })
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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "replace missing text in README", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 2)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .editFile)
    #expect(controller.chatSession.toolCalls[0].status == .failed)
    #expect(
      controller.chatSession.toolCalls[0].resultPreview?.text.contains("not found") == true)
    #expect(controller.chatSession.toolCalls[1].request.toolName == .readFile)
    #expect(controller.chatSession.toolCalls[1].status == .completed)
    #expect(controller.chatSession.testMessages.last?.content == "The file contains project notes.")

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
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)

    controller.sendMessage(prompt: "read README.md", in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating }

    controller.sendMessage(prompt: "list files", in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating && controller.chatSession.toolCalls.count == 2 }

    #expect(controller.chatSession.turns.count == 2)
    #expect(controller.chatSession.turns.allSatisfy { $0.status == .completed })
    #expect(controller.chatSession.toolCalls.map(\.request.toolName) == [.readFile, .listFiles])
    #expect(controller.chatSession.testMessages.last?.content.contains("Files in `.`:") == true)
    #expect(controller.chatSession.testMessages.last?.content.contains("README.md") == true)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 3)
    #expect(capturedSystemPrompts[2].contains("list_files"))
  }

  @Test
  func repeatedRunCommandAddsTransientRuntimeNoticeAfterThirdCall() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [.chunk("I am blocked on repeated git status output.")],
    ])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 0)
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "check status", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 3)
    #expect(
      controller.chatSession.toolCalls.allSatisfy { record in
        record.request.toolName == .runCommand && record.status == .completed
      })
    #expect(
      controller.chatSession.toolCalls.allSatisfy { record in
        if case .duplicateToolCall = record.resultPayload {
          return false
        }
        return true
      })

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(
      capturedPromptPlans[1].transientInstructions.contains(repeatedRunCommandNotice) == false)
    #expect(
      capturedPromptPlans[2].transientInstructions.contains(repeatedRunCommandNotice) == false)
    #expect(capturedPromptPlans[3].transientInstructions.contains(repeatedRunCommandNotice))
  }

  @Test
  func failedRunCommandResultsCountTowardRepeatedRuntimeNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [runCommandToolCall("git status")],
      [.chunk("The command is still failing.")],
    ])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 1)
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "check status", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 3)
    #expect(
      controller.chatSession.toolCalls.allSatisfy { record in
        guard record.request.toolName == .runCommand,
          case .runCommand(let result)? = record.resultPayload
        else {
          return false
        }
        return result.outcomeStatus == .failed
      })

    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(capturedPromptPlans[3].transientInstructions.contains(repeatedRunCommandNotice))
    #expect(
      capturedPromptPlans[3].transientInstructions.contains {
        $0.contains("The previous run_command result in this turn failed.")
      })
  }

  @Test
  func differentRunCommandArgumentsDoNotAddRepeatedRuntimeNotice() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [runCommandToolCall("git status")],
      [runCommandToolCall("git diff")],
      [runCommandToolCall("git status")],
      [.chunk("I inspected different command outputs.")],
    ])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: allowedRunCommandOrchestrator(exitCode: 0)
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "inspect git state", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 3)
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 4)
    #expect(
      capturedPromptPlans.allSatisfy {
        !$0.transientInstructions.contains(repeatedRunCommandNotice)
      })
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
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: ToolExecutorRegistry([
          AnyToolExecutor(AllowedRunCommandToolExecutor(exitCode: 0)),
          AnyToolExecutor(ListFilesToolExecutor()),
        ])
      )
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "inspect the workspace", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(
      controller.chatSession.toolCalls.map(\.request.toolName) == [
        .runCommand, .runCommand, .runCommand, .listFiles,
      ])
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.count == 5)
    #expect(capturedPromptPlans[3].transientInstructions.contains(repeatedRunCommandNotice))
    #expect(
      capturedPromptPlans[4].transientInstructions.contains(repeatedRunCommandNotice) == false)
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

  private var repeatedRunCommandNotice: String {
    """
    [System Notice]
    You have made the exact same `run_command` call with identical arguments 3+ times in a row.
    Do not keep repeating it. Inspect the output, change the command, or report what is blocking you.
    """
  }

  private func runCommandToolCall(_ command: String) -> ChatModelStreamEvent {
    .toolCall(
      ChatRuntimeToolCall(
        name: "run_command",
        arguments: [
          "command": .string(command),
          "timeoutSeconds": .number(10),
        ]
      ))
  }

  private func allowedRunCommandOrchestrator(exitCode: Int32) -> ToolOrchestrator {
    ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([
        AnyToolExecutor(AllowedRunCommandToolExecutor(exitCode: exitCode))
      ])
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
