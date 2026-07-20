import Observation
import SumikaCore

@MainActor
@Observable
final class ModelManagementFeatureState {
  private let chatController: ChatSessionController

  init(chatController: ChatSessionController) {
    self.chatController = chatController
  }

  var state: ModelManagementState {
    chatController.modelRuntime.state
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
    chatController.modelRuntime.prepareDefaultModelDirectory()
    chatController.modelRuntime.startResourceMonitoring()
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
    chatController.modelRuntime.selectModel(model)
  }

  func performPrimaryAction() {
    switch primaryAction {
    case .download:
      chatController.prepareForModelRuntimeAction(
        cancelGeneration: false,
        invalidateContext: false
      )
      chatController.modelRuntime.downloadSelectedModel()
    case .load:
      chatController.prepareForModelRuntimeAction(
        cancelGeneration: false,
        invalidateContext: true
      )
      chatController.modelRuntime.loadSelectedModel()
    case .unload:
      chatController.prepareForModelRuntimeAction(
        cancelGeneration: true,
        invalidateContext: true
      )
      chatController.modelRuntime.unloadModel()
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
      chatController.modelRuntime.selectModel(availableModel)
    }
    chatController.modelRuntime.loadSelectedModel()
  }

  func setContextTokenLimit(_ limit: Int) {
    chatController.modelRuntime.setContextTokenLimit(limit)
  }

  func saveSelectedModelSettings(modeSettings: ChatModeSettingsSet) {
    chatController.modelRuntime.saveSelectedModelSettings(modeSettings: modeSettings)
  }

  func isSelectedModelDownloaded() -> Bool {
    chatController.modelRuntime.isSelectedModelDownloaded()
  }

  func loadSelectedModelForStartup() {
    chatController.modelRuntime.loadSelectedModel()
  }

  private var preferredDownloadedModel: ManagedModel? {
    if state.isModelDownloaded(state.selectedModel) {
      return state.selectedModel
    }

    return downloadedModels.first
  }
}

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
