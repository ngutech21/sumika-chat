import Foundation

@MainActor
package final class ConversationSessionCoordinator {
  private let modelController: ModelRuntimeController
  private let chatController: ChatSessionController

  package init(
    modelController: ModelRuntimeController,
    chatController: ChatSessionController
  ) {
    self.modelController = modelController
    self.chatController = chatController
  }

  package func switchSession(to session: ChatSession) {
    chatController.cancelGenerationForSessionSwitch()

    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel
    let didResetModelRuntime = modelController.applySessionModel(model)

    chatController.installSession(
      session,
      modelRuntimeWasReset: didResetModelRuntime
    )
  }
}
