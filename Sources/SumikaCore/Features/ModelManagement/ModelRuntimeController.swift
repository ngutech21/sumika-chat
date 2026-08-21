import Foundation
import Observation

@MainActor
@Observable
final class ModelRuntimeController {
  var availableModels = ManagedModelCatalog.models
  var selectedModelID: ManagedModel.ID
  var downloadState: ModelDownloadState = .idle
  var modelPath: String
  var modelState: ModelLoadState = .notLoaded
  var modelContextTokenLimit = ManagedModelCatalog.defaultContextTokenLimit
  var selectedModeSettings = ManagedModelCatalog.defaultModel.defaultModeSettings
  var modelGenerationConfigPreset: ChatGenerationConfigPreset?
  var modelAvailabilitySnapshot: [ManagedModel.ID: Bool] = [:]
  var deletingModelID: ManagedModel.ID?
  private var isRuntimeOperationInProgress = false

  @ObservationIgnored private let runtimeOperations: RuntimeOperationCoordinator
  @ObservationIgnored private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var deleteTask: Task<Void, Never>?
  @ObservationIgnored private var availabilityRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var generationConfigRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var availabilityRefreshRevision = 0
  @ObservationIgnored private var availabilityMutationRevisions: [ManagedModel.ID: Int] = [:]
  @ObservationIgnored private var generationConfigRevision = 0
  @ObservationIgnored private var modelOperationID: UUID

  @ObservationIgnored var onModelDidChange: (@MainActor (StoredModelSettings) -> Void)?
  @ObservationIgnored var onRuntimeDidReset: (@MainActor () -> Void)?
  @ObservationIgnored var onError: (@MainActor (String) -> Void)?

  var selectedModel: ManagedModel {
    availableModels.first { $0.id == selectedModelID } ?? ManagedModelCatalog.defaultModel
  }

  var canPerformSelectedModelAction: Bool {
    modelState != .loading
      && !downloadState.isDownloading
      && deletingModelID == nil
      && !isRuntimeOperationInProgress
  }

  var state: ModelManagementState {
    ModelManagementState(
      availableModels: availableModels,
      selectedModel: selectedModel,
      downloadedModelIDs: Set(
        modelAvailabilitySnapshot.compactMap { modelID, isDownloaded in
          isDownloaded ? modelID : nil
        }
      ),
      downloadState: downloadState,
      modelState: modelState,
      modelContextTokenLimit: modelContextTokenLimit,
      modelGenerationConfigPreset: modelGenerationConfigPreset,
      deletingModelID: deletingModelID,
      canPerformSelectedModelAction: canPerformSelectedModelAction
    )
  }

  var conversationState: ConversationModelState {
    let effectiveModelState =
      deletingModelID == selectedModelID ? ModelLoadState.notLoaded : modelState
    return ConversationModelState(
      selectedModel: selectedModel,
      loadState: effectiveModelState,
      contextTokenLimit: modelContextTokenLimit,
      operationID: modelOperationID
    )
  }

  init(
    selectedModelID: ManagedModel.ID,
    modelPath: String,
    modelContextTokenLimit: Int,
    selectedModeSettings: ChatModeSettingsSet? = nil,
    modelSettingsStore: any ModelSettingsStoring,
    runtimeOperations: RuntimeOperationCoordinator,
    modelLifecycleCoordinator: ModelLifecycleCoordinator,
    initialOperationID: UUID
  ) {
    self.selectedModelID = selectedModelID
    self.modelPath = modelPath
    self.modelContextTokenLimit = modelContextTokenLimit
    self.selectedModeSettings =
      selectedModeSettings ?? ManagedModelCatalog.defaultModel.defaultModeSettings
    self.modelSettingsStore = modelSettingsStore
    self.runtimeOperations = runtimeOperations
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
    self.modelOperationID = initialOperationID
    refreshModelGenerationConfigPreset()
  }

  func setEventHandlers(_ handlers: ModelManagementEventHandlers) {
    onModelDidChange = handlers.modelDidChange
    onRuntimeDidReset = handlers.runtimeDidReset
    onError = handlers.errorDidOccur
  }

