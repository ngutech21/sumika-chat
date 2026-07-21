import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ConversationEngineLifecycleTests {
  @Test
  func userTurnStreamsAssistantReplyAndCompletes() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello"])
    let session = ChatSession(interactionMode: .chat)
    let workspace = try makeConversationTestWorkspace(containing: session)
    let harness = ConversationEngineLifecycleHarness(
      session: session,
      runtime: runtime
    )

    harness.startUserTurn(prompt: "say hello", workspace: workspace, sessionID: session.id)

    try await waitUntil { harness.finishCount == 1 }

    #expect(harness.session.turns.first?.status == .completed)
    #expect(harness.session.testMessages.map(\.content) == ["say hello", "hello"])
    #expect(harness.session.testMessages.last?.deliveryStatus == .complete)
  }

  @Test
  func toolLoopPausesAtWriteApproval() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("index.html"),
              "content": .string("<h1>Hello</h1>"),
            ]
          ))
      ]
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "write a page", workspace: workspace, sessionID: sessionID)

    try await waitUntil { harness.session.turns.first?.status == .awaitingApproval }

    #expect(harness.finishCount == 1)
    #expect(harness.session.toolCalls.first?.status == .awaitingApproval)
    let outputURL = workspace.rootURL.appending(path: "index.html")
    #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
  }

  @Test
  func approvedWriteFileResumesAndCompletes() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let htmlContent = "<h1>Hello</h1>"
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("index.html"),
              "content": .string(htmlContent),
            ]
          ))
      ],
      [.chunk("Wrote index.html.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "write a page", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.session.turns.first?.status == .awaitingApproval }
    let record = try #require(harness.session.toolCalls.first)

    harness.approve(record, in: workspace)

    try await waitUntil { harness.session.turns.first?.status == .completed }

    let outputURL = workspace.rootURL.appending(path: "index.html")
    #expect(try String(contentsOf: outputURL, encoding: .utf8) == htmlContent)
    #expect(harness.session.toolCalls.first?.status == .completed)
    #expect(harness.session.testMessages.last?.content == "Wrote index.html.")
    let toolContexts = await runtime.capturedToolContexts
    #expect(toolContexts.count == 2)
    #expect(toolContexts[1] != nil)
  }

  @Test
  func askUserAnswerResumesAndCompletes() async throws {
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
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(
      prompt: "implement the feature", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.session.turns.first?.status == .awaitingUserAnswer }
    let record = try #require(harness.session.toolCalls.first)

    harness.answer(record, answer: "Minimal fix", in: workspace)

    try await waitUntil { harness.session.turns.first?.status == .completed }

    #expect(harness.session.toolCalls.first?.status == .completed)
    #expect(
      harness.session.toolCalls.first?.resultPayload
        == .askUser(AskUserResult(answer: "Minimal fix")))
    #expect(harness.session.testMessages.last?.content == "I'll make the minimal fix.")
  }

  @Test
  func denyToolCallResumesWithFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "edit_file",
            arguments: [
              "path": .string("README.md"),
              "old_text": .string("project notes"),
              "new_text": .string("updated notes"),
            ]
          ))
      ],
      [.chunk("I will leave README.md unchanged.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "update the readme", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.session.turns.first?.status == .awaitingApproval }
    let record = try #require(harness.session.toolCalls.first)

    harness.deny(record)

    try await waitUntil { harness.session.turns.first?.status == .completed }

    let readmeURL = workspace.rootURL.appending(path: "README.md")
    #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "project notes")
    #expect(harness.session.toolCalls.first?.status == .denied)
    #expect(harness.session.testMessages.last?.content == "I will leave README.md unchanged.")
  }

  @Test
  func multipleApprovalsWaitForEveryDecisionAndKeepModelOrder() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("first.txt"),
              "content": .string("first"),
            ]
          )),
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("second.txt"),
              "content": .string("second"),
            ]
          )),
      ],
      [.chunk("Applied the approved change and left the denied file untouched.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "write both files", workspace: workspace, sessionID: sessionID)
    try await waitUntil {
      harness.session.toolCalls.count == 2
        && harness.session.toolCalls.allSatisfy { $0.status == .awaitingApproval }
    }
    let second = harness.session.toolCalls[1]

    harness.approve(second, in: workspace)
    try await waitUntil {
      harness.session.turns.first?.status == .awaitingApproval
        && harness.session.toolCalls.map(\.status) == [.awaitingApproval, .completed]
    }

    #expect(await runtime.capturedMessages.count == 1)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "second.txt"),
        encoding: .utf8
      ) == "second")
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "first.txt").path))

    let first = harness.session.toolCalls[0]
    harness.deny(first)
    try await waitUntil { harness.session.turns.first?.status == .completed }

    #expect(harness.session.toolCalls.map(\.id) == [first.id, second.id])
    #expect(harness.session.toolCalls.map(\.status) == [.denied, .completed])
    guard case .failure(let denial)? = harness.session.toolCalls[0].resultPayload else {
      Issue.record("Expected a user-denied result for the first call.")
      return
    }
    #expect(denial.reason == .userDenied)
    let followUpMessages = await runtime.capturedMessages
    #expect(followUpMessages.count == 2)
    let toolMessages = followUpMessages[1].filter { $0.role == .tool }
    #expect(toolMessages.count == 2)
    #expect(toolMessages[0].content.contains("Tool call denied by user."))
    #expect(toolMessages[1].content.contains("Wrote 6 bytes to second.txt."))
  }

  @Test
  func approveAllExecutesInModelOrderAndGeneratesOnce() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("one.txt"),
              "content": .string("one"),
            ]
          )),
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("two.txt"),
              "content": .string("two"),
            ]
          )),
      ],
      [.chunk("Wrote both files.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "write both files", workspace: workspace, sessionID: sessionID)
    try await waitUntil {
      harness.session.toolCalls.count == 2
        && harness.session.toolCalls.allSatisfy { $0.status == .awaitingApproval }
    }

    harness.approveBatch(containing: harness.session.toolCalls[0], in: workspace)
    try await waitUntil { harness.session.turns.first?.status == .completed }

    #expect(harness.session.toolCalls.map(\.status) == [.completed, .completed])
    #expect(await runtime.capturedMessages.count == 2)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "one.txt"), encoding: .utf8)
        == "one")
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "two.txt"), encoding: .utf8)
        == "two")
  }

  @Test
  func approveAllContinuesAfterFailureAndGeneratesOnce() async throws {
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
              "reason": .string("Verify failure handling."),
            ]
          )),
        .toolCall(
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: [
              "command": .string("true"),
              "timeoutSeconds": .number(1),
              "reason": .string("Verify sibling continuation."),
            ]
          )),
      ],
      [.chunk("Ran both approved commands and reported the failure.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "run both checks", workspace: workspace, sessionID: sessionID)
    try await waitUntil {
      harness.session.toolCalls.count == 2
        && harness.session.toolCalls.allSatisfy { $0.status == .awaitingApproval }
    }
    harness.approveBatch(containing: harness.session.toolCalls[0], in: workspace)
    try await waitUntil { harness.session.turns.first?.status == .completed }

    #expect(harness.session.toolCalls.map(\.status) == [.failed, .completed])
    #expect(await runtime.capturedMessages.count == 2)
    let followUp = await runtime.capturedMessages[1]
    #expect(followUp.filter { $0.role == .tool }.count == 2)
  }

  @Test
  func approvalBatchWithBlockedDuplicateForcesFinalFollowUp() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let listCall = ChatModelStreamEvent.toolCall(
      ChatRuntimeToolCall(name: "list_files", arguments: ["path": .string(".")])
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [listCall],
      [listCall],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: [
              "command": .string("true"),
              "timeoutSeconds": .number(1),
              "reason": .string("Verify the workspace state."),
            ]
          )),
        listCall,
        listCall,
      ],
      [.chunk("Stopped after the blocked duplicate observation.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(
      prompt: "inspect the workspace",
      workspace: workspace,
      sessionID: sessionID
    )
    try await waitUntil {
      harness.session.turns.first?.status == .awaitingApproval
        && harness.session.toolCalls.count == 5
    }
    let command = harness.session.toolCalls[2]
    guard
      case .duplicateToolCall(let duplicate)? = harness.session.toolCalls.last?.resultPayload
    else {
      Issue.record("Expected the final batch record to be a duplicate observation.")
      return
    }
    #expect(duplicate.blocked)

    harness.approve(command, in: workspace)
    try await waitUntil { harness.session.turns.first?.status == .completed }

    let toolContexts = await runtime.capturedToolContexts
    #expect(toolContexts.count == 4)
    #expect(toolContexts[3] == nil)
    #expect(
      harness.session.testMessages.last?.content
        == "Stopped after the blocked duplicate observation.")
  }

  @Test
  func denialBeforeSiblingApprovalStillWaitsAndKeepsModelOrder() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: ["path": .string("first.txt"), "content": .string("first")]
          )),
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: ["path": .string("second.txt"), "content": .string("second")]
          )),
      ],
      [.chunk("Wrote only the approved file.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "write both files", workspace: workspace, sessionID: sessionID)
    try await waitUntil {
      harness.session.toolCalls.count == 2
        && harness.session.toolCalls.allSatisfy { $0.status == .awaitingApproval }
    }
    harness.deny(harness.session.toolCalls[0])
    try await waitUntil {
      harness.session.toolCalls.map(\.status) == [.denied, .awaitingApproval]
        && harness.session.turns.first?.status == .awaitingApproval
    }
    #expect(await runtime.capturedMessages.count == 1)

    harness.approve(harness.session.toolCalls[1], in: workspace)
    try await waitUntil { harness.session.turns.first?.status == .completed }

    #expect(harness.session.toolCalls.map(\.status) == [.denied, .completed])
    let followUp = await runtime.capturedMessages[1]
    #expect(followUp.filter { $0.role == .tool }.count == 2)
    #expect(followUp.first { $0.role == .tool }?.content.contains("user_denied") == true)
  }

  @Test
  func thinkingCompletesWhenFirstVisibleChunkArrives() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .thinkingChunk("Weighing the candidate answers."),
        .chunk("Here is the answer."),
      ]
    ])
    let session = ChatSession(interactionMode: .chat)
    let workspace = try makeConversationTestWorkspace(containing: session)
    let harness = ConversationEngineLifecycleHarness(
      session: session,
      runtime: runtime
    )

    harness.startUserTurn(
      prompt: "explain the tradeoff",
      workspace: workspace,
      sessionID: session.id
    )

    try await waitUntil { harness.finishCount == 1 }

    let thinkingMessage = harness.session.turns.first?.items
      .compactMap { item -> AssistantThinkingMessage? in
        if case .assistantThinking(let message) = item {
          return message
        }
        return nil
      }.first
    #expect(thinkingMessage?.deliveryStatus == .complete)
    #expect(thinkingMessage?.startedAt != nil)
    #expect(thinkingMessage?.completedAt != nil)
    #expect(thinkingMessage?.reasoningDuration != nil)
  }

  @Test
  func cancelActiveTurnMarksTurnCancelledAndRemovesTransientPlaceholder() async throws {
    let runtime = ControlledStreamingRuntime(turns: [["partial"]], blockedCallIndexes: [0])
    let session = ChatSession(interactionMode: .chat)
    let workspace = try makeConversationTestWorkspace(containing: session)
    let harness = ConversationEngineLifecycleHarness(
      session: session,
      runtime: runtime
    )

    harness.startUserTurn(prompt: "wait", workspace: workspace, sessionID: session.id)
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }

    harness.cancel()

    try await waitUntil { harness.finishCount == 1 }

    #expect(harness.session.turns.first?.status == .cancelled)
    #expect(harness.session.testMessages.map(\.kind) == [.user])
  }

  @Test
  func agentTurnsLoadWorkspaceInstructionsBeforeTheModelRequestWithoutDuplicatingThem() async throws
  {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let loader = WorkspaceInstructionsLoaderStub(
      result: .found(
        WorkspaceInstructionsDocument(
          path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
          contentHash: "rules-hash",
          content: "Use just test-core."
        )
      )
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("First response.")],
      [.chunk("Second response.")],
    ])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime,
      workspaceInstructionsLoader: loader
    )

    harness.startUserTurn(prompt: "First", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.finishCount == 1 }
    harness.startUserTurn(prompt: "Second", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.finishCount == 2 }

    let userMessages: [UserTurnMessage] = harness.session.turns.flatMap(\.items).compactMap {
      item in
      guard case .userMessage(let message) = item else {
        return nil
      }
      return message
    }
    let requests = await runtime.capturedMessages

    #expect(await loader.loadCount == 2)
    #expect(userMessages.count == 2)
    #expect(userMessages[0].promptContext.workspaceInstructions.count == 1)
    #expect(userMessages[1].promptContext.workspaceInstructions.isEmpty)
    #expect(requests.count == 2)
    #expect(requests[0].map(\.content).joined().contains("Use just test-core."))
    #expect(
      requests[1].map(\.content).joined()
        .components(separatedBy: "Workspace instructions:").count == 2
    )
  }

  @Test
  func chatModeNeverLoadsWorkspaceInstructions() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let loader = WorkspaceInstructionsLoaderStub(result: .missing)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["Reply."])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .chat),
      runtime: runtime,
      workspaceInstructionsLoader: loader
    )

    harness.startUserTurn(prompt: "Chat", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.finishCount == 1 }

    #expect(await loader.loadCount == 0)
    #expect(await runtime.capturedMessages.count == 1)
  }

  @Test
  func invalidWorkspaceSessionAssociationNeverLoadsWorkspaceInstructions() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let loader = WorkspaceInstructionsLoaderStub(result: .missing)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["Reply."])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime,
      workspaceInstructionsLoader: loader
    )

    #expect(
      !harness.startUserTurn(
        prompt: "Agent",
        workspace: workspace,
        sessionID: UUID()
      ))

    #expect(harness.finishCount == 0)
    #expect(harness.errorMessages == ["The active chat session does not belong to the workspace."])
    #expect(await loader.loadCount == 0)
    #expect(await runtime.capturedMessages.isEmpty)
  }

  @Test
  func workspaceInstructionsLoadFailureExcludesTurnWithoutModelRequest() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let loader = WorkspaceInstructionsLoaderStub(
      result: .missing,
      error: .invalidUTF8("AGENTS.md")
    )
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["Must not be requested."])
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime,
      workspaceInstructionsLoader: loader
    )

    harness.startUserTurn(prompt: "Implement", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.finishCount == 1 }

    #expect(await loader.loadCount == 1)
    #expect(await runtime.capturedMessages.isEmpty)
    #expect(harness.session.turns.first?.status == .failed)
    #expect(harness.session.turns.first?.modelContextPolicy == .excluded)
    #expect(harness.errorMessages == ["Workspace instructions are not valid UTF-8: AGENTS.md."])
  }

  @Test
  func cancelledSnapshotTurnDoesNotPreventReinjectionOnNextTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let loader = WorkspaceInstructionsLoaderStub(
      result: .found(
        WorkspaceInstructionsDocument(
          path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
          contentHash: String(repeating: "a", count: 64),
          content: "Stable rules"
        )
      )
    )
    let runtime = ControlledStreamingRuntime(
      turns: [["Cancelled"], ["Completed"]],
      blockedCallIndexes: [0]
    )
    let harness = ConversationEngineLifecycleHarness(
      session: ChatSession(id: sessionID, interactionMode: .agent),
      runtime: runtime,
      workspaceInstructionsLoader: loader
    )

    harness.startUserTurn(prompt: "First", workspace: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }
    harness.cancel()
    try await waitUntil { harness.finishCount == 1 }
    harness.startUserTurn(prompt: "Second", workspace: workspace, sessionID: sessionID)
    try await waitUntil { harness.finishCount == 2 }

    let userMessages: [UserTurnMessage] = harness.session.turns.flatMap(\.items).compactMap {
      item in
      guard case .userMessage(let message) = item else {
        return nil
      }
      return message
    }
    let requests = await runtime.capturedMessages

    #expect(harness.session.turns[0].modelContextPolicy == .excluded)
    #expect(userMessages.map { $0.promptContext.workspaceInstructions.count } == [1, 1])
    #expect(await loader.loadCount == 2)
    #expect(requests.count == 2)
    #expect(
      requests[1].map(\.content).joined()
        .components(separatedBy: "Workspace instructions:").count == 2
    )
  }
}

