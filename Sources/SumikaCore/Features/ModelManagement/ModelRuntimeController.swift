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
  public var modelGenerationConfigPreset: ChatGenerationConfigPreset?
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
  private static let resourceMonitorInterval: Duration = .seconds(5)
  private static let resourceMemoryPublishThresholdBytes: UInt64 = 16 * 1024 * 1024
  private static let resourceCPUPublishThreshold = 1.0

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
    refreshModelGenerationConfigPreset()
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

  public func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    try? await runtimeOperations.runtimeCacheDebugSnapshot(operationID: modelOperationID)
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
        refreshModelGenerationConfigPreset()
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
        let usage = await resourceMonitor.currentUsage()
        if shouldPublishResourceUsage(usage) {
          processUsage = usage
        }
        try? await Task.sleep(for: Self.resourceMonitorInterval)
      }
    }
  }

  public func setModelDirectory(_ url: URL) {
    modelPath = url.path(percentEncoded: false)
    modelState = .notLoaded
    refreshModelGenerationConfigPreset()
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
    modelGenerationConfigPreset = nil
    modelAvailabilitySnapshot[model.id] = modelLifecycleCoordinator.isModelDownloaded(model)

    Task { [modelSettingsStore] in
      await modelSettingsStore.setSelectedModelID(model.id)
      let settings = await modelSettingsStore.settings(for: model)
      guard selectedModelID == model.id else {
        return
      }
      modelContextTokenLimit = settings.contextTokenLimit
      refreshModelGenerationConfigPreset()
      onModelDidChange?(settings)
    }
  }

  public func applySessionModel(_ model: ManagedModel) -> Bool {
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
      refreshModelGenerationConfigPreset()
    }

    if shouldUnloadRuntime {
      unloadRuntimeForModelSwitch()
    }

    return shouldUnloadRuntime
  }

  public func isModelDownloaded(_ model: ManagedModel) -> Bool {
    modelAvailabilitySnapshot[model.id] ?? false
  }

  public func isSelectedModelDownloaded() -> Bool {
    let model = selectedModel
    let isDownloaded = modelLifecycleCoordinator.isModelDownloaded(model)
    modelAvailabilitySnapshot[model.id] = isDownloaded
    return isDownloaded
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

  public func saveSelectedModelSettings(modeSettings: ChatModeSettingsSet) {
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

  public func saveSelectedModelSettings(
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) {
    let settings = ChatModeSettings(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings
    )
    saveSelectedModelSettings(
      modeSettings: ChatModeSettingsSet(chat: settings, agent: settings)
    )
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
      refreshModelGenerationConfigPreset()
      if notifyModelDidChange {
        onModelDidChange?(settings)
      }
    }
  }

  public func loadSelectedModel() {
    modelPath = selectedModel.localPath
    refreshModelGenerationConfigPreset()
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

  private func shouldPublishResourceUsage(_ usage: ProcessResourceUsage?) -> Bool {
    guard let currentUsage = processUsage else {
      return usage != nil
    }
    guard let usage else {
      return true
    }

    let memoryDelta =
      currentUsage.memoryBytes > usage.memoryBytes
      ? currentUsage.memoryBytes - usage.memoryBytes
      : usage.memoryBytes - currentUsage.memoryBytes
    let cpuDelta = abs(currentUsage.cpuPercent - usage.cpuPercent)

    return memoryDelta >= Self.resourceMemoryPublishThresholdBytes
      || cpuDelta >= Self.resourceCPUPublishThreshold
  }
}
