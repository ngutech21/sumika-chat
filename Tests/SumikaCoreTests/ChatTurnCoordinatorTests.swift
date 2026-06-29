import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ChatTurnCoordinatorTests {
  @Test
  func userTurnStreamsAssistantReplyAndCompletes() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello"])
    let harness = ChatTurnCoordinatorHarness(
      session: ChatSession(interactionMode: .chat),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "say hello")

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
    let harness = ChatTurnCoordinatorHarness(
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
    let harness = ChatTurnCoordinatorHarness(
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
    let harness = ChatTurnCoordinatorHarness(
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
    let harness = ChatTurnCoordinatorHarness(
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
  func cancelActiveTurnMarksTurnCancelledAndRemovesTransientPlaceholder() async throws {
    let runtime = ControlledStreamingRuntime(turns: [["partial"]], blockedCallIndexes: [0])
    let harness = ChatTurnCoordinatorHarness(
      session: ChatSession(interactionMode: .chat),
      runtime: runtime
    )

    harness.startUserTurn(prompt: "wait")
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }

    harness.cancel()

    try await waitUntil { harness.finishCount == 1 }

    #expect(harness.session.turns.first?.status == .cancelled)
    #expect(harness.session.testMessages.map(\.kind) == [.user])
  }
}

@MainActor
private final class ChatTurnCoordinatorHarness: @unchecked Sendable {
  var session: ChatSession
  var finishCount = 0
  var errorMessages: [String] = []

  private let applier = ChatWorkflowEventApplier()
  private let coordinator = ChatTurnCoordinator()
  private let operationID = UUID()
  private let runtimeContextClearCoordinator: RuntimeContextClearCoordinator
  private let chatGenerationCoordinator: ChatGenerationCoordinator
  private var toolLoopCoordinator: ToolLoopCoordinator
  private var toolOrchestrator = ToolOrchestrator(executorRegistry: .codingAgent)

  init(session: ChatSession, runtime: any ChatModelRuntime) {
    self.session = session
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: operationID
    )
    let modelLifecycleCoordinator = ModelLifecycleCoordinator(
      modelDownloader: UnavailableModelDownloader(),
      runtimeOperations: runtimeOperations,
      modelAvailability: { _ in true }
    )
    self.runtimeContextClearCoordinator = RuntimeContextClearCoordinator(
      modelLifecycleCoordinator: modelLifecycleCoordinator
    )
    self.chatGenerationCoordinator = ChatGenerationCoordinator(
      runtimeOperations: runtimeOperations,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    self.toolLoopCoordinator = ToolLoopCoordinator(agentToolOrchestrator: toolOrchestrator)
  }

  func startUserTurn(
    prompt: String,
    workspace: Workspace? = nil,
    sessionID: ChatSession.ID? = nil
  ) {
    coordinator.startUserTurn(
      prompt: prompt,
      workspace: workspace,
      sessionID: sessionID,
      attachments: [],
      runtime: runtimeContext(),
      runtimeContextClearCoordinator: runtimeContextClearCoordinator,
      callbacks: callbacks()
    )
  }

  func approve(_ record: ToolCallRecord, in workspace: Workspace) {
    guard let turnID = session.turnID(containingToolCall: record.id) else {
      return
    }
    coordinator.approveToolCall(
      record,
      in: workspace,
      turnID: turnID,
      toolOrchestrator: toolOrchestrator,
      runtime: runtimeContext(),
      callbacks: callbacks()
    )
  }

  func answer(_ record: ToolCallRecord, answer: String, in workspace: Workspace) {
    guard let turnID = session.turnID(containingToolCall: record.id) else {
      return
    }
    coordinator.answerAskUserToolCall(
      record,
      answer: answer,
      in: workspace,
      turnID: turnID,
      runtime: runtimeContext(),
      callbacks: callbacks()
    )
  }

  func deny(_ record: ToolCallRecord) {
    guard let turnID = session.turnID(containingToolCall: record.id) else {
      return
    }
    coordinator.denyToolCall(
      record,
      message: "Tool call denied by user.",
      turnID: turnID,
      runtime: runtimeContext(),
      callbacks: callbacks()
    )
  }

  func cancel() {
    coordinator.cancelActiveTurn(
      emitEvents: { [weak self] events in self?.emit(events) },
      turnDidFinish: { [weak self] _, _ in self?.finishCount += 1 },
      notifySessionDidChange: {}
    )
  }

  private func emit(_ events: [ChatWorkflowEvent]) {
    applier.apply(events, to: &session)
  }

  private func runtimeContext() -> ChatTurnRuntimeContext {
    ChatTurnRuntimeContext(
      selectedModel: ManagedModelCatalog.defaultModel,
      operationID: operationID,
      chatGenerationCoordinator: chatGenerationCoordinator,
      toolLoopCoordinator: toolLoopCoordinator
    )
  }

  private func callbacks() -> ChatTurnCallbacks {
    ChatTurnCallbacks(
      session: { [weak self] in self?.session ?? .defaultSession },
      emitEvents: { [weak self] events in self?.emit(events) },
      setActiveToolPromptMode: { _ in },
      updateRuntimeCacheDebugSnapshot: { _ in },
      refreshContextUsage: { _ in },
      setErrorMessage: { [weak self] message in self?.errorMessages.append(message) },
      turnDidFinish: { [weak self] _, _ in self?.finishCount += 1 },
      notifySessionDidChange: {}
    )
  }
}

private func makeWorkspace(sessionID: ChatSession.ID) throws -> Workspace {
  let rootURL = FileManager.default.temporaryDirectory.appending(
    path: "sumika-chat-tests-\(UUID().uuidString)",
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