@MainActor
private final class ConversationEngineLifecycleHarness: @unchecked Sendable {
  private let engine: ConversationEngine
  var finishCount = 0
  private var wasGenerating = false

  var session: ChatSession {
    engine.chatSession
  }

  var errorMessages: [String] {
    engine.errorMessage.map { [$0] } ?? []
  }

  init(
    session: ChatSession,
    runtime: any ChatModelRuntime,
    workspaceInstructionsLoader: any WorkspaceInstructionsLoading = WorkspaceInstructionsLoader()
  ) {
    self.engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: session,
      workspaceInstructionsLoader: workspaceInstructionsLoader
    )
    engine.modelRuntime.modelState = .ready
    engine.setSessionChangeHandler { [weak self] in
      self?.recordLifecycleTransition()
    }
  }

  @discardableResult
  func startUserTurn(
    prompt: String,
    workspace: Workspace,
    sessionID: ChatSession.ID
  ) -> Bool {
    engine.sendMessage(prompt: prompt, in: workspace, sessionID: sessionID)
  }

  func approve(_ record: ToolCallRecord, in workspace: Workspace) {
    engine.approveToolCall(id: record.id, in: workspace)
  }

  func approveBatch(containing record: ToolCallRecord, in workspace: Workspace) {
    engine.approveToolCallBatch(containing: record.id, in: workspace)
  }

  func answer(_ record: ToolCallRecord, answer: String, in workspace: Workspace) {
    engine.answerAskUserToolCall(id: record.id, answer: answer, in: workspace)
  }

  func deny(_ record: ToolCallRecord) {
    engine.denyToolCall(id: record.id)
  }

  func cancel() {
    engine.cancelGeneration()
  }

  private func recordLifecycleTransition() {
    if wasGenerating, !engine.isGenerating {
      finishCount += 1
    }
    wasGenerating = engine.isGenerating
  }
}

private actor WorkspaceInstructionsLoaderStub: WorkspaceInstructionsLoading {
  let result: WorkspaceInstructionsLoadResult
  let error: WorkspaceInstructionsLoadingError?
  private(set) var loadCount = 0

  init(
    result: WorkspaceInstructionsLoadResult,
    error: WorkspaceInstructionsLoadingError? = nil
  ) {
    self.result = result
    self.error = error
  }

  func loadInstructions(
    from workspace: Workspace
  ) async throws -> WorkspaceInstructionsLoadResult {
    _ = workspace
    loadCount += 1
    if let error {
      throw error
    }
    return result
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

@MainActor
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

@MainActor
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
