import Foundation

@MainActor
final class ConversationSessionCoordinator {
  private let modelController: ModelRuntimeController
  private let conversationEngine: ConversationEngine

  init(
    modelController: ModelRuntimeController,
    conversationEngine: ConversationEngine
  ) {
    self.modelController = modelController
    self.conversationEngine = conversationEngine
  }

  func switchSession(to session: ChatSession) {
    conversationEngine.cancelGenerationForSessionSwitch()

    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel
    let didResetModelRuntime = modelController.applySessionModel(model)

    conversationEngine.installSession(
      session,
      modelRuntimeWasReset: didResetModelRuntime
    )
  }
}