  deinit {
    loadTask?.cancel()
    downloadTask?.cancel()
    deleteTask?.cancel()
    availabilityRefreshTask?.cancel()
    generationConfigRefreshTask?.cancel()
  }

  #if DEBUG
    func setModelLoadStateForTesting(_ state: ModelLoadState) {
      modelState = state
    }
  #endif

  func prepareDefaultModelDirectory() async {
    let lifecycleCoordinator = modelLifecycleCoordinator
    do {
      let baseURL = try await Task.detached {
        try lifecycleCoordinator.ensureDefaultModelDirectoryExists()
      }.value
      if modelPath.isEmpty {
        modelPath = selectedModel.localPath
      } else if !modelPath.hasPrefix(baseURL.path(percentEncoded: false)) {
        modelPath = selectedModel.localPath
      }
      refreshModelGenerationConfigPreset()
      await refreshModelAvailability()
    } catch {
      onError?(error.localizedDescription)
    }
  }

  func setContextTokenLimit(_ limit: Int) {
    modelContextTokenLimit = limit
  }

  func selectModel(_ model: ManagedModel) {
    guard canPerformSelectedModelAction, selectedModelID != model.id else {
      return
    }

    unloadModel()
    selectedModelID = model.id
    modelPath = model.localPath
    downloadState = .idle
    modelContextTokenLimit = model.defaultContextTokenLimit
    modelGenerationConfigPreset = nil
    updateModelAvailability(
      modelLifecycleCoordinator.isModelDownloaded(model),
      for: model.id
    )

    Task { [modelSettingsStore] in
      await modelSettingsStore.setSelectedModelID(model.id)
      let settings = await modelSettingsStore.settings(for: model)
      guard selectedModelID == model.id else {
        return
      }
      modelContextTokenLimit = settings.contextTokenLimit
      selectedModeSettings = settings.modeSettings
      refreshModelGenerationConfigPreset()
      onModelDidChange?(settings)
    }
  }

  func applySessionModel(_ model: ManagedModel) -> Bool {
    let isModelSwitch = selectedModelID != model.id
    let shouldUnloadRuntime = isModelSwitch && modelState != .notLoaded

    if isModelSwitch {
      loadTask?.cancel()
      loadTask = nil
      selectedModelID = model.id
      modelPath = model.localPath
      downloadState = .idle
      modelContextTokenLimit = model.defaultContextTokenLimit
      modelGenerationConfigPreset = nil
    } else if modelPath.isEmpty {
      modelPath = model.localPath
    }

    Task { [modelSettingsStore] in
      let settings = await modelSettingsStore.settings(for: model)
      guard selectedModelID == model.id else {
        return
      }
      modelContextTokenLimit = settings.contextTokenLimit
      selectedModeSettings = settings.modeSettings
      refreshModelGenerationConfigPreset()
    }

    if shouldUnloadRuntime {
      unloadRuntimeForModelSwitch()
    }

    return shouldUnloadRuntime
  }

  func refreshModelAvailability() async {
    availabilityRefreshRevision &+= 1
    let refreshRevision = availabilityRefreshRevision
    let mutationRevisions = availabilityMutationRevisions
    let models = availableModels
    let lifecycleCoordinator = modelLifecycleCoordinator
    availabilityRefreshTask?.cancel()
    let refreshTask = Task {
      let snapshot = await Task.detached {
        lifecycleCoordinator.modelAvailabilitySnapshot(for: models)
      }.value
      guard
        !Task.isCancelled,
        refreshRevision == availabilityRefreshRevision
      else {
        return
      }

      var mergedSnapshot = snapshot
      for model in models
      where mutationRevisions[model.id, default: 0]
        != availabilityMutationRevisions[model.id, default: 0]
      {
        mergedSnapshot[model.id] = modelAvailabilitySnapshot[model.id]
      }
      modelAvailabilitySnapshot = mergedSnapshot
      availabilityRefreshTask = nil
    }
    availabilityRefreshTask = refreshTask
    await refreshTask.value
  }

