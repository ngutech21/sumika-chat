import Observation
import SumikaCore

@MainActor
@Observable
final class ModelManagementFeatureState {
  @ObservationIgnored private let modelController: ModelRuntimeController
  private let chatController: ChatSessionController

  init(
    modelController: ModelRuntimeController,
    chatController: ChatSessionController
  ) {
    self.modelController = modelController
    self.chatController = chatController
  }

  var state: ModelManagementState {
    modelController.state
  }

  var modeSettings: ChatModeSettingsSet {
    chatController.modeSettings
  }

  var errorMessage: String? {
    chatController.errorMessage
  }

  var downloadedModels: [ManagedModel] {
    state.availableModels.filter(state.isModelDownloaded)
  }

  var canChangeModel: Bool {
    !chatController.isGenerating && state.canChangeModel
  }

  var canSend: Bool {
    state.modelState == .ready && !chatController.isGenerating
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
    modelController.prepareDefaultModelDirectory()
    modelController.startResourceMonitoring()
  }

  func selectModel(_ model: ManagedModel) {
    selectModel(
      model,
      shouldInvalidateContext: state.selectedModel.id != model.id
    )
  }

  func selectConversationModel(_ model: ManagedModel) {
    selectModel(model, shouldInvalidateContext: true)
  }

  private func selectModel(
    _ model: ManagedModel,
    shouldInvalidateContext: Bool
  ) {
    guard canChangeModel else {
      return
    }

    chatController.prepareForModelRuntimeAction(
      cancelGeneration: false,
      invalidateContext: shouldInvalidateContext
    )
    modelController.selectModel(model)
  }

  func performPrimaryAction() {
    switch primaryAction {
    case .download:
      chatController.prepareForModelRuntimeAction(
        cancelGeneration: false,
        invalidateContext: false
      )
      modelController.downloadSelectedModel()
    case .load:
      chatController.prepareForModelRuntimeAction(
        cancelGeneration: false,
        invalidateContext: true
      )
      modelController.loadSelectedModel()
    case .unload:
      chatController.prepareForModelRuntimeAction(
        cancelGeneration: true,
        invalidateContext: true
      )
      modelController.unloadModel()
    }
  }

  func loadAvailableModelForConversation() {
    chatController.prepareForModelRuntimeAction(
      cancelGeneration: false,
      invalidateContext: true
    )
    guard let availableModel = preferredDownloadedModel else {
      chatController.errorMessage = "Download a model from Models first."
      return
    }

    if state.selectedModel.id != availableModel.id {
      modelController.selectModel(availableModel)
    }
    modelController.loadSelectedModel()
  }

  func updateModeSettings(_ modeSettings: ChatModeSettingsSet) {
    guard chatController.updateModeSettings(modeSettings) else {
      return
    }
    modelController.saveSelectedModelSettings(modeSettings: modeSettings)
  }

  func updateContextTokenLimit(_ limit: Int) {
    guard state.modelContextTokenLimit != limit else {
      return
    }
    modelController.setContextTokenLimit(limit)
    modelController.saveSelectedModelSettings(modeSettings: modeSettings)
  }

  func isSelectedModelDownloaded() -> Bool {
    modelController.isSelectedModelDownloaded()
  }

  func loadSelectedModelForStartup() {
    modelController.loadSelectedModel()
  }

  private var preferredDownloadedModel: ManagedModel? {
    if state.isModelDownloaded(state.selectedModel) {
      return state.selectedModel
    }

    return downloadedModels.first
  }
}

#if DEBUG
  extension ModelManagementFeatureState {
    func setModelLoadStateForTesting(_ state: ModelLoadState) {
      modelController.setModelLoadStateForTesting(state)
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
