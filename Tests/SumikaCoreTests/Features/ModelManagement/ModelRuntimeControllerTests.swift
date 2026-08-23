import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-model-runtime-tests"))
@MainActor
struct ModelRuntimeControllerTests {
  @Test
  func initializesWithSelectedModelConfiguration() async throws {
    let store = RuntimeFakeModelSettingsStore()
    let selectedModel = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let sharedModeSettings = ChatModeSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2, topP: 0.7, topK: 10, maxTokens: 256)
    )
    let settings = StoredModelSettings(
      modeSettings: ChatModeSettingsSet(chat: sharedModeSettings, agent: sharedModeSettings),
      contextTokenLimit: 16_384
    )
    let controller = await makeController(
      initialModelID: selectedModel.id,
      initialSettings: settings,
      modelSettingsStore: store
    )

    #expect(controller.selectedModelID == selectedModel.id)
    #expect(controller.selectedModel.id == selectedModel.id)
    #expect(controller.modelPath == selectedModel.localPath)
    #expect(controller.modelContextTokenLimit == settings.contextTokenLimit)
  }

  @Test
  func stateProjectsModelManagementFactsWithoutExposingMutableStorage() async throws {
    let downloadedModel = ManagedModelCatalog.defaultModel
    let initialOperationID = UUID()
    let controller = await makeController(
      initialOperationID: initialOperationID,
      modelAvailability: { $0.id == downloadedModel.id }
    )

    let state = controller.state
    #expect(state.availableModels == ManagedModelCatalog.models)
    #expect(state.selectedModel == downloadedModel)
    #expect(state.modelState == .notLoaded)
    #expect(state.modelContextTokenLimit == downloadedModel.defaultContextTokenLimit)
    #expect(state.canPerformSelectedModelAction)

    let conversationState = controller.conversationState
    #expect(conversationState.selectedModel == state.selectedModel)
    #expect(conversationState.loadState == state.modelState)
    #expect(conversationState.contextTokenLimit == state.modelContextTokenLimit)
    #expect(conversationState.operationID == initialOperationID)
  }

  @Test
  func contextTokenLimitChangesThroughExplicitAction() async {
    let controller = await makeController()

    controller.setContextTokenLimit(12_288)

    #expect(controller.state.modelContextTokenLimit == 12_288)
  }

  @Test
  func selectingModelPersistsSelectionAndPublishesSettings() async throws {
    let store = RuntimeFakeModelSettingsStore()
    let selectedModel = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let sharedModeSettings = ChatModeSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2, topP: 0.7, topK: 10, maxTokens: 256)
    )
    let settings = StoredModelSettings(
      modeSettings: ChatModeSettingsSet(chat: sharedModeSettings, agent: sharedModeSettings),
      contextTokenLimit: 16_384
    )
    store.settingsByModelID[selectedModel.id] = settings
    let controller = await makeController(
      initialModelID: "gemma4-26b-qat-4bit",
      modelSettingsStore: store
    )
    var publishedSettings: StoredModelSettings?
    controller.onModelDidChange = { publishedSettings = $0 }

    controller.selectModel(selectedModel)

    try await waitUntil { publishedSettings == settings }
    #expect(controller.selectedModelID == selectedModel.id)
    #expect(controller.modelPath == selectedModel.localPath)
    #expect(controller.modelContextTokenLimit == settings.contextTokenLimit)
    #expect(store.persistedSelectedModelID == selectedModel.id)
    #expect(publishedSettings == settings)
  }

  @Test
  func selectingModelRefreshesSelectedModelAvailability() async throws {
    let selectedModel = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let store = RuntimeFakeModelSettingsStore()
    let controller = await makeController(
      initialModelID: "gemma4-26b-qat-4bit",
      modelSettingsStore: store,
      modelAvailability: { $0.id == selectedModel.id }
    )
    controller.modelAvailabilitySnapshot[selectedModel.id] = false

    controller.selectModel(selectedModel)

    #expect(controller.state.isModelDownloaded(selectedModel))
  }

  @Test
  func downloadSelectedModelUpdatesDownloadState() async throws {
    let downloader = RuntimeControllerFakeModelDownloader()
    let controller = await makeController(modelDownloader: downloader)

    controller.downloadSelectedModel()

    try await waitUntil { controller.downloadState == .downloaded }
    #expect(downloader.downloadedModelID == ManagedModelCatalog.defaultModelID)
    #expect(controller.state.isModelDownloaded(ManagedModelCatalog.defaultModel))
  }

  @Test
  func downloadSelectedModelPublishesIntermediateProgress() async throws {
    let downloader = RuntimeControllerFakeModelDownloader(progressFractions: [0.25, 1])
    let controller = await makeController(modelDownloader: downloader)

    controller.downloadSelectedModel()

    try await waitUntil { controller.downloadState == .downloading(progress: 0.25) }

    try await waitUntil { controller.downloadState == .downloaded }
  }

  @Test
  func downloadSelectedModelPublishesFailureAndClearsProgress() async throws {
    let downloader = RuntimeControllerFakeModelDownloader(
      error: RuntimeControllerFakeDownloadError.failed)
    let controller = await makeController(modelDownloader: downloader)
    var errorMessage: String?
    controller.onError = { errorMessage = $0 }

    controller.downloadSelectedModel()

    try await waitUntil {
      controller.downloadState
        == .failed(RuntimeControllerFakeDownloadError.failed.localizedDescription)
    }
    #expect(errorMessage == RuntimeControllerFakeDownloadError.failed.localizedDescription)
  }

  @Test
  func saveSelectedModelSettingsPersistsCurrentRuntimeSettings() async throws {
    let store = RuntimeFakeModelSettingsStore()
    let controller = await makeController(modelSettingsStore: store)
    controller.modelContextTokenLimit = 12_288
    let generationSettings = ChatGenerationSettings(
      temperature: 0.3,
      topP: 0.85,
      topK: 40,
      maxTokens: 768
    )
    let sharedModeSettings = ChatModeSettings(
      systemPrompt: "Use concise code review notes.",
      generationSettings: generationSettings
    )
    let modeSettings = ChatModeSettingsSet(
      chat: sharedModeSettings,
      agent: sharedModeSettings
    )

    controller.saveSelectedModelSettings(modeSettings: modeSettings)

    try await waitUntil { store.savedSettingsByModelID[controller.selectedModel.id] != nil }
    let savedSettings = store.savedSettingsByModelID[controller.selectedModel.id]
    #expect(savedSettings?.modeSettings == modeSettings)
    #expect(savedSettings?.contextTokenLimit == 12_288)
  }

  @Test
  func applyingSameSessionModelDoesNotCancelInFlightLoad() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerRaceLoadingRuntime()
    defer { Task { await runtime.releaseFirstLoad() } }
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()
    try await waitUntilAsync { await runtime.loadCount == 1 }
    let loadOperationID = controller.conversationState.operationID

    let didResetRuntime = controller.applySessionModel(controller.selectedModel)

    #expect(!didResetRuntime)
    #expect(controller.conversationState.operationID == loadOperationID)
    await runtime.releaseFirstLoad()
    try await waitUntil { controller.modelState == .ready }
    #expect(await runtime.loadCount == 1)
  }

  @Test
  func loadModelUsesDirectoryConfigurationAndUpdatesReadyState() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }

    let configuration = await runtime.loadedConfiguration
    #expect(configuration?.localModelDirectory == modelDirectory)
    #expect(configuration?.contextTokenLimit == 2048)
  }

  @Test
  func pilotModelLoadCarriesCatalogThinkingBudgetPolicyToRuntime() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      initialModelID: "Qwen3.6-27B-OptiQ-4bit",
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()
    try await waitUntil { controller.modelState == .ready }

    #expect(await runtime.loadedConfiguration?.thinkingBudgetPolicy == .hardLimitImmediate)
  }

  @Test
  func qwen38LoadCarriesMediumReasoningEffortWithoutChangingBudgetPolicy() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      initialModelID: "qwen3.8-27B-OptiQ-4bit",
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()
    try await waitUntil { controller.modelState == .ready }

    let configuration = await runtime.loadedConfiguration
    #expect(configuration?.reasoningEffort == .medium)
    #expect(configuration?.thinkingBudgetPolicy == .hardLimitImmediate)
  }

  @Test
  func loadModelCapsContextLimitAtUserRequestedSetting() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"max_position_embeddings":131072}"#)
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }

    let configuration = await runtime.loadedConfiguration
    #expect(configuration?.contextTokenLimit == 16_384)
  }

  @Test
  func loadModelIgnoresCancelledEarlierOperationAfterNewLoadStarts() async throws {
    let firstModelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let secondModelDirectory = try makeModelDirectory(config: #"{"n_ctx":4096}"#)
    let runtime = RuntimeControllerRaceLoadingRuntime()
    defer { Task { await runtime.releaseFirstLoad() } }
    let controller = await makeController(
      runtime: runtime,
      modelPath: firstModelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()
    try await waitUntilAsync { await runtime.loadCount == 1 }

    controller.modelPath = secondModelDirectory.path(percentEncoded: false)
    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }
    try await waitUntilAsync { await runtime.loadCount == 2 }
    await runtime.releaseFirstLoad()
    try await waitUntilAsync { await runtime.didFinishFirstLoad }
    await Task.yield()

    #expect(controller.modelState == .ready)
    let configurations = await runtime.loadedConfigurations
    #expect(configurations.count == 2)
    #expect(configurations[0].localModelDirectory == firstModelDirectory)
    #expect(configurations[1].localModelDirectory == secondModelDirectory)
    #expect(configurations[1].contextTokenLimit == 4096)
  }

  @Test
  func staleUnloadDoesNotOverwriteRuntimeAfterSubsequentLoad() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = RuntimeControllerDelayedUnloadRuntime()
    defer { Task { await runtime.releaseUnload() } }
    let controller = await makeController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )
    controller.modelState = .ready

    controller.unloadModel()
    try await waitUntilAsync { await runtime.didStartUnload }
    #expect(controller.modelState == .notLoaded)
    #expect(!controller.state.canPerformSelectedModelAction)

    controller.loadModel()
    await Task.yield()
    #expect(await runtime.loadCount == 0)

    await runtime.releaseUnload()
    try await waitUntilAsync { await runtime.didFinishUnload }
    try await waitUntil { controller.modelState == .ready }

    #expect(await runtime.isLoaded)
    #expect(controller.state.canPerformSelectedModelAction)
  }

  @Test
  func unloadModelReleasesRuntimeAndResetsModelState() async throws {
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(runtime: runtime)
    controller.modelState = .ready

    controller.unloadModel()

    try await waitUntil { controller.modelState == .notLoaded }
    try await waitUntilAsync { await runtime.didUnload }

    #expect(await runtime.didUnload)
  }

  @Test
  func deletingInactiveModelPreservesSelectionAndSettingsAndClearsDownloadedState() async throws {
    let model = ManagedModelCatalog.defaultModel
    let baseURL = try scopedTemporaryDirectory().appending(
      path: "inactive-delete-models",
      directoryHint: .isDirectory
    )
    let modelDirectory = baseURL.appending(
      path: model.localDirectoryName,
      directoryHint: .isDirectory
    )
    let nestedDirectory = modelDirectory.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try #"{"model_type":"test"}"#.write(
      to: modelDirectory.appending(path: "config.json", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    try "weights".write(
      to: nestedDirectory.appending(path: "weights.bin", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let store = RuntimeFakeModelSettingsStore()
    let customSettings = StoredModelSettings(
      modeSettings: model.defaultModeSettings,
      contextTokenLimit: 12_288
    )
    store.settingsByModelID[model.id] = customSettings
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      initialSettings: customSettings,
      modelSettingsStore: store,
      runtime: runtime,
      modelAvailability: { candidate in
        let directory = baseURL.appending(
          path: candidate.localDirectoryName,
          directoryHint: .isDirectory
        )
        return FileManager.default.fileExists(
          atPath: directory.appending(path: "config.json").path(percentEncoded: false)
        )
      },
      modelDirectoryBaseURL: baseURL
    )
    try await waitUntil { controller.state.isModelDownloaded(model) }
    let selectedModelID = controller.selectedModelID
    let selectedModelPath = controller.modelPath
    let selectedModeSettings = controller.selectedModeSettings
    controller.downloadState = .downloaded
    controller.modelGenerationConfigPreset = ChatGenerationConfigPreset(temperature: 0.7)

    controller.deleteModel(model)

    try await waitUntil {
      controller.deletingModelID == nil && !controller.state.isModelDownloaded(model)
    }
    #expect(!FileManager.default.fileExists(atPath: modelDirectory.path(percentEncoded: false)))
    #expect(!(await runtime.didUnload))
    #expect(controller.selectedModelID == selectedModelID)
    #expect(controller.modelPath == selectedModelPath)
    #expect(controller.selectedModeSettings == selectedModeSettings)
    #expect(store.settingsByModelID[model.id] == customSettings)
    #expect(controller.downloadState == .idle)
    #expect(controller.modelGenerationConfigPreset == nil)
  }

  @Test
  func activeModelDeletionFailureKeepsDownloadedStateAndReportsError() async throws {
    let model = ManagedModelCatalog.defaultModel
    let baseURL = try scopedTemporaryDirectory().appending(
      path: "failed-delete-models",
      directoryHint: .isDirectory
    )
    let modelDirectory = baseURL.appending(
      path: model.localDirectoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    let runtime = RuntimeControllerRecordingRuntime()
    let controller = await makeController(
      runtime: runtime,
      modelAvailability: { $0.id == model.id },
      modelDirectoryBaseURL: baseURL,
      modelDirectoryRemover: { _ in
        throw RuntimeControllerModelDeletionError.removalFailed
      }
    )
    try await waitUntil { controller.state.isModelDownloaded(model) }
    controller.modelState = .ready
    controller.downloadState = .downloaded
    var errorMessage: String?
    controller.onError = { errorMessage = $0 }

    controller.deleteModel(model)

    try await waitUntil { errorMessage != nil && controller.deletingModelID == nil }
    #expect(errorMessage == RuntimeControllerModelDeletionError.removalFailed.localizedDescription)
    #expect(controller.state.isModelDownloaded(model))
    #expect(controller.downloadState == .downloaded)
    #expect(controller.modelState == .notLoaded)
    #expect(await runtime.didUnload)
    #expect(FileManager.default.fileExists(atPath: modelDirectory.path(percentEncoded: false)))
  }

  @Test
  func staleAvailabilityRefreshCannotOverrideDownloadSuccess() async throws {
    let selectedModel = ManagedModelCatalog.defaultModel
    let otherDownloadedModel = try #require(
      ManagedModelCatalog.models.first { $0.id != selectedModel.id }
    )
    let availability = RuntimeControllerBlockingAvailability(
      modelID: selectedModel.id,
      resultsByModelID: [otherDownloadedModel.id: true]
    )
    let controller = await makeController(
      modelAvailability: { availability.value(for: $0) }
    )
    controller.modelAvailabilitySnapshot[otherDownloadedModel.id] = false
    availability.blockNext(result: false)
    defer { availability.release() }

    let refreshTask = Task {
      await controller.refreshModelAvailability()
    }
    try await waitUntil { availability.didStartBlockedCall }
    controller.downloadSelectedModel()
    try await waitUntil { controller.downloadState == .downloaded }

    availability.release()
    await refreshTask.value

    #expect(controller.state.isModelDownloaded(selectedModel))
    #expect(controller.state.isModelDownloaded(otherDownloadedModel))
  }

  @Test
  func staleAvailabilityRefreshCannotRestoreDeletedModel() async throws {
    let model = ManagedModelCatalog.defaultModel
    let availability = RuntimeControllerBlockingAvailability(
      modelID: model.id,
      defaultResult: true
    )
    let baseURL = try scopedTemporaryDirectory().appending(
      path: "stale-delete-models",
      directoryHint: .isDirectory
    )
    let controller = await makeController(
      modelAvailability: { availability.value(for: $0) },
      modelDirectoryBaseURL: baseURL,
      modelDirectoryRemover: { _ in }
    )
    try await waitUntil { controller.state.isModelDownloaded(model) }
    availability.blockNext(result: true)
    defer { availability.release() }

    let refreshTask = Task {
      await controller.refreshModelAvailability()
    }
    try await waitUntil { availability.didStartBlockedCall }
    controller.deleteModel(model)
    try await waitUntil {
      controller.deletingModelID == nil && !controller.state.isModelDownloaded(model)
    }

    availability.release()
    await refreshTask.value

    #expect(!controller.state.isModelDownloaded(model))
  }

  @Test
  func preparingDefaultModelDirectoryWaitsForCompleteAvailabilitySnapshot() async throws {
    let selectedModel = ManagedModelCatalog.defaultModel
    let availability = RuntimeControllerBlockingAvailability(modelID: selectedModel.id)
    availability.blockNext(result: true)
    defer { availability.release() }
    let controller = await makeController(
      modelAvailability: { availability.value(for: $0) },
      refreshAvailabilityBeforeReturning: false
    )
    var didFinishPreparation = false

    let preparationTask = Task {
      await controller.prepareDefaultModelDirectory()
      didFinishPreparation = true
    }
    try await waitUntil { availability.didStartBlockedCall }

    #expect(!didFinishPreparation)

    availability.release()
    await preparationTask.value

    #expect(didFinishPreparation)
    #expect(controller.modelAvailabilitySnapshot.count == ManagedModelCatalog.models.count)
    #expect(controller.state.isModelDownloaded(selectedModel))
  }

  @Test
  func selectedModelCannotBeDeletedWhileDownloadingOrLoading() async throws {
    let model = ManagedModelCatalog.defaultModel
    let controller = await makeController(modelAvailability: { $0.id == model.id })
    try await waitUntil { controller.state.isModelDownloaded(model) }

    controller.downloadState = .downloading(progress: nil)
    #expect(!controller.canDeleteModel(model))
    #expect(!controller.state.canPerformSelectedModelAction)

    controller.downloadState = .idle
    controller.modelState = .loading
    #expect(!controller.canDeleteModel(model))
    #expect(!controller.state.canPerformSelectedModelAction)
  }

  private func makeController(
    initialModelID: ManagedModel.ID = ManagedModelCatalog.defaultModelID,
    initialSettings: StoredModelSettings? = nil,
    modelSettingsStore: RuntimeFakeModelSettingsStore =
      RuntimeFakeModelSettingsStore(),
    modelDownloader: RuntimeControllerFakeModelDownloader = RuntimeControllerFakeModelDownloader(),
    runtime: any ChatModelRuntime = RuntimeControllerRecordingRuntime(),
    modelPath: String? = nil,
    initialOperationID: UUID = UUID(),
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool = { _ in false },
    modelDirectoryBaseURL: URL = LocalModelDirectory.defaultBaseURL,
    modelDirectoryRemover: @escaping @Sendable (URL) throws -> Void =
      ModelLifecycleCoordinator.defaultModelDirectoryRemover,
    refreshAvailabilityBeforeReturning: Bool = true
  ) async -> ModelRuntimeController {
    let selectedModel =
      ManagedModelCatalog.model(id: initialModelID) ?? ManagedModelCatalog.defaultModel
    let settings =
      if let initialSettings {
        initialSettings
      } else {
        await modelSettingsStore.settings(for: selectedModel)
      }
    let runtimeOperations = RuntimeOperationCoordinator(runtime: runtime)
    let lifecycleCoordinator = ModelLifecycleCoordinator(
      modelDownloader: modelDownloader,
      runtimeOperations: runtimeOperations,
      modelAvailability: modelAvailability,
      modelDirectoryBaseURL: modelDirectoryBaseURL,
      modelDirectoryRemover: modelDirectoryRemover
    )
    let controller = ModelRuntimeController(
      selectedModelID: selectedModel.id,
      modelPath: modelPath ?? selectedModel.localPath,
      modelContextTokenLimit: settings.contextTokenLimit,
      modelSettingsStore: modelSettingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: lifecycleCoordinator,
      initialOperationID: initialOperationID
    )
    if refreshAvailabilityBeforeReturning {
      await controller.refreshModelAvailability()
    }
    return controller
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

  private func makeModelDirectory(config: String) throws -> URL {
    let modelDirectory = try scopedTemporaryDirectory().appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    try config.write(
      to: modelDirectory.appending(path: "config.json", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    return modelDirectory
  }

}

private final class RuntimeFakeModelSettingsStore: ModelSettingsStoring, @unchecked Sendable {
  var persistedSelectedModelID: ManagedModel.ID?
  var settingsByModelID: [String: StoredModelSettings] = [:]
  var savedSettingsByModelID: [String: StoredModelSettings] = [:]

  func setSelectedModelID(_ modelID: String) async {
    persistedSelectedModelID = modelID
  }

  func settings(for model: ManagedModel) async -> StoredModelSettings {
    settingsByModelID[model.id]
      ?? StoredModelSettings(
        modeSettings: model.defaultModeSettings,
        contextTokenLimit: model.defaultContextTokenLimit
      )
  }

  func save(settings: StoredModelSettings, for model: ManagedModel) async throws {
    savedSettingsByModelID[model.id] = settings
  }
}

private final class RuntimeControllerFakeModelDownloader: ModelDownloading, @unchecked Sendable {
  var downloadedModelID: String?
  private let progressFractions: [Double]
  private let error: Error?

  init(progressFractions: [Double] = [1], error: Error? = nil) {
    self.progressFractions = progressFractions
    self.error = error
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    downloadedModelID = model.id
    for fraction in progressFractions {
      let progress = Progress(totalUnitCount: 100)
      progress.completedUnitCount = Int64(fraction * 100)
      await progressHandler(progress)
      try await Task.sleep(for: .milliseconds(20))
    }
    if let error {
      throw error
    }
    return model.localDirectoryURL
  }
}

private enum RuntimeControllerFakeDownloadError: LocalizedError {
  case failed

  var errorDescription: String? {
    "download failed"
  }
}

private enum RuntimeControllerModelDeletionError: LocalizedError {
  case removalFailed

  var errorDescription: String? {
    "model removal failed"
  }
}

private final class RuntimeControllerBlockingAvailability: @unchecked Sendable {
  private let condition = NSCondition()
  private let modelID: ManagedModel.ID
  private let defaultResult: Bool
  private let resultsByModelID: [ManagedModel.ID: Bool]
  private var shouldBlockNextCall = false
  private var blockedResult = false
  private var isReleased = false
  private var startedBlockedCall = false

  init(
    modelID: ManagedModel.ID,
    defaultResult: Bool = false,
    resultsByModelID: [ManagedModel.ID: Bool] = [:]
  ) {
    self.modelID = modelID
    self.defaultResult = defaultResult
    self.resultsByModelID = resultsByModelID
  }

  var didStartBlockedCall: Bool {
    condition.withLock { startedBlockedCall }
  }

  func blockNext(result: Bool) {
    condition.withLock {
      shouldBlockNextCall = true
      blockedResult = result
      isReleased = false
      startedBlockedCall = false
    }
  }

  func release() {
    condition.withLock {
      isReleased = true
      condition.broadcast()
    }
  }

  func value(for model: ManagedModel) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard model.id == modelID, shouldBlockNextCall else {
      return model.id == modelID ? defaultResult : resultsByModelID[model.id, default: false]
    }

    shouldBlockNextCall = false
    startedBlockedCall = true
    condition.broadcast()
    while !isReleased {
      condition.wait()
    }
    return blockedResult
  }
}

private actor RuntimeControllerRecordingRuntime: ChatModelRuntime {
  private(set) var loadedConfiguration: ChatModelConfiguration?
  private(set) var didUnload = false

  func load(configuration: ChatModelConfiguration) async throws {
    loadedConfiguration = configuration
  }

  func unload() async {
    didUnload = true
    loadedConfiguration = nil
  }

  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private actor RuntimeControllerRaceLoadingRuntime: ChatModelRuntime {
  private var firstLoadContinuation: CheckedContinuation<Void, Never>?
  private(set) var loadedConfigurations: [ChatModelConfiguration] = []
  private(set) var didFinishFirstLoad = false

  var loadCount: Int {
    loadedConfigurations.count
  }

  func load(configuration: ChatModelConfiguration) async throws {
    loadedConfigurations.append(configuration)

    if loadedConfigurations.count == 1 {
      await withCheckedContinuation { continuation in
        firstLoadContinuation = continuation
        Task {
          try? await Task.sleep(for: .seconds(2))
          self.releaseFirstLoad()
        }
      }
      didFinishFirstLoad = true
      try Task.checkCancellation()
    }
  }

  func releaseFirstLoad() {
    firstLoadContinuation?.resume()
    firstLoadContinuation = nil
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

private actor RuntimeControllerDelayedUnloadRuntime: ChatModelRuntime {
  private var unloadContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartUnload = false
  private(set) var didFinishUnload = false
  private(set) var isLoaded = true
  private(set) var loadCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
    loadCount += 1
    isLoaded = true
  }

  func unload() async {
    didStartUnload = true
    await withCheckedContinuation { continuation in
      unloadContinuation = continuation
      Task {
        try? await Task.sleep(for: .seconds(2))
        self.releaseUnload()
      }
    }
    isLoaded = false
    didFinishUnload = true
  }

  func releaseUnload() {
    unloadContinuation?.resume()
    unloadContinuation = nil
  }

  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}
