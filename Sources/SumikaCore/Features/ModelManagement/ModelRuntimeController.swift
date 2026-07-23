import Foundation
import Observation

@MainActor
@Observable
final class ModelRuntimeController {
  var availableModels = ManagedModelCatalog.models
  var selectedModelID: ManagedModel.ID
  var downloadState: ModelDownloadState = .idle
  var downloadProgress: Double?
  var modelPath: String
  var modelState: ModelLoadState = .notLoaded
  var modelContextTokenLimit = ManagedModelCatalog.defaultContextTokenLimit
  var selectedModeSettings = ManagedModelCatalog.defaultModel.defaultModeSettings
  var modelGenerationConfigPreset: ChatGenerationConfigPreset?
  var modelAvailabilitySnapshot: [ManagedModel.ID: Bool] = [:]

  @ObservationIgnored private let runtimeOperations: RuntimeOperationCoordinator
  @ObservationIgnored private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var modelOperationID: UUID

  @ObservationIgnored var onModelDidChange: (@MainActor (StoredModelSettings) -> Void)?
  @ObservationIgnored var onRuntimeDidReset: (@MainActor () -> Void)?
  @ObservationIgnored var onContextUsageShouldRefresh: (@MainActor () async -> Void)?
  @ObservationIgnored var onError: (@MainActor (String) -> Void)?

  var selectedModel: ManagedModel {
    availableModels.first { $0.id == selectedModelID } ?? ManagedModelCatalog.defaultModel
  }

  var canChangeModel: Bool {
    modelState != .loading && !downloadState.isDownloading
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
      canChangeModel: canChangeModel
    )
  }

  var conversationState: ConversationModelState {
    ConversationModelState(
      selectedModel: selectedModel,
      loadState: modelState,
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
    refreshModelAvailability()
  }

  func setEventHandlers(_ handlers: ModelManagementEventHandlers) {
    onModelDidChange = handlers.modelDidChange
    onRuntimeDidReset = handlers.runtimeDidReset
    onContextUsageShouldRefresh = handlers.contextUsageShouldRefresh
    onError = handlers.errorDidOccur
  }

  deinit {
    loadTask?.cancel()
    downloadTask?.cancel()
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func currentOperationID() -> UUID {
    modelOperationID
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
      refreshModelAvailability()
    } catch {
      onError?(error.localizedDescription)
    }
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func setModelDirectory(_ url: URL) {
    modelPath = url.path(percentEncoded: false)
    modelState = .notLoaded
    refreshModelGenerationConfigPreset()
  }

  func setContextTokenLimit(_ limit: Int) {
    modelContextTokenLimit = limit
  }

  func selectModel(_ model: ManagedModel) {
    guard canChangeModel, selectedModelID != model.id else {
      return
    }

    unloadModel()
    selectedModelID = model.id
    modelPath = model.localPath
    downloadState = .idle
    downloadProgress = nil
    modelContextTokenLimit = model.defaultContextTokenLimit
    modelGenerationConfigPreset = nil
    modelAvailabilitySnapshot[model.id] = modelLifecycleCoordinator.isModelDownloaded(model)

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
      downloadProgress = nil
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

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func isModelDownloaded(_ model: ManagedModel) -> Bool {
    modelAvailabilitySnapshot[model.id] ?? false
  }

  func isSelectedModelDownloaded() -> Bool {
    let model = selectedModel
    let isDownloaded = modelLifecycleCoordinator.isModelDownloaded(model)
    modelAvailabilitySnapshot[model.id] = isDownloaded
    return isDownloaded
  }

  func refreshModelAvailability() {
    let models = availableModels
    let lifecycleCoordinator = modelLifecycleCoordinator
    Task {
      let snapshot = await Task.detached {
        lifecycleCoordinator.modelAvailabilitySnapshot(for: models)
      }.value
      modelAvailabilitySnapshot = snapshot
    }
  }

  func downloadSelectedModel() {
    guard !downloadState.isDownloading else {
      return
    }

    let model = selectedModel
    let lifecycleCoordinator = modelLifecycleCoordinator
    downloadTask?.cancel()
    downloadProgress = nil
    downloadState = .downloading(progress: nil)

    downloadTask = Task {
      do {
        let result = try await lifecycleCoordinator.download(model: model) { progress in
          let fraction = Self.normalizedDownloadProgress(progress)
          self.downloadProgress = fraction
          self.downloadState = .downloading(progress: self.downloadProgress)
        }
        try Task.checkCancellation()
        downloadState = .downloaded
        downloadProgress = 1
        modelPath = result.localPath
        modelAvailabilitySnapshot[model.id] = true
        refreshModelGenerationConfigPreset()
      } catch is CancellationError {
        downloadState = .idle
        downloadProgress = nil
      } catch {
        downloadState = .failed(error.localizedDescription)
        onError?(error.localizedDescription)
        downloadProgress = nil
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
    let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
    Task {
      let preset = await Task.detached {
        LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory)
      }.value
      guard modelPath == modelDirectory.path(percentEncoded: false) else {
        return
      }
      modelGenerationConfigPreset = preset
    }
  }

  // Test-only convenience; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func loadSelectedModel() {
    modelPath = selectedModel.localPath
    refreshModelGenerationConfigPreset()
    loadModel()
  }

  func loadModel() {
    guard !downloadState.isDownloading else {
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
    let reasoningTraceFormat = selectedModel.reasoningTraceFormat

    loadTask = Task {
      await runtimeOperations.setCurrentOperation(operationID)
      modelState = .loading

      do {
        try await lifecycleCoordinator.loadModel(
          from: directoryURL,
          requestedContextTokenLimit: requestedContextTokenLimit,
          supportsImageInput: supportsImageInput,
          reasoningTraceFormat: reasoningTraceFormat,
          operationID: operationID
        )
        try Task.checkCancellation()
        guard await runtimeOperations.isCurrent(operationID), operationID == modelOperationID else {
          return
        }
        modelState = .ready
        await onContextUsageShouldRefresh?()
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
        loadTask = nil
      }
    }
  }

  func unloadModel() {
    let operationID = UUID()
    modelOperationID = operationID
    loadTask?.cancel()
    modelState = .notLoaded
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
        loadTask = nil
      }
    }
  }

  private func unloadRuntimeForModelSwitch() {
    let operationID = UUID()
    modelOperationID = operationID
    modelState = .notLoaded
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
    }
  }

  private static func normalizedDownloadProgress(_ progress: Progress) -> Double? {
    let fraction = progress.fractionCompleted
    guard fraction.isFinite else {
      return nil
    }

    return min(max(fraction, 0), 1)
  }

}