  func downloadSelectedModel() {
    guard !downloadState.isDownloading else {
      return
    }

    let model = selectedModel
    let lifecycleCoordinator = modelLifecycleCoordinator
    downloadTask?.cancel()
    downloadState = .downloading(progress: nil)

    downloadTask = Task {
      do {
        let result = try await lifecycleCoordinator.download(model: model) { progress in
          let fraction = Self.normalizedDownloadProgress(progress)
          self.downloadState = .downloading(progress: fraction)
        }
        try Task.checkCancellation()
        downloadState = .downloaded
        modelPath = result.localPath
        updateModelAvailability(true, for: model.id)
        refreshModelGenerationConfigPreset()
      } catch is CancellationError {
        downloadState = .idle
      } catch {
        downloadState = .failed(error.localizedDescription)
        onError?(error.localizedDescription)
      }

      downloadTask = nil
    }
  }

  func saveSelectedModelSettings(modeSettings: ChatModeSettingsSet) {
    selectedModeSettings = modeSettings
    let settings = StoredModelSettings(
      modeSettings: modeSettings,
      contextTokenLimit: modelContextTokenLimit
    )

    let selectedModel = selectedModel
    Task { [modelSettingsStore] in
      do {
        try await modelSettingsStore.save(settings: settings, for: selectedModel)
      } catch {
        onError?(error.localizedDescription)
      }
    }
  }

