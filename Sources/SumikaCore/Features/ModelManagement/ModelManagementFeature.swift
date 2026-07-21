import Foundation
import Observation

/// The package-visible model-management interface. It owns every sequencing
/// decision between model operations and the active conversation.
@MainActor
@Observable
package final class ModelManagementFeature {
  @ObservationIgnored private let modelController: ModelRuntimeController
  @ObservationIgnored private let conversationEngine: ConversationEngine
  package private(set) var errorMessage: String?

  init(
    modelController: ModelRuntimeController,
    conversationEngine: ConversationEngine
  ) {
    self.modelController = modelController
    self.conversationEngine = conversationEngine
  }

  package var state: ModelManagementState {
    modelController.state
  }

  package var modeSettings: ChatModeSettingsSet {
    conversationEngine.modeSettings
  }

  package var canChangeModel: Bool {
    !conversationEngine.isGenerating && state.canChangeModel
  }

  package var canSend: Bool {
    state.modelState == .ready && !conversationEngine.isGenerating
  }

  package func startRuntimeServices() {
    modelController.prepareDefaultModelDirectory()
    modelController.startResourceMonitoring()
  }

  package func selectModel(_ model: ManagedModel) {
    selectModel(
      model,
      shouldInvalidateContext: state.selectedModel.id != model.id
    )
  }

  package func selectConversationModel(_ model: ManagedModel) {
    selectModel(model, shouldInvalidateContext: true)
  }

  package func downloadSelectedModel() {
    prepareForModelOperation(cancelGeneration: false, invalidateContext: false)
    modelController.downloadSelectedModel()
  }

  package func loadSelectedModel() {
    prepareForModelOperation(cancelGeneration: false, invalidateContext: true)
    modelController.loadModel()
  }

  package func unloadModel() {
    prepareForModelOperation(cancelGeneration: true, invalidateContext: true)
    modelController.unloadModel()
  }

  package func loadAvailableModelForConversation() -> Bool {
    errorMessage = nil
    guard let availableModel = preferredDownloadedModel else {
      errorMessage = "Download a model from Models first."
      return false
    }
    conversationEngine.prepareForModelRuntimeAction(
      cancelGeneration: false,
      invalidateContext: true
    )
    if state.selectedModel.id != availableModel.id {
      modelController.selectModel(availableModel)
    }
    modelController.loadModel()
    return true
  }

  package func updateModeSettings(_ modeSettings: ChatModeSettingsSet) {
    guard conversationEngine.updateModeSettings(modeSettings) else {
      return
    }
    modelController.saveSelectedModelSettings(modeSettings: modeSettings)
  }

  package func updateContextTokenLimit(_ limit: Int) {
    guard state.modelContextTokenLimit != limit else {
      return
    }
    modelController.setContextTokenLimit(limit)
    modelController.saveSelectedModelSettings(modeSettings: modeSettings)
  }

  package func isSelectedModelDownloaded() -> Bool {
    modelController.isSelectedModelDownloaded()
  }

  package func loadPersistedModelSelection() {
    modelController.loadPersistedModelSelection()
  }

  func handleModelRuntimeError(_ message: String) {
    errorMessage = message
  }

  #if DEBUG
    package func setModelLoadStateForTesting(_ state: ModelLoadState) {
      modelController.setModelLoadStateForTesting(state)
    }
  #endif

  private func selectModel(
    _ model: ManagedModel,
    shouldInvalidateContext: Bool
  ) {
    guard canChangeModel else {
      return
    }
    prepareForModelOperation(
      cancelGeneration: false,
      invalidateContext: shouldInvalidateContext
    )
    modelController.selectModel(model)
  }

  private func prepareForModelOperation(
    cancelGeneration: Bool,
    invalidateContext: Bool
  ) {
    errorMessage = nil
    conversationEngine.prepareForModelRuntimeAction(
      cancelGeneration: cancelGeneration,
      invalidateContext: invalidateContext
    )
  }

  private var preferredDownloadedModel: ManagedModel? {
    if state.isModelDownloaded(state.selectedModel) {
      return state.selectedModel
    }
    return state.availableModels.first(where: state.isModelDownloaded)
  }
}
