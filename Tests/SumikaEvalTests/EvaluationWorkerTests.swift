import Foundation
import SumikaCore
import Synchronization
import Testing

@testable import SumikaEval

@MainActor
@Suite(.serialized)
struct EvaluationWorkerTests {
  @Test
  func checkpointsKeepTheSessionAndLoadedRuntime() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = fixture.runner()
    let first = await runner.runCheckpoint(networkPolicy: fixture.options.networkPolicy)
    let firstSession = try fixture.session()
    #expect(first.outcome == .completed)
    #expect(first.finishTaskStatus == .done)
    #expect(firstSession.turns.count == 1)
    #expect(firstSession.turns.first?.toolCallBatchCount == 1)
    #expect(await fixture.runtime.loadCount == 1)
    #expect(await fixture.runtime.unloadCount == 0)
    let initialClearCount = await fixture.runtime.clearCount

    try "second checkpoint".write(to: fixture.options.promptFile, atomically: true, encoding: .utf8)
    try Data("old trace".utf8).write(
      to: fixture.options.outputDirectory.appending(path: "mlx-trace.jsonl"))
    let second = await runner.runCheckpoint(networkPolicy: fixture.options.networkPolicy)
    let secondSession = try fixture.session()
    #expect(second.outcome == .completed)
    #expect(secondSession.id == firstSession.id)
    #expect(secondSession.turns.first == firstSession.turns.first)
    #expect(secondSession.turns.count == 2)
    #expect(secondSession.turns.map(\.toolCallBatchCount) == [1, 1])
    #expect(second.turnID == secondSession.turns.last?.id)
    #expect(second.turnID != first.turnID)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.options.outputDirectory.appending(path: "mlx-trace.jsonl").path))
    let histories = await fixture.runtime.histories
    #expect(histories.count == 2)
    #expect(histories[1].contains { $0.role == .user && $0.content.contains("first checkpoint") })
    #expect(histories[1].contains { $0.role == .user && $0.content.contains("second checkpoint") })
    #expect(await fixture.runtime.loadCount == 1)
    #expect(await fixture.runtime.unloadCount == 0)
    #expect(await fixture.runtime.clearCount == initialClearCount)
    await runner.shutdown()
    #expect(await fixture.runtime.unloadCount == 1)
  }

  @Test
  func oneShotRunTearsDownTheRuntime() async throws {
    let fixture = try Fixture(worker: false)
    defer { fixture.remove() }
    let result = await fixture.runner().run()
    #expect(result.outcome == .completed)
    #expect(await fixture.runtime.loadCount == 1)
    #expect(await fixture.runtime.unloadCount == 1)
  }

  @Test
  func changedPolicyAndUnsuccessfulCheckpointCannotContinue() async throws {
    let fixture = try Fixture(reply: .finish("needs_user"))
    defer { fixture.remove() }
    let runner = fixture.runner()
    let first = await runner.runCheckpoint(networkPolicy: fixture.options.networkPolicy)
    #expect(first.finishTaskStatus == .needsUser)
    let rejected = await runner.runCheckpoint(networkPolicy: fixture.options.networkPolicy)
    #expect(rejected.outcome == .failed)
    #expect(rejected.errorMessage?.contains("unsuccessful checkpoint") == true)
    #expect(await fixture.runtime.histories.count == 1)
    await runner.shutdown()

    let other = try Fixture()
    defer { other.remove() }
    let otherRunner = other.runner()
    let changed = try JSONDecoder().decode(
      EvaluationNetworkPolicy.self, from: Data(#"{"network_mode":"public"}"#.utf8))
    let policyResult = await otherRunner.runCheckpoint(networkPolicy: changed)
    #expect(policyResult.outcome == .failed)
    #expect(policyResult.errorMessage?.contains("network policy") == true)
    #expect(await other.runtime.loadCount == 0)
    #expect(await other.runtime.histories.isEmpty)
    await otherRunner.shutdown()
  }

  @Test(arguments: [false, true])
  func failedAndCancelledCheckpointsCannotContinue(blocked: Bool) async throws {
    let fixture = try Fixture(reply: blocked ? .wait : .fail)
    defer { fixture.remove() }
    let cancellation = EvaluationCancellation()
    let runner = fixture.runner(cancellation: cancellation)
    let task = Task { await runner.runCheckpoint(networkPolicy: fixture.options.networkPolicy) }
    if blocked {
      while await fixture.runtime.histories.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      cancellation.requested = true
    }
    let result = await task.value
    #expect(result.outcome == (blocked ? .cancelled : .failed))
    cancellation.requested = false
    let rejected = await runner.runCheckpoint(networkPolicy: fixture.options.networkPolicy)
    #expect(rejected.outcome == .failed)
    #expect(rejected.errorMessage?.contains("unsuccessful checkpoint") == true)
    #expect(await fixture.runtime.histories.count == 1)
    await runner.shutdown()
    #expect(await fixture.runtime.unloadCount == 1)
  }

  @Test
  func workerAcknowledgesDrainedArtifactsThenEOFTearsDown() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    let worker = EvaluationWorker(runner: fixture.runner())
    var responses: [EvaluationWorkerResponse] = []
    let task = Task {
      await worker.run(input: pipe.fileHandleForReading) { response in
        responses.append(response)
        let session = try fixture.session()
        let result = try JSONDecoder().decode(
          EvaluationResult.self,
          from: Data(contentsOf: fixture.options.outputDirectory.appending(path: "result.json")))
        #expect(result.turnID == session.turns.last?.id)
        #expect(result.turnID == response.result.turnID)
        #expect(ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE"] == "0")
        let line = try #require(String(data: response.line(), encoding: .utf8))
        #expect(line.hasPrefix(EvaluationWorkerResponse.prefix))
        if responses.count == 1 {
          try "second checkpoint".write(
            to: fixture.options.promptFile, atomically: true, encoding: .utf8)
          try pipe.fileHandleForWriting.write(contentsOf: request("checkpoint_2"))
        } else {
          try pipe.fileHandleForWriting.close()
        }
      }
    }
    try pipe.fileHandleForWriting.write(contentsOf: request("checkpoint_1"))
    #expect(await task.value == 0)
    #expect(responses.map(\.checkpointID) == ["checkpoint_1", "checkpoint_2"])
    #expect(await fixture.runtime.loadCount == 1)
    #expect(await fixture.runtime.unloadCount == 1)
  }

  @Test
  func cancellationWhileIdleWakesInputAndTearsDown() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let cancellation = EvaluationCancellation()
    let worker = EvaluationWorker(runner: fixture.runner(cancellation: cancellation))
    let task = Task {
      await worker.run(input: pipe.fileHandleForReading) { _ in
        cancellation.requested = true
      }
    }
    try pipe.fileHandleForWriting.write(contentsOf: request("checkpoint_1"))
    #expect(await task.value == EvaluationOutcome.cancelled.exitCode)
    #expect(await fixture.runtime.loadCount == 1)
    #expect(await fixture.runtime.unloadCount == 1)
  }

  @Test
  func eofWhileGeneratingCancelsAndDrainsBeforeAcknowledging() async throws {
    let fixture = try Fixture(reply: .wait)
    defer { fixture.remove() }
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    let worker = EvaluationWorker(runner: fixture.runner())
    var outcome: EvaluationOutcome?
    let task = Task {
      await worker.run(input: pipe.fileHandleForReading) { response in
        outcome = response.result.outcome
        let session = try fixture.session()
        #expect(session.turns.last?.status == .cancelled)
        #expect(fixture.runtime.unloadTracing.withLock { $0 } == [true])
      }
    }
    try pipe.fileHandleForWriting.write(contentsOf: request("checkpoint_1"))
    while await fixture.runtime.histories.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    try pipe.fileHandleForWriting.close()
    #expect(await task.value == EvaluationOutcome.cancelled.exitCode)
    #expect(outcome == .cancelled)
    #expect(await fixture.runtime.unloadCount == 1)
  }

  private func request(_ checkpointID: String) -> Data {
    Data(
      "{\"checkpointID\":\"\(checkpointID)\",\"networkPolicy\":{\"network_mode\":\"no-network\"}}\n"
        .utf8)
  }
}

