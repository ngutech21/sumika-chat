import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ConversationEngineWriteApprovalTests {
  @Test
  func nativeWriteFileToolCallWaitsForApprovalWithoutWriting() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string("<!doctype html>\n<html>Movies</html>\n"),
            ]
          ))
      ]
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)

    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingApproval }

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(!engine.isGenerating)
    #expect(engine.hasPendingApproval)
    #expect(engine.chatSession.toolCalls.count == 1)
    #expect(engine.chatSession.toolCalls[0].status == .awaitingApproval)
    #expect(engine.chatSession.toolCalls[0].request.toolName == .writeFile)
    #expect(engine.chatSession.testMessages.count == 2)
    #expect(engine.chatSession.testMessages[1].kind == .toolCall)
    #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
  }

  @Test
  func pendingApprovalBlocksCanSend() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string("<!doctype html>\n<html>Movies</html>\n"),
            ]
          ))
      ]
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)
    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingApproval }

    #expect(engine.hasPendingApproval)
    #expect(!engine.canSend(prompt: "skip that and explain the current state"))
  }

  @Test
  func sendingNewMessageDoesNotInterruptPendingApproval() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string("<!doctype html>\n<html>Movies</html>\n"),
            ]
          ))
      ],
      [.chunk("I will explain the current state instead.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)
    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingApproval }
    #expect(
      !engine.sendMessage(
        prompt: "skip that and explain the current state",
        in: workspace,
        sessionID: sessionID
      ))

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
    #expect(engine.chatSession.turns.count == 1)
    #expect(engine.chatSession.turns[0].status == .awaitingApproval)
    #expect(engine.chatSession.toolCalls.first?.status == .awaitingApproval)

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 1)
  }

  @Test
  func approvingNativeWriteFileWritesContentAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let htmlContent = "<!doctype html>\n<html>Movies</html>\n"
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string(htmlContent),
            ]
          ))
      ],
      [.chunk("Updated movies.html.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)
    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(engine.chatSession.toolCalls.first?.id)

    engine.approveToolCall(id: toolCallID, in: workspace)

    try await waitUntil { engine.chatSession.turns.first?.status == .completed }

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(try String(contentsOf: outputURL, encoding: .utf8) == htmlContent)
    #expect(!engine.isGenerating)
    #expect(!engine.hasPendingApproval)
    #expect(engine.chatSession.toolCalls[0].status == .completed)
    #expect(engine.chatSession.toolCalls[0].approvalSource == .manual)
    #expect(engine.chatSession.toolCalls[0].resultPreview?.status == .success)
    #expect(engine.chatSession.testMessages.count == 3)
    #expect(engine.chatSession.testMessages[1].kind == .toolResult)
    #expect(engine.chatSession.testMessages[1].toolCall?.toolName == .writeFile)
    #expect(engine.chatSession.testMessages[1].toolResult?.toolName == .writeFile)
    #expect(engine.chatSession.testMessages[2].content == "Updated movies.html.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(capturedMessages.last?.last?.content.contains("No more tools are available") == false)
    #expect(capturedMessages.last?.last?.role == .tool)
    #expect(capturedMessages.last?.last?.content.contains("Wrote") == true)
    #expect(
      capturedMessages.last?.last?.content.contains("Use this tool result")
        == true)
    #expect(
      capturedMessages.last?.last?.content.contains("Do not include generated file contents")
        == false)
    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.last?.contains("No more tools may run") == false)
    #expect(
      capturedSystemPrompts.last?.contains("Do not include generated file contents")
        == false)
    #expect(
      capturedSystemPrompts.last?.contains("Never claim a change without a successful result")
        == true)
    #expect(
      capturedSystemPrompts.last?.contains("a failed or invalid result means no change") == true)
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.last?.transientInstructions.isEmpty == true)
    #expect(capturedPromptPlans.last?.toolContext != nil)
  }

  @Test
  func automaticApprovalExecutesWriteAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let content = "approved automatically\n"
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("automatic.txt"),
              "content": .string(content),
            ]
          ))
      ],
      [.chunk("Updated automatic.txt.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.enableAutomaticToolApproval(in: workspace)

    engine.sendMessage(
      prompt: "create the file", in: workspace, sessionID: sessionID)

    try await waitUntil { engine.chatSession.turns.first?.status == .completed }

    let record = try #require(engine.chatSession.toolCalls.first)
    #expect(record.status == .completed)
    #expect(record.approvalSource == .automatic)
    #expect(!engine.hasPendingApproval)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "automatic.txt"),
        encoding: .utf8
      ) == content
    )
  }

  @Test
  func cancellingAutomaticApprovalPersistsFinishedToolAndDoesNotStartNextTool() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let processRunner = ControlledCommandProcessRunner()
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        runCommandToolCall("first"),
        runCommandToolCall("second"),
      ]
    ])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: ToolExecutorRegistry([
          AnyToolExecutor(RunCommandToolExecutor(processRunner: processRunner))
        ])
      )
    )
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.enableAutomaticToolApproval(in: workspace)

    engine.sendMessage(
      prompt: "run both commands", in: workspace, sessionID: sessionID)

    try await waitUntilAsync { await processRunner.startedCount == 1 }
    #expect(
      engine.chatSession.toolCalls.map(\.status) == [
        .awaitingApproval, .awaitingApproval,
      ])

    engine.cancelGeneration()
    await processRunner.releaseFirst()

    try await waitUntilAsync {
      await processRunner.startedCount > 1
        || engine.chatSession.toolCalls.first?.status == .completed
    }

    let records = engine.chatSession.toolCalls
    #expect(records.map(\.status) == [.completed, .awaitingApproval])
    #expect(records.map(\.approvalSource) == [.automatic, nil])
    #expect(await processRunner.startedCount == 1)
    #expect(engine.chatSession.turns.first?.status == .cancelled)

    await processRunner.releaseAll()
  }

  @Test
  func enablingAutomaticApprovalResumesExistingPendingBatch() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("resumed.txt"),
              "content": .string("resumed\n"),
            ]
          ))
      ],
      [.chunk("Resumed the automation.")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "create the file", in: workspace, sessionID: sessionID)
    try await waitUntil { engine.hasPendingApproval }

    engine.enableAutomaticToolApproval(in: workspace)

    try await waitUntil { engine.chatSession.turns.first?.status == .completed }
    #expect(engine.chatSession.toolApprovalPolicy == .automatic)
    #expect(engine.chatSession.toolCalls.first?.approvalSource == .automatic)
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "resumed.txt").path
      )
    )
  }

  @Test
  func disablingAutomaticApprovalPausesBeforeNextUnstartedPendingTool() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("first.txt"),
              "content": .string("first\n"),
            ]
          )),
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("second.txt"),
              "content": .string("second\n"),
            ]
          )),
      ]
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "create both files", in: workspace, sessionID: sessionID)
    try await waitUntil {
      engine.chatSession.toolCalls.count == 2 && engine.hasPendingApproval
    }

    var didDisable = false
    engine.setSessionChangeHandler {
      guard !didDisable,
        engine.chatSession.toolCalls.first?.status == .completed
      else {
        return
      }
      didDisable = true
      engine.disableAutomaticToolApproval()
    }

    engine.enableAutomaticToolApproval(in: workspace)

    try await waitUntil { !engine.isGenerating && didDisable }
    let records = engine.chatSession.toolCalls
    #expect(engine.chatSession.toolApprovalPolicy == .manual)
    #expect(records.map(\.status) == [.completed, .awaitingApproval])
    #expect(records.map(\.approvalSource) == [.automatic, nil])
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "first.txt").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "second.txt").path
      )
    )
  }

  @Test
  func loadingAutomaticSessionDoesNotExecutePersistedPendingApproval() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let pendingRecord = await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: RawToolCallRequest(
        workspaceID: workspace.id,
        sessionID: sessionID,
        toolName: .writeFile,
        arguments: [
          "path": .string("must-wait.txt"),
          "content": .string("not on load\n"),
        ]
      ),
      workspace: workspace
    )
    let session = ChatSession(
      id: sessionID,
      turns: [
        ChatTurn(
          status: .awaitingApproval,
          items: [.tool(pendingRecord)]
        )
      ],
      interactionMode: .agent,
      toolApprovalPolicy: .automatic
    )
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    engine.loadSession(session)
    await Task.yield()

    #expect(engine.chatSession.toolApprovalPolicy == .automatic)
    #expect(engine.hasPendingApproval)
    #expect(!engine.isGenerating)
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "must-wait.txt").path
      )
    )
  }

  @Test
  func denyingNativeEditFileDoesNotWriteAndAllowsFinalAssistantResponse() async throws {
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    try engine.loadSession(from: workspace, sessionID: sessionID)
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "update the readme", in: workspace, sessionID: sessionID)
    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(engine.chatSession.toolCalls.first?.id)

    engine.denyToolCall(id: toolCallID)
    try await waitUntil { !engine.isGenerating }

    let readmeURL = workspace.rootURL.appending(path: "README.md")
    #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "project notes")
    #expect(!engine.hasPendingApproval)
    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(engine.chatSession.toolCalls[0].status == .denied)
    #expect(engine.chatSession.toolCalls[0].resultPreview?.affectedPaths == ["README.md"])
    #expect(engine.chatSession.testMessages.count == 3)
    #expect(engine.chatSession.testMessages[1].toolResult?.preview.status == .denied)
    #expect(engine.chatSession.testMessages[2].content == "I will leave README.md unchanged.")
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
    condition: @escaping @MainActor () async -> Bool
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

  private func runCommandToolCall(_ command: String) -> ChatModelStreamEvent {
    .toolCall(
      ChatRuntimeToolCall(
        name: ToolName.runCommand.rawValue,
        arguments: [
          "command": .string(command),
          "timeoutSeconds": .number(10),
        ]
      ))
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

private actor ControlledCommandProcessRunner: CommandProcessRunning {
  private var requests: [CommandProcessRequest] = []
  private var continuations: [CheckedContinuation<Void, Never>] = []

  var startedCount: Int {
    requests.count
  }

  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    requests.append(request)
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    return CommandProcessResult(
      exitCode: Task.isCancelled ? nil : 0,
      durationMs: 1,
      stdout: "",
      stderr: "",
      cancelled: Task.isCancelled
    )
  }

  func releaseFirst() {
    guard !continuations.isEmpty else {
      return
    }
    continuations.removeFirst().resume()
  }

  func releaseAll() {
    let pendingContinuations = continuations
    continuations.removeAll()
    for continuation in pendingContinuations {
      continuation.resume()
    }
  }
}
