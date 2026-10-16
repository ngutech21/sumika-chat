import Foundation
import SumikaCore
import SumikaRuntimeMLX

@MainActor
final class EvaluationRunner {
  struct Environment {
    let sumika: Sumika
    let metadata: EvaluationMetadata
  }

  let options: EvaluationOptions
  let cancellation: EvaluationCancellation
  private let environmentFactory: (@MainActor () async throws -> Environment)?
  private var environment: Environment?
  private var previousResult: EvaluationResult?
  private var inputPrepared = false

  init(
    options: EvaluationOptions, cancellation: EvaluationCancellation,
    environmentFactory: (@MainActor () async throws -> Environment)? = nil
  ) {
    self.options = options
    self.cancellation = cancellation
    self.environmentFactory = environmentFactory
  }

  func run() async -> EvaluationResult {
    let result = await runCheckpoint(networkPolicy: options.networkPolicy)
    await shutdown()
    return result
  }

  func runCheckpoint(networkPolicy: EvaluationNetworkPolicy) async -> EvaluationResult {
    var result = EvaluationResult(modelID: options.modelID, outcome: .failed)
    var artifactsReady = false
    let start = ContinuousClock.now
    do {
      guard previousResult?.canResumeWorker != false else {
        throw EvaluationError("A worker cannot continue after an unsuccessful checkpoint")
      }
      guard networkPolicy == options.networkPolicy else {
        throw EvaluationError("A worker cannot change its network policy")
      }
      let prompt = try await prepareInput()
      artifactsReady = true
      if environment == nil {
        let prepared: Environment
        if let environmentFactory {
          prepared = try await environmentFactory()
        } else {
          prepared = try await makeEnvironment()
        }
        environment = prepared
        let session = ChatSession(
          selectedModelID: options.modelID,
          modeSettings: prepared.metadata.settings.modeSettings,
          interactionMode: .agent,
          toolApprovalPolicy: .automatic
        )
        let workspace = Workspace(
          name: "Harbor trial", rootURL: options.workspaceRoot, sessions: [session])
        try prepared.sumika.conversation.activate(sessionID: session.id, in: workspace)
        try await saveSession(prepared.sumika.conversation.snapshot())
        prepared.sumika.models.loadSelectedModel()
      }
      guard let environment else { throw EvaluationError("Missing evaluation runtime") }
      let instance = environment.sumika
      result.maxToolLoopIterations = environment.metadata.maxToolLoopIterations
      result.contextTokenLimit = environment.metadata.settings.contextTokenLimit
      try await save(environment.metadata, named: "runtime.json")
      while instance.models.state.modelState != .ready {
        if let outcome = stopOutcome(since: start) {
          result.outcome = outcome
          return await finish(result)
        }
        if case .failed(let message) = instance.models.state.modelState {
          throw EvaluationError(message)
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      if let outcome = stopOutcome(since: start) {
        result.outcome = outcome
        return await finish(result)
      }
      try await instance.conversation.sendMessage(MessageSubmission(text: prompt))
      guard let turnID = instance.conversation.snapshot()?.turns.last?.id else {
        throw EvaluationError("Prompt submission did not create a turn")
      }
      result.turnID = turnID
      (result.outcome, result.errorMessage) = try await waitForTurn(
        turnID, in: instance, since: start)
    } catch {
      result.outcome = stopOutcome(since: start) ?? .failed
      result.errorMessage = error.localizedDescription
    }
    guard artifactsReady else {
      previousResult = result
      FileHandle.standardError.write(Data("\(result.errorMessage ?? "Invalid trial input")\n".utf8))
      return result
    }
    return await finish(result)
  }

  private func waitForTurn(
    _ turnID: UUID, in instance: Sumika, since start: ContinuousClock.Instant
  ) async throws -> (EvaluationOutcome, String?) {
    while true {
      if let outcome = stopOutcome(since: start) { return (outcome, nil) }
      guard let state = instance.conversation.state.active,
        let turn = state.turns.first(where: { $0.id == turnID })
      else { throw EvaluationError("The active evaluation turn disappeared") }
      if let outcome = EvaluationOutcome.terminalOutcome(for: turn),
        outcome == .needsUser || state.activity == .idle
      {
        return (outcome, state.errorMessage)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func makeEnvironment() async throws -> Environment {
    guard let model = ManagedModelCatalog.model(id: options.modelID), model.supportsWorkspaceTools
    else {
      throw EvaluationError("Unknown or unsupported Work model: \(options.modelID)")
    }
    let modelDirectory = model.localDirectoryURL
    guard
      await Task.detached(operation: { LocalModelDirectory.isComplete(at: modelDirectory) }).value
    else {
      throw EvaluationError("The selected model must already be installed with complete weights")
    }
    let settingsStore = ModelSettingsStore(
      settingsURL: options.outputDirectory.appending(path: "state/model-settings.json"))
    let settings = try await modelSettings(for: model, store: settingsStore)
    let metadata = try await EvaluationMetadata.capture(
      model: model, settings: settings, options: options)
    let runtimeEnvironment = MLXRuntimeComposition.makeChatEnvironment()
    let instance = Sumika(
      configuration: Sumika.Configuration(
        initialModel: model, modelPath: modelDirectory.path(percentEncoded: false),
        initialModelSettings: settings),
      dependencies: Sumika.Dependencies(
        runtime: runtimeEnvironment.runtime, workspaceExecution: makeWorkspaceExecution(),
        modelSettingsStore: settingsStore, modelDownloader: UnavailableModelDownloader(),
        chatAttachmentLoader: ChatAttachmentLoader(
          attachmentStore: ChatAttachmentStore(
            baseURL: options.outputDirectory.appending(path: "state/attachments"))),
        skillCatalog: SkillCatalog(
          homeDirectoryURL: options.outputDirectory.appending(path: "state/home")),
        turnTracer: runtimeEnvironment.turnTracer))
    return Environment(sumika: instance, metadata: metadata)
  }

  func modelSettings(for model: ManagedModel, store: ModelSettingsStore) async throws
    -> StoredModelSettings
  {
    let settings = await store.settings(for: model)
    guard let level = options.reasoningLevel else { return settings }
    guard case .selectableEffort(let supported, _) = model.reasoningCapability,
      supported.contains(level)
    else {
      throw EvaluationError(
        "Model \(model.id) does not support --reasoning-level \(level.rawValue)")
    }
    var modeSettings = settings.modeSettings
    modeSettings.agent.generationSettings.reasoningSelection = .effort(level)
    return try await store.apply(
      .modeSettingsChanged(from: settings.modeSettings, updated: modeSettings), for: model)
  }

  private func makeWorkspaceExecution() -> WorkspaceExecution {
    let backend = HarborWorkspaceBackend(bridgeURL: options.bridgeURL, token: options.bridgeToken)
    return WorkspaceExecution(
      fileIO: backend, commandRunner: backend,
      webClient: options.networkPolicy.webEnabled ? backend : nil)
  }

  func stopOutcome(since start: ContinuousClock.Instant) -> EvaluationOutcome? {
    if cancellation.requested || Task.isCancelled { return .cancelled }
    if let timeout = options.timeoutSeconds, start.duration(to: .now) >= .seconds(timeout) {
      return .timedOut
    }
    return nil
  }

  private func prepareInput() async throws -> String {
    let options = options
    let firstInput = !inputPrepared
    let prompt = try await Task.detached {
      let prompt = try String(contentsOf: options.promptFile, encoding: .utf8)
      guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw EvaluationError("The prompt file is empty")
      }
      let stateDirectory = options.outputDirectory.appending(path: "state")
      let existingArtifacts = [
        "state", "session.json", "result.json", "runtime.json", "mlx-trace.jsonl",
      ].contains {
        FileManager.default.fileExists(
          atPath: options.outputDirectory.appending(path: $0).path(percentEncoded: false)
        )
      }
      guard !firstInput || !existingArtifacts else {
        throw EvaluationError("The output directory already contains trial state")
      }
      if !firstInput {
        for name in ["session.json", "result.json", "runtime.json", "mlx-trace.jsonl"] {
          let file = options.outputDirectory.appending(path: name)
          if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
          }
        }
      }
      try FileManager.default.createDirectory(
        at: stateDirectory,
        withIntermediateDirectories: true
      )
      return prompt
    }.value
    inputPrepared = true
    return prompt
  }

  private func finish(_ initialResult: EvaluationResult) async -> EvaluationResult {
    var result = initialResult
    let sumika = environment?.sumika
    let session = sumika?.conversation.snapshot()
    if let turn = session?.turns.first(where: { $0.id == result.turnID }) {
      result.finishTaskStatus =
        turn.items.reversed().compactMap { item -> FinishTaskStatus? in
          guard case .tool(let record) = item else { return nil }
          guard record.status == .completed,
            case .finishTask(let input) = record.request.payload
          else { return nil }
          return input.status
        }.first
    }
    // Preserve a user-answer pause in the artifact before cancelling the live turn.
    do {
      try await saveSession(session)
    } catch {
      result.outcome = .failed
      result.errorMessage = "Cannot save evaluation artifacts: \(error.localizedDescription)"
      FileHandle.standardError.write(Data("\(result.errorMessage ?? "Artifact failure")\n".utf8))
    }
    if let sumika {
      await sumika.conversation.cancelGenerationAndDrain()
      if result.outcome != .needsUser {
        do {
          try await saveSession(sumika.conversation.snapshot())
        } catch {
          result.outcome = .failed
          result.errorMessage = "Cannot save the drained session: \(error.localizedDescription)"
        }
      }
    }
    do { try await saveResult(result) } catch {
      result.outcome = .failed
      result.errorMessage = "Cannot save evaluation result: \(error.localizedDescription)"
    }
    previousResult = result
    return result
  }

  func shutdown() async {
    guard let sumika = environment?.sumika else { return }
    environment = nil
    await sumika.conversation.cancelGenerationAndDrain()
    sumika.conversation.deactivate()
    await sumika.conversation.drainAttachments()
    await sumika.agent.prepareForTermination()
    await sumika.models.prepareForTermination()
    sumika.models.unloadModel()
    while !sumika.models.state.canPerformSelectedModelAction {
      await Task.yield()
    }
    if options.worker { setenv("SUMIKA_DEBUG_TRACE", "0", 1) }
  }

  private func saveSession(_ session: ChatSession?) async throws {
    guard let session else { return }
    try await save(session, named: "session.json")
  }

  private func saveResult(_ result: EvaluationResult) async throws {
    try await save(result, named: "result.json")
  }

  private func save(_ value: some Encodable & Sendable, named name: String) async throws {
    let destination = options.outputDirectory.appending(path: name)
    try await Task.detached {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try encoder.encode(value).write(to: destination, options: .atomic)
    }.value
  }
}
