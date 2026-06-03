import Foundation
import Observation

@MainActor
@Observable
public final class ModelRuntimeController {
  public var availableModels = ManagedModelCatalog.models
  public var selectedModelID: ManagedModel.ID
  public var downloadState: ModelDownloadState = .idle
  public var downloadProgress: Double?
  public var modelPath: String
  public var modelState: ModelLoadState = .notLoaded
  public var modelContextTokenLimit = ManagedModelCatalog.defaultContextTokenLimit
  public var processUsage: ProcessResourceUsage?
  public var modelAvailabilitySnapshot: [ManagedModel.ID: Bool] = [:]

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

  public var selectedModel: ManagedModel {
    availableModels.first { $0.id == selectedModelID } ?? ManagedModelCatalog.defaultModel
  }

  public var canChangeModel: Bool {
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
    self.init(
      selectedModelID: ManagedModelCatalog.defaultModel.id,
      modelPath: ManagedModelCatalog.defaultModel.localPath,
      modelContextTokenLimit: ManagedModelCatalog.defaultModel.defaultContextTokenLimit,
      modelSettingsStore: settingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: modelLifecycleCoordinator,
      resourceMonitor: resourceMonitor,
      initialOperationID: initialOperationID
    )
    loadPersistedModelSelection()
  }

  public init(
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

  public func currentOperationID() -> UUID {
    modelOperationID
  }

  public func prepareDefaultModelDirectory() {
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

  public func startResourceMonitoring() {
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

  public func setModelDirectory(_ url: URL) {
    modelPath = url.path(percentEncoded: false)
    modelState = .notLoaded
  }

  public func selectModel(_ model: ManagedModel) {
    guard canChangeModel, selectedModelID != model.id else {
      return
    }

    unloadModel()
    selectedModelID = model.id
    modelPath = model.localPath
    downloadState = .idle
    downloadProgress = nil
    modelContextTokenLimit = model.defaultContextTokenLimit

    Task { [modelSettingsStore] in
      await modelSettingsStore.setSelectedModelID(model.id)
      let settings = await modelSettingsStore.settings(for: model)
      guard selectedModelID == model.id else {
        return
      }
      modelContextTokenLimit = settings.contextTokenLimit
      onModelDidChange?(settings)
    }
  }

  public func applySessionModel(_ model: ManagedModel) -> Bool {
    let shouldUnloadRuntime = selectedModelID != model.id && modelState != .notLoaded

    loadTask?.cancel()
    loadTask = nil
    selectedModelID = model.id
    modelPath = model.localPath
    downloadState = .idle
    downloadProgress = nil
    modelContextTokenLimit = model.defaultContextTokenLimit

    Task { [modelSettingsStore] in
      let settings = await modelSettingsStore.settings(for: model)
      guard selectedModelID == model.id else {
        return
      }
      modelContextTokenLimit = settings.contextTokenLimit
    }

    if shouldUnloadRuntime {
      unloadRuntimeForModelSwitch()
    }

    return shouldUnloadRuntime
  }

  public func isModelDownloaded(_ model: ManagedModel) -> Bool {
    modelAvailabilitySnapshot[model.id] ?? false
  }

  public func refreshModelAvailability() {
    let models = availableModels
    let lifecycleCoordinator = modelLifecycleCoordinator
    Task {
      let snapshot = await Task.detached {
        lifecycleCoordinator.modelAvailabilitySnapshot(for: models)
      }.value
      modelAvailabilitySnapshot = snapshot
    }
  }

  public func downloadSelectedModel() {
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

  public func saveSelectedModelSettings(
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    let settings = StoredModelSettings(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings,
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

  public func loadPersistedModelSelection(notifyModelDidChange: Bool = false) {
    Task { [modelSettingsStore] in
      let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
      let selectedModelID = await modelSettingsStore.selectedModelID(
        availableModelIDs: availableModelIDs)
      let selectedModel =
        ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
      let settings = await modelSettingsStore.settings(for: selectedModel)

      guard canChangeModel else {
        return
      }

      self.selectedModelID = selectedModel.id
      modelPath = selectedModel.localPath
      modelContextTokenLimit = settings.contextTokenLimit
      if notifyModelDidChange {
        onModelDidChange?(settings)
      }
    }
  }

  public func loadSelectedModel() {
    modelPath = selectedModel.localPath
    loadModel()
  }

  public func loadModel() {
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

  public func unloadModel() {
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
