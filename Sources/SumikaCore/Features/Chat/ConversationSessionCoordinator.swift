import Foundation

@MainActor
package final class ConversationSessionCoordinator {
  private let modelController: ModelRuntimeController
  private let conversationEngine: ConversationEngine

  package init(
    modelController: ModelRuntimeController,
    conversationEngine: ConversationEngine
  ) {
    self.modelController = modelController
    self.conversationEngine = conversationEngine
  }

  package func switchSession(to session: ChatSession) {
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