  private func refreshModelGenerationConfigPreset() {
    generationConfigRevision &+= 1
    let revision = generationConfigRevision
    let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
    generationConfigRefreshTask?.cancel()
    generationConfigRefreshTask = Task {
      let preset = await Task.detached {
        LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory)
      }.value
      guard
        !Task.isCancelled,
        revision == generationConfigRevision,
        modelPath == modelDirectory.path(percentEncoded: false)
      else {
        return
      }
      modelGenerationConfigPreset = preset
      generationConfigRefreshTask = nil
    }
  }

  func loadModel() {
    guard !downloadState.isDownloading, deletingModelID == nil else {
      return
    }

    let trimmedPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else {
      onError?("Choose a local model directory before loading.")
      return
    }

    let directoryURL = URL(filePath: trimmedPath, directoryHint: .isDirectory)
    loadTask?.cancel()
    let operationID = UUID()
    modelOperationID = operationID
    let lifecycleCoordinator = modelLifecycleCoordinator
    let runtimeOperations = runtimeOperations
    let requestedContextTokenLimit = modelContextTokenLimit
    let supportsImageInput = selectedModel.supportsImageInput
    let usesBundledMTPDrafter = selectedModel.usesBundledMTPDrafter
    let reasoningTraceFormat = selectedModel.reasoningTraceFormat
    let supportsHistoricalReasoningPreservation =
      selectedModel.supportsHistoricalReasoningPreservation
    let thinkingBudgetPolicy = selectedModel.thinkingBudgetPolicy
    modelState = .loading
    isRuntimeOperationInProgress = true

    loadTask = Task {
      await runtimeOperations.setCurrentOperation(operationID)

      do {
        try await lifecycleCoordinator.loadModel(
          from: directoryURL,
          requestedContextTokenLimit: requestedContextTokenLimit,
          supportsImageInput: supportsImageInput,
          usesBundledMTPDrafter: usesBundledMTPDrafter,
          reasoningTraceFormat: reasoningTraceFormat,
          supportsHistoricalReasoningPreservation: supportsHistoricalReasoningPreservation,
          thinkingBudgetPolicy: thinkingBudgetPolicy,
          operationID: operationID
        )
        try Task.checkCancellation()
        guard await runtimeOperations.isCurrent(operationID), operationID == modelOperationID else {
          return
        }
        modelState = .ready
      } catch is CancellationError {
        if await runtimeOperations.isCurrent(operationID), operationID == modelOperationID {
          modelState = .notLoaded
          onRuntimeDidReset?()
        }
      } catch {
        guard await runtimeOperations.isCurrent(operationID), operationID == modelOperationID else {
          return
        }
        modelState = .failed(error.localizedDescription)
        onError?(error.localizedDescription)
      }

      if operationID == modelOperationID {
        isRuntimeOperationInProgress = false
        loadTask = nil
      }
    }
  }

  func unloadModel() {
    guard deletingModelID == nil else {
      return
    }
    let operationID = UUID()
    modelOperationID = operationID
    loadTask?.cancel()
    modelState = .notLoaded
    isRuntimeOperationInProgress = true
    onRuntimeDidReset?()
    let lifecycleCoordinator = modelLifecycleCoordinator
    let runtimeOperations = runtimeOperations

    loadTask = Task {
      await runtimeOperations.setCurrentOperation(operationID)
      do {
        try await lifecycleCoordinator.unloadModel(operationID: operationID)
      } catch is CancellationError {
      } catch {
        guard await runtimeOperations.isCurrent(operationID), operationID == modelOperationID else {
          return
        }
        onError?(error.localizedDescription)
      }
      if await runtimeOperations.isCurrent(operationID), operationID == modelOperationID {
        isRuntimeOperationInProgress = false
        loadTask = nil
      }
    }
  }

  func canDeleteModel(_ model: ManagedModel) -> Bool {
    guard
      deletingModelID == nil,
      let managedModel = availableModels.first(where: { $0.id == model.id }),
      modelAvailabilitySnapshot[managedModel.id] == true
    else {
      return false
    }

    guard managedModel.id == selectedModelID else {
      return true
    }

    return canPerformSelectedModelAction
  }

  func deleteModel(_ model: ManagedModel) {
    guard
      canDeleteModel(model),
      let managedModel = availableModels.first(where: { $0.id == model.id })
    else {
      return
    }

    let shouldUnloadRuntime =
      managedModel.id == selectedModelID && modelState != .notLoaded
    let operationID = shouldUnloadRuntime ? UUID() : nil
    if let operationID {
      modelOperationID = operationID
      loadTask?.cancel()
      loadTask = nil
    }

    deletingModelID = managedModel.id
    let lifecycleCoordinator = modelLifecycleCoordinator
    let runtimeOperations = runtimeOperations
    deleteTask = Task {
      if let operationID {
        await runtimeOperations.setCurrentOperation(operationID)
      }

      do {
        try await lifecycleCoordinator.deleteDownloadedModel(
          managedModel,
          unloadOperationID: operationID
        ) {
          self.modelState = .notLoaded
          self.isRuntimeOperationInProgress = true
          self.onRuntimeDidReset?()
        }
        updateModelAvailability(false, for: managedModel.id)
        if managedModel.id == selectedModelID {
          downloadState = .idle
          invalidateGenerationConfigRefresh()
          modelGenerationConfigPreset = nil
        }
      } catch is CancellationError {
      } catch {
        onError?(error.localizedDescription)
      }

      if let operationID,
        await runtimeOperations.isCurrent(operationID),
        operationID == modelOperationID
      {
        isRuntimeOperationInProgress = false
      }
      if deletingModelID == managedModel.id {
        deletingModelID = nil
        deleteTask = nil
      }
    }
  }

  private func unloadRuntimeForModelSwitch() {
    let operationID = UUID()
    modelOperationID = operationID
    modelState = .notLoaded
    isRuntimeOperationInProgress = true
    onRuntimeDidReset?()
    let lifecycleCoordinator = modelLifecycleCoordinator
    let runtimeOperations = runtimeOperations

    loadTask = Task {
      await runtimeOperations.setCurrentOperation(operationID)
      do {
        try await lifecycleCoordinator.unloadModel(operationID: operationID)
      } catch is CancellationError {
      } catch {
        guard await runtimeOperations.isCurrent(operationID) else {
          return
        }
        onError?(error.localizedDescription)
      }
      if await runtimeOperations.isCurrent(operationID), operationID == modelOperationID {
        isRuntimeOperationInProgress = false
        loadTask = nil
      }
    }
  }

  private func updateModelAvailability(_ isDownloaded: Bool, for modelID: ManagedModel.ID) {
    availabilityMutationRevisions[modelID, default: 0] &+= 1
    modelAvailabilitySnapshot[modelID] = isDownloaded
  }

  private func invalidateGenerationConfigRefresh() {
    generationConfigRevision &+= 1
    generationConfigRefreshTask?.cancel()
    generationConfigRefreshTask = nil
  }

  private static func normalizedDownloadProgress(_ progress: Progress) -> Double? {
    let fraction = progress.fractionCompleted
    guard fraction.isFinite else {
      return nil
    }

    return min(max(fraction, 0), 1)
  }

}
