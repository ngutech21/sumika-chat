import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(.serialized, TemporaryDirectoryTrait(named: "run-command-batch"))
@MainActor
struct RunCommandBatchTests {
  @Test(arguments: [Int32(0), Int32(1)])
  func automaticApprovalExecutesIdenticalCommandsOnce(exitCode: Int32) async throws {
    let runner = BatchCommandProcessRunner(exitCode: exitCode)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("check"), command("check"), command("check")],
      [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()

    await engine.sendMessage(
      prompt: "run the check", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }

    #expect(await runner.requests.count == 1)
    let records = engine.chatSession.toolCalls
    #expect(records.count == 3)
    for record in records.dropFirst() {
      #expect(record.resultPayload == .runCommandDuplicate(.init(originalCallID: records[0].id)))
      #expect(record.approvalSource == nil)
    }
    #expect(await runtime.capturedMessages.count == 2)
    let observations = await runtime.capturedMessages[1].filter { $0.role == .tool }
    #expect(observations.count == 3)
    let duplicateJSON = try controlJSON(observations[1].content)
    #expect(duplicateJSON["kind"] as? String == "duplicate_in_batch")
    #expect(duplicateJSON["status"] as? String == "failed")
    #expect(duplicateJSON["duplicate"] as? Bool == true)
    #expect(duplicateJSON["not_executed"] as? Bool == true)
    #expect(
      duplicateJSON["duplicate_of"] as? String == RuntimeToolCallID.string(for: records[0].id))
    #expect(duplicateJSON["exit_code"] == nil)
    #expect(duplicateJSON["replayed_result_kind"] == nil)
    #expect(duplicateJSON["forbidden_repeat"] == nil)
    if exitCode != 0 {
      #expect(observations.last?.content.contains("The latest run_command failed.") == true)
    }
    #expect(projectedCallIDs(engine.chatSession) == records.map(\.id))
    #expect(await runtime.capturedToolContexts.last??.registry.definition(for: .runCommand) != nil)
  }

  @Test(arguments: [false, true])
  func manualApprovalAndApproveAllPreserveNonadjacentCallOrder(approveAll: Bool) async throws {
    let runner = BatchCommandProcessRunner()
    let ids = [UUID(), UUID(), UUID()]
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("first", id: ids[0]), command("second", id: ids[1]), command("first", id: ids[2])],
      [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }

    #expect(
      engine.chatSession.toolCalls.map(\.status) == [.awaitingApproval, .awaitingApproval, .failed])
    #expect(projectedCallIDs(engine.chatSession).isEmpty)
    #expect(await runner.requests.isEmpty)
    engine.approveToolCall(id: ids[2])
    #expect(!engine.isGenerating)
    if approveAll {
      engine.approveToolCallBatch(containing: ids[0])
    } else {
      engine.approveToolCall(id: ids[0])
      try await waitUntil { !engine.isGenerating }
      #expect(await runtime.capturedMessages.count == 1)
      #expect(projectedCallIDs(engine.chatSession).isEmpty)
      engine.approveToolCall(id: ids[1])
    }
    try await waitUntil { !engine.isGenerating }
    #expect(await runner.requests.map(\.arguments) == [["-c", "first"], ["-c", "second"]])
    #expect(engine.chatSession.toolCalls.map(\.id) == ids)
    #expect(projectedCallIDs(engine.chatSession) == ids)
    #expect(await runtime.capturedMessages.count == 2)
    engine.approveToolCall(id: ids[0])
    engine.approveToolCall(id: ids[2])
    #expect(await runner.requests.count == 2)
  }

  @Test
  func reasonAndDefaultTimeoutDoNotChangeIdentityButCommandBytesDo() async throws {
    let runner = BatchCommandProcessRunner()
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        command("check"), command("check", timeout: 120, reason: "Another explanation"),
        command(" check"), command("echo \u{e9}"), command("echo e\u{301}"),
      ],
      [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }
    #expect(await runner.requests.count == 4)
    #expect(await runner.requests.allSatisfy { $0.timeoutSeconds == 120 })
    #expect(engine.chatSession.toolCalls[1].isUnexecutedCommandDuplicate)
  }

  @Test(arguments: [(121, 999, 1), (0, -1, 1), (1, 2, 2)])
  func identityUsesEffectiveTimeout(values: (Int, Int, Int)) async throws {
    let runner = BatchCommandProcessRunner()
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("check", timeout: values.0), command("check", timeout: values.1)],
      [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }
    #expect(await runner.requests.count == values.2)
    #expect(await runner.requests.allSatisfy { (1...120).contains($0.timeoutSeconds) })
  }

  @Test
  func workingDirectoryIdentityUsesTheExecutionResolver() throws {
    let root = try scopedTemporaryDirectory()
    let other = root.appending(path: "other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let alias = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
    let input = RunCommandInput(command: "check", timeoutSeconds: 120)
    let original = try RunCommandExecutionSignature(
      input: input, workspace: Workspace(name: "Root", rootURL: root))
    let different = try RunCommandExecutionSignature(
      input: input, workspace: Workspace(name: "Other", rootURL: other))
    let normalized = try RunCommandExecutionSignature(
      input: input, workspace: Workspace(name: "Alias", rootURL: alias))
    #expect(original != different)
    #expect(different == normalized)
  }

  @Test
  func denialNeverPromotesADuplicate() async throws {
    let runner = BatchCommandProcessRunner()
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("check"), command("check")], [.chunk("The command was denied.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }
    let ids = engine.chatSession.toolCalls.map(\.id)
    engine.denyToolCall(id: ids[0])
    try await waitUntil { !engine.isGenerating }
    engine.approveToolCall(id: ids[1])
    #expect(await runner.requests.isEmpty)
    #expect(engine.chatSession.toolCalls.map(\.status) == [.denied, .failed])
    #expect(await runtime.capturedMessages.count == 2)
  }

  @Test
  func cancellationDoesNotStartDuplicatesOrIndependentSiblings() async throws {
    let runner = BatchCommandProcessRunner(holdFirst: true)
    defer { Task { await runner.releaseFirst() } }
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("first"), command("first"), command("second")]
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { await runner.requests.count == 1 }
    #expect(engine.chatSession.toolCalls[1].isUnexecutedCommandDuplicate)
    engine.cancelGeneration()
    await runner.releaseFirst()
    try await waitUntil { engine.chatSession.toolCalls.first?.resultPayload != nil }
    #expect(await runner.requests.count == 1)
    #expect(engine.chatSession.toolCalls[1].isUnexecutedCommandDuplicate)
    #expect(engine.chatSession.toolCalls[2].status == .awaitingApproval)
    #expect(engine.chatSession.turns.last?.status == .cancelled)
  }

  @Test(arguments: [Int32(0), Int32(1)])
  func laterResponseCanRetryAndOnlyExecutedFailuresCount(exitCode: Int32) async throws {
    let runner = BatchCommandProcessRunner(exitCode: exitCode)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("check"), command("check")],
      [command("check"), command("check")],
      [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }
    #expect(await runner.requests.count == 2)
    #expect(engine.chatSession.turns.last?.toolCallBatchCount == 2)
    #expect(await runtime.capturedMessages.count == 3)
    let contexts = await runtime.capturedToolContexts
    #expect(contexts[1]?.registry.definition(for: .runCommand) != nil)
    #expect((contexts[2]?.registry.definition(for: .runCommand) != nil) == (exitCode == 0))
    if exitCode != 0 {
      let turn = try #require(engine.chatSession.turns.last)
      #expect(RunCommandRepeatPolicy.repeatedFailure(inTailOf: turn.items)?.command == "check")
    }
  }

  @Test
  func newUserTurnCanRunTheSameCommandAgain() async throws {
    let runner = BatchCommandProcessRunner()
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("check"), command("check")], [.chunk("Command results recorded.")],
      [command("check"), command("check")], [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()
    for _ in 0..<2 {
      await engine.sendMessage(
        prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
      try await waitUntil { !engine.isGenerating }
    }
    #expect(await runner.requests.count == 2)
    #expect(engine.chatSession.turns.count == 2)
  }

  @Test
  func invalidCommandsKeepValidationResultsAndDoNotReserveSignatures() async throws {
    let runner = BatchCommandProcessRunner()
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: [
              "command": .string("check"), "timeoutSeconds": .string("invalid"),
            ])),
        command("check"), command("check"),
      ],
      [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }
    let records = engine.chatSession.toolCalls
    #expect(await runner.requests.count == 1)
    #expect(!records[0].isUnexecutedCommandDuplicate)
    #expect(records[2].resultPayload == .runCommandDuplicate(.init(originalCallID: records[1].id)))
  }

  @Test(arguments: ["ask_user", "finish_task"])
  func wholeBatchRejectionPrecedesTheDuplicateGuard(toolName: String) async throws {
    let runner = BatchCommandProcessRunner()
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("check"), command("check"), .toolCall(ChatRuntimeToolCall(name: toolName))],
      [.chunk("The batch was rejected.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime, runner: runner)
    engine.enableAutomaticToolApproval()
    await engine.sendMessage(prompt: "run checks", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }
    #expect(await runner.requests.isEmpty)
    #expect(engine.chatSession.toolCalls.count == 3)
    #expect(
      engine.chatSession.toolCalls.allSatisfy { record in
        guard case .invalid(let input) = record.request.payload else { return false }
        return input.reason.message
          == "\(toolName) must be the only native tool call in a response."
      })
  }

  @Test
  func unavailableCommandsDoNotReserveSignatures() throws {
    let workspace = Workspace(name: "Commands", rootURL: try scopedTemporaryDirectory())
    let registry = ToolRegistry(tools: [])
    let requests = (0..<2).map { _ in
      ToolCallRequestValidator().validate(
        RawToolCallRequest(
          workspaceID: workspace.id, sessionID: UUID(), toolName: .runCommand,
          arguments: ["command": .string("check")]), registry: registry)
    }
    #expect(RunCommandBatchPolicy.blockedRecords(for: requests, workspace: workspace).isEmpty)
  }

  @Test(
    arguments: [ToolApprovalPolicy.manual, .automatic],
    ["pending", "completed", "denied", "failed", "cancelled", "executedDuplicate"])
  func savedBatchesAreGuardedOnExplicitResume(policy: ToolApprovalPolicy, original: String)
    async throws
  {
    let runner = BatchCommandProcessRunner()
    let preparation = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("first"), command("first"), command("second")]
    ])
    let (initialEngine, initialWorkspace) = try makeEngine(runtime: preparation, runner: runner)
    await initialEngine.sendMessage(
      prompt: "run checks", in: initialWorkspace, sessionID: initialEngine.chatSession.id)
    try await waitUntil { !initialEngine.isGenerating }
    var session = initialEngine.chatSession
    var turn = try #require(session.turns.first)
    var records = session.toolCalls
    records[1].state = .awaitingApproval(preview: nil)
    records[1].evaluation = records[0].evaluation
    if original == "denied" {
      records[0].state = .denied(
        .failure(
          ToolFailure(toolName: .runCommand, path: nil, reason: .userDenied)))
    } else if original == "cancelled" {
      records[0].state = .cancelled
    } else if original != "pending" {
      let result = ToolResultPayload.runCommand(
        RunCommandResult(
          command: "first", timeoutSeconds: 120, exitCode: original == "failed" ? 1 : 0,
          durationMs: 1, stdout: .init(text: ""), stderr: .init(text: "")))
      records[0].state = original == "failed" ? .failed(result) : .completed(result)
    }
    if original == "executedDuplicate" {
      records[1].state = records[0].state
      records[1].approvalSource = .manual
    }
    for record in records { turn.updateToolCallRecord(record) }
    session.turns = [turn]
    session.toolApprovalPolicy = policy
    var workspace = initialWorkspace
    workspace.sessions = [session]
    let store = WorkspaceStore(baseURL: try scopedTemporaryDirectory().appending(path: "library"))
    try await store.saveLibrary(WorkspaceLibrary(workspaces: [workspace]))
    let restored = await store.loadLibrary()
    workspace = try #require(restored.library.workspaces.first)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("Command results recorded.")]
    ])
    let (engine, _) = try makeEngine(runtime: runtime, runner: runner, workspace: workspace)
    #expect(await runner.requests.isEmpty)
    if policy == .automatic {
      engine.resumeAutomaticApprovalBatch(containing: records[0].id)
    } else {
      // Approving the duplicate itself must not cause it or its original to run.
      engine.approveToolCall(id: records[1].id)
      try await waitUntil { !engine.isGenerating }
      #expect(await runner.requests.isEmpty)
      if original == "pending" {
        engine.approveToolCallBatch(containing: records[0].id)
      } else {
        engine.approveToolCall(id: records[2].id)
      }
    }
    try await waitUntil { !engine.isGenerating }
    #expect(
      await runner.requests.map(\.arguments)
        == (original == "pending" ? [["-c", "first"], ["-c", "second"]] : [["-c", "second"]]))
    if original == "executedDuplicate" {
      #expect(engine.chatSession.toolCalls[1].state == records[1].state)
      #expect(engine.chatSession.toolCalls[1].approvalSource == .manual)
    } else {
      #expect(engine.chatSession.toolCalls[1].isUnexecutedCommandDuplicate)
    }
    if original != "pending" { #expect(engine.chatSession.toolCalls[0].state == records[0].state) }
    if original == "cancelled" {
      #expect(projectedCallIDs(engine.chatSession).isEmpty)
      #expect(await runtime.capturedMessages.isEmpty)
    } else {
      #expect(projectedCallIDs(engine.chatSession) == records.map(\.id))
      #expect(await runtime.capturedMessages.count == 1)
    }
  }

  @Test
  func duplicateAppendChangesTheTemporaryFileOnce() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [command("printf x >> once.txt"), command("printf x >> once.txt")],
      [.chunk("Command results recorded.")],
    ])
    let (engine, workspace) = try makeEngine(runtime: runtime)
    engine.enableAutomaticToolApproval()
    await engine.sendMessage(prompt: "append once", in: workspace, sessionID: engine.chatSession.id)
    try await waitUntil { !engine.isGenerating }
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "once.txt"), encoding: .utf8) == "x")
    #expect(engine.chatSession.toolCalls[1].isUnexecutedCommandDuplicate)
  }

  private func command(
    _ text: String,
    id: UUID = UUID(),
    timeout: Int? = nil,
    reason: String? = nil
  ) -> ChatModelStreamEvent {
    var arguments: ToolCallArguments = ["command": .string(text)]
    if let timeout { arguments["timeoutSeconds"] = .number(Double(timeout)) }
    if let reason { arguments["reason"] = .string(reason) }
    return .toolCall(
      ChatRuntimeToolCall(
        id: RuntimeToolCallID.string(for: id), name: "run_command", arguments: arguments))
  }

  private func makeEngine(
    runtime: ChatSessionFakeChatModelRuntime,
    runner: any CommandProcessRunning = DefaultCommandProcessRunner(),
    workspace existingWorkspace: Workspace? = nil
  ) throws -> (ConversationEngine, Workspace) {
    let workspace =
      try existingWorkspace
      ?? Workspace(
        name: "Commands", rootURL: scopedTemporaryDirectory(),
        sessions: [ChatSession(interactionMode: .agent)])
    let engine = ConversationEngine(
      runtime: runtime, modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: ToolExecutorRegistry([
          AnyToolExecutor(RunCommandToolExecutor(processRunner: runner))
        ])))
    try engine.loadSession(from: workspace, sessionID: #require(workspace.sessions.first?.id))
    engine.modelRuntime.modelState = .ready
    return (engine, workspace)
  }

  private func waitUntil(
    _ condition: @escaping @MainActor @Sendable () async -> Bool
  ) async throws {
    try await withTestTimeout {
      while !(await condition()) {
        try await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  private func projectedCallIDs(_ session: ChatSession) -> [UUID] {
    ChatModelContextBuilder().transcript(from: session).entries.compactMap { entry in
      guard case .toolObservation(let observation) = entry.body else { return nil }
      return observation.callID
    }
  }

  private func controlJSON(_ text: String) throws -> [String: Any] {
    let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("{") })
    return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  }
}

private actor BatchCommandProcessRunner: CommandProcessRunning {
  private(set) var requests: [CommandProcessRequest] = []
  private let exitCode: Int32
  private let holdFirst: Bool
  private var firstContinuation: CheckedContinuation<Void, Never>?

  init(exitCode: Int32 = 0, holdFirst: Bool = false) {
    self.exitCode = exitCode
    self.holdFirst = holdFirst
  }

  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    requests.append(request)
    if holdFirst && requests.count == 1 {
      await withCheckedContinuation { firstContinuation = $0 }
    }
    return CommandProcessResult(
      exitCode: exitCode, durationMs: 1, stdout: "", stderr: exitCode == 0 ? "" : "Check failed.",
      cancelled: Task.isCancelled)
  }

  func releaseFirst() {
    firstContinuation?.resume()
    firstContinuation = nil
  }
}
