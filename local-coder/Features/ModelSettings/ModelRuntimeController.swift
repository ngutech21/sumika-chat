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
  var processUsage: ProcessResourceUsage?
  var modelAvailabilitySnapshot: [ManagedModel.ID: Bool] = [:]

  @ObservationIgnored private let runtimeOperations: RuntimeOperationCoordinator
  @ObservationIgnored private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  @ObservationIgnored private let resourceMonitor: any ProcessResourceMonitoring
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var modelOperationID: UUID
  @ObservationIgnored private var resourceMonitorTask: Task<Void, Never>?

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

  convenience init(
    modelSettingsStore settingsStore: any ModelSettingsStoring,
    modelDownloader downloader: any ModelDownloading,
    runtimeOperations: RuntimeOperationCoordinator,
    modelLifecycleCoordinator: ModelLifecycleCoordinator,
    resourceMonitor: any ProcessResourceMonitoring,
    initialOperationID: UUID
  ) {
    let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
    let selectedModelID = settingsStore.selectedModelID(availableModelIDs: availableModelIDs)
    let selectedModel =
      ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
    let storedSettings = settingsStore.settings(for: selectedModel)
    self.init(
      selectedModelID: selectedModel.id,
      modelPath: selectedModel.localPath,
      modelContextTokenLimit: storedSettings.contextTokenLimit,
      modelSettingsStore: settingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: modelLifecycleCoordinator,
      resourceMonitor: resourceMonitor,
      initialOperationID: initialOperationID
    )
  }

  init(
    selectedModelID: ManagedModel.ID,
    modelPath: String,
    modelContextTokenLimit: Int,
    modelSettingsStore: any ModelSettingsStoring,
    runtimeOperations: RuntimeOperationCoordinator,
    modelLifecycleCoordinator: ModelLifecycleCoordinator,
    resourceMonitor: any ProcessResourceMonitoring,
    initialOperationID: UUID
  ) {
    self.selectedModelID = selectedModelID
    self.modelPath = modelPath
    self.modelContextTokenLimit = modelContextTokenLimit
    self.modelSettingsStore = modelSettingsStore
    self.runtimeOperations = runtimeOperations
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
    self.resourceMonitor = resourceMonitor
    self.modelOperationID = initialOperationID
    refreshModelAvailability()
  }

  deinit {
    loadTask?.cancel()
    downloadTask?.cancel()
    resourceMonitorTask?.cancel()
  }

  func currentOperationID() -> UUID {
    modelOperationID
  }

  func prepareDefaultModelDirectory() {
    let lifecycleCoordinator = modelLifecycleCoordinator
    Task {
      do {
        let baseURL = try await Task.detached {
          try lifecycleCoordinator.ensureDefaultModelDirectoryExists()
        }.value
        if modelPath.isEmpty {
          modelPath = selectedModel.localPath
        } else if !modelPath.hasPrefix(baseURL.path(percentEncoded: false)) {
          modelPath = selectedModel.localPath
        }
        refreshModelAvailability()
      } catch {
        onError?(error.localizedDescription)
      }
    }
  }

  func startResourceMonitoring() {
    guard resourceMonitorTask == nil else {
      return
    }

    resourceMonitorTask = Task {
      while !Task.isCancelled {
        processUsage = await resourceMonitor.currentUsage()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func setModelDirectory(_ url: URL) {
    modelPath = url.path(percentEncoded: false)
    modelState = .notLoaded
  }

  func selectModel(_ model: ManagedModel) {
    guard canChangeModel, selectedModelID != model.id else {
      return
    }

    unloadModel()
    selectedModelID = model.id
    modelSettingsStore.setSelectedModelID(model.id)
    modelPath = model.localPath
    downloadState = .idle
    downloadProgress = nil

    let settings = modelSettingsStore.settings(for: model)
    modelContextTokenLimit = settings.contextTokenLimit
    onModelDidChange?(settings)
  }

  func applySessionModel(_ model: ManagedModel) -> Bool {
    let shouldUnloadRuntime = selectedModelID != model.id && modelState != .notLoaded

    loadTask?.cancel()
    loadTask = nil
    selectedModelID = model.id
    modelPath = model.localPath
    downloadState = .idle
    downloadProgress = nil
    modelContextTokenLimit = modelSettingsStore.settings(for: model).contextTokenLimit

    if shouldUnloadRuntime {
      unloadRuntimeForModelSwitch()
    }

    return shouldUnloadRuntime
  }

  func isModelDownloaded(_ model: ManagedModel) -> Bool {
    modelAvailabilitySnapshot[model.id] ?? false
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

  func saveSelectedModelSettings(
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    let settings = StoredModelSettings(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings,
      contextTokenLimit: modelContextTokenLimit
    )

    do {
      try modelSettingsStore.save(settings: settings, for: selectedModel)
    } catch {
      onError?(error.localizedDescription)
    }
  }

  func loadSelectedModel() {
    modelPath = selectedModel.localPath
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

    loadTask = Task {
      await runtimeOperations.setCurrentOperation(operationID)
      modelState = .loading

      do {
        _ = try await lifecycleCoordinator.loadModel(
          from: directoryURL,
          requestedContextTokenLimit: requestedContextTokenLimit,
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