@MainActor
private struct Fixture {
  let directory: URL
  let options: EvaluationOptions
  let runtime: WorkerRuntime

  init(worker: Bool = true, reply: WorkerRuntime.Reply = .finish("done")) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let prompt = directory.appending(path: "prompt.txt")
    try "first checkpoint".write(to: prompt, atomically: true, encoding: .utf8)
    options = try EvaluationOptions(
      arguments: [
        "--model-id", "Swift-1.5-4bit-MLX", "--workspace-root", directory.path,
        "--bridge-url", "http://127.0.0.1:8765", "--prompt-file", prompt.path,
        "--output-dir", directory.appending(path: "output").path, "--timeout-seconds", "10",
      ] + (worker ? ["--worker"] : []), environment: ["SUMIKA_HARBOR_TOKEN": "test"])
    runtime = WorkerRuntime(reply: reply)
  }

  func runner(cancellation: EvaluationCancellation = EvaluationCancellation()) -> EvaluationRunner {
    EvaluationRunner(options: options, cancellation: cancellation) {
      let model = try #require(ManagedModelCatalog.model(id: options.modelID))
      let settings = StoredModelSettings(
        modeSettings: model.defaultModeSettings, contextTokenLimit: model.defaultContextTokenLimit)
      let sumika = Sumika(
        configuration: .init(initialModel: model, initialModelSettings: settings),
        dependencies: .init(
          runtime: runtime,
          modelSettingsStore: ModelSettingsStore(
            settingsURL: directory.appending(path: "settings.json")),
          modelAvailability: { _ in true },
          skillCatalog: SkillCatalog(homeDirectoryURL: directory.appending(path: "home"))))
      let metadata = EvaluationMetadata(
        modelID: model.id, huggingFaceRepoID: model.huggingFaceRepoID,
        modelDirectory: directory.path, modelFiles: [], buildConfiguration: "test",
        settings: settings, workspaceRoot: options.workspaceRoot.path,
        timeoutSeconds: options.timeoutSeconds, maxToolLoopIterations: model.maxToolLoopIterations,
        networkPolicy: options.networkPolicy, webAccessSettings: .disabled)
      return EvaluationRunner.Environment(sumika: sumika, metadata: metadata)
    }
  }

  func session() throws -> ChatSession {
    try JSONDecoder().decode(
      ChatSession.self,
      from: Data(contentsOf: options.outputDirectory.appending(path: "session.json")))
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor WorkerRuntime: ChatModelRuntime {
  nonisolated let unloadTracing = Mutex<[Bool]>([])
  enum Reply: Sendable {
    case finish(String)
    case fail
    case wait
  }

  let reply: Reply
  private(set) var loadCount = 0
  private(set) var unloadCount = 0
  private(set) var clearCount = 0
  private(set) var histories: [[ProjectedModelContextEntry]] = []

  init(reply: Reply) { self.reply = reply }
  func load(configuration: ChatModelConfiguration) async throws { loadCount += 1 }
  func unload() async {
    unloadCount += 1
    unloadTracing.withLock {
      $0.append(ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE"] == "1")
    }
  }
  func clearContext() async { clearCount += 1 }

  func streamReply(
    for transcript: ModelPromptProjection, attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan, settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    histories.append(transcript.projectedEntries())
    switch reply {
    case .finish(let status):
      return AsyncThrowingStream { continuation in
        continuation.yield(
          .toolCall(
            ChatRuntimeToolCall(
              name: "finish_task",
              arguments: ["status": .string(status), "summary": .string("Checkpoint finished.")])))
        continuation.yield(.completed(nil))
        continuation.finish()
      }
    case .fail:
      throw EvaluationError("Fixture runtime failure")
    case .wait:
      return AsyncThrowingStream { _ in }
    }
  }
}
