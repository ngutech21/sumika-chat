import Foundation
import SumikaCore
import SumikaRuntimeMLX

@MainActor
struct EvaluationRunner {
  let options: EvaluationOptions
  let cancellation: EvaluationCancellation

  func run() async -> EvaluationResult {
    var result = EvaluationResult(modelID: options.modelID, outcome: .failed)
    var sumika: Sumika?
    var artifactsReady = false
    let start = ContinuousClock.now
    do {
      let prompt = try await prepareInput()
      artifactsReady = true
      guard let model = ManagedModelCatalog.model(id: options.modelID),
        model.supportsWorkspaceTools
      else {
        throw EvaluationError("Unknown or unsupported Work model: \(options.modelID)")
      }
      let modelDirectory = model.localDirectoryURL
      guard
        await Task.detached(operation: {
          LocalModelDirectory.isComplete(at: modelDirectory)
        }).value
      else {
        throw EvaluationError("The selected model must already be installed with complete weights")
      }
      result.maxToolLoopIterations = model.maxToolLoopIterations
      let settingsStore = ModelSettingsStore(
        settingsURL: options.outputDirectory.appending(path: "state/model-settings.json")
      )
      let settings = await settingsStore.settings(for: model)
      result.contextTokenLimit = settings.contextTokenLimit
      try await save(
        EvaluationMetadata.capture(model: model, settings: settings, options: options),
        named: "runtime.json"
      )
      let environment = MLXRuntimeComposition.makeChatEnvironment()
      let instance = Sumika(
        configuration: Sumika.Configuration(
          initialModel: model,
          modelPath: modelDirectory.path(percentEncoded: false),
          initialModelSettings: settings
        ),
        dependencies: Sumika.Dependencies(
          runtime: environment.runtime,
          workspaceExecution: makeWorkspaceExecution(),
          modelSettingsStore: settingsStore,
          modelDownloader: UnavailableModelDownloader(),
          chatAttachmentLoader: ChatAttachmentLoader(
            attachmentStore: ChatAttachmentStore(
              baseURL: options.outputDirectory.appending(path: "state/attachments")
            )
          ),
          skillCatalog: SkillCatalog(
            homeDirectoryURL: options.outputDirectory.appending(path: "state/home")
          ),
          turnTracer: environment.turnTracer
        )
      )
      sumika = instance
      let session = ChatSession(
        selectedModelID: model.id,
        modeSettings: settings.modeSettings,
        interactionMode: .agent,
        toolApprovalPolicy: .automatic
      )
      let workspace = Workspace(
        name: "Harbor trial",
        rootURL: options.workspaceRoot,
        sessions: [session]
      )
      try instance.conversation.activate(sessionID: session.id, in: workspace)
      try await saveSession(instance.conversation.snapshot())
      instance.models.loadSelectedModel()
      while instance.models.state.modelState != .ready {
        if let outcome = stopOutcome(since: start) {
          result.outcome = outcome
          return await finish(result, sumika: instance)
        }
        if case .failed(let message) = instance.models.state.modelState {
          throw EvaluationError(message)
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      if let outcome = stopOutcome(since: start) {
        result.outcome = outcome
        return await finish(result, sumika: instance)
      }
      try await instance.conversation.sendMessage(MessageSubmission(text: prompt))
      guard let turnID = instance.conversation.snapshot()?.turns.last?.id else {
        throw EvaluationError("Prompt submission did not create a turn")
      }
      result.turnID = turnID
      while true {
        if let outcome = stopOutcome(since: start) {
          result.outcome = outcome
          break
        }
        guard let state = instance.conversation.state.active,
          let turn = state.turns.first(where: { $0.id == turnID })
        else {
          throw EvaluationError("The active evaluation turn disappeared")
        }
        if let outcome = EvaluationOutcome.terminalOutcome(for: turn),
          outcome == .needsUser || state.activity == .idle
        {
          result.outcome = outcome
          result.errorMessage = state.errorMessage
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    } catch {
      result.outcome = stopOutcome(since: start) ?? .failed
      result.errorMessage = error.localizedDescription
    }
    guard artifactsReady else {
      FileHandle.standardError.write(Data("\(result.errorMessage ?? "Invalid trial input")\n".utf8))
      return result
    }
    return await finish(result, sumika: sumika)
  }

  private func makeWorkspaceExecution() -> WorkspaceExecution {
    let backend = HarborWorkspaceBackend(bridgeURL: options.bridgeURL, token: options.bridgeToken)
    return WorkspaceExecution(
      fileIO: backend, commandRunner: backend,
      webClient: options.networkPolicy.webEnabled ? backend : nil)
  }

  private func stopOutcome(since start: ContinuousClock.Instant) -> EvaluationOutcome? {
    if cancellation.requested || Task.isCancelled { return .cancelled }
    if start.duration(to: .now) >= .seconds(options.timeoutSeconds) { return .timedOut }
    return nil
  }

  private func prepareInput() async throws -> String {
    let options = options
    return try await Task.detached {
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
      guard !existingArtifacts else {
        throw EvaluationError("The output directory already contains trial state")
      }
      try FileManager.default.createDirectory(
        at: stateDirectory,
        withIntermediateDirectories: true
      )
      return prompt
    }.value
  }

  private func finish(_ initialResult: EvaluationResult, sumika: Sumika?) async -> EvaluationResult
  {
    var result = initialResult
    let session = sumika?.conversation.snapshot()
    if let session {
      result.finishTaskStatus =
        session.toolCalls.reversed().compactMap { record -> FinishTaskStatus? in
          guard record.status == .completed,
            case .finishTask(let input) = record.request.payload
          else { return nil }
          return input.status
        }.first
    }
    // Preserve a user-answer pause in the artifact before cancelling the live turn.
    do {
      try await saveSession(session)
      try await saveResult(result)
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
          try? await saveResult(result)
        }
      }
      sumika.conversation.deactivate()
      await sumika.conversation.drainAttachments()
      await sumika.agent.prepareForTermination()
      await sumika.models.prepareForTermination()
      sumika.models.unloadModel()
    }
    return result
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
