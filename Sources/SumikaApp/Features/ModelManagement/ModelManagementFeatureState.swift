import Observation
import SumikaCore

@MainActor
@Observable
final class ModelManagementFeatureState {
  @ObservationIgnored private let models: ModelManagementFeature

  init(models: ModelManagementFeature) {
    self.models = models
  }

  var state: ModelManagementState {
    models.state
  }

  var modeSettings: ChatModeSettingsSet {
    models.modeSettings
  }

  var errorMessage: String? {
    models.errorMessage
  }

  var downloadedModels: [ManagedModel] {
    state.availableModels.filter(state.isModelDownloaded)
  }

  var canChangeModel: Bool {
    models.canChangeModel
  }

  var canSend: Bool {
    models.canSend
  }

  var effectiveDownloadState: ModelDownloadState {
    if state.isModelDownloaded(state.selectedModel),
      !state.downloadState.isDownloading
    {
      return .downloaded
    }

    return state.downloadState
  }

  var primaryAction: ModelManagementPrimaryAction {
    if !state.isModelDownloaded(state.selectedModel) {
      return .download
    }

    return state.modelState == .ready ? .unload : .load
  }

  var isPrimaryActionDisabled: Bool {
    switch primaryAction {
    case .download:
      return !canChangeModel || state.downloadState.isDownloading
    case .load, .unload:
      return state.modelState == .loading || state.downloadState.isDownloading
    }
  }

  func startRuntimeServices() {
    models.startRuntimeServices()
  }

  func selectModel(_ model: ManagedModel) {
    models.selectModel(model)
  }

  func selectConversationModel(_ model: ManagedModel) {
    models.selectConversationModel(model)
  }

  func performPrimaryAction() {
    switch primaryAction {
    case .download:
      models.downloadSelectedModel()
    case .load:
      models.loadSelectedModel()
    case .unload:
      models.unloadModel()
    }
  }

  func loadAvailableModelForConversation() {
    _ = models.loadAvailableModelForConversation()
  }

  func updateModeSettings(_ modeSettings: ChatModeSettingsSet) {
    models.updateModeSettings(modeSettings)
  }

  func updateContextTokenLimit(_ limit: Int) {
    models.updateContextTokenLimit(limit)
  }

  func isSelectedModelDownloaded() -> Bool {
    models.isSelectedModelDownloaded()
  }

  func loadSelectedModelForStartup() {
    models.loadSelectedModel()
  }
}

#if DEBUG
  extension ModelManagementFeatureState {
    func setModelLoadStateForTesting(_ state: ModelLoadState) {
      models.setModelLoadStateForTesting(state)
    }
  }
#endif

enum ModelManagementPrimaryAction: Equatable {
  case download
  case load
  case unload

  var title: String {
    switch self {
    case .download:
      "Download"
    case .load:
      "Load"
    case .unload:
      "Unload"
    }
  }

  var systemImage: String {
    switch self {
    case .download:
      "square.and.arrow.down"
    case .load:
      "play.fill"
    case .unload:
      "eject"
    }
  }
}
