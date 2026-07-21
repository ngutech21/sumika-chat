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

  func activate(
    sessionID: ChatSession.ID,
    in workspace: Workspace
  ) throws {
    guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else {
      throw ConversationIntentError.sessionNotFound(
        workspaceID: workspace.id,
        sessionID: sessionID
      )
    }

    if conversationEngine.matches(workspaceID: workspace.id, sessionID: sessionID) {
      return
    }

    guard !conversationEngine.activity.isBusy else {
      throw conversationEngine.busyError
    }

    conversationEngine.publishSessionSnapshot()

    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel
    let didResetModelRuntime = modelController.applySessionModel(model)

    conversationEngine.installConversation(
      session,
      in: workspace,
      modelRuntimeWasReset: didResetModelRuntime
    )
  }

  func deactivate() {
    conversationEngine.deactivate()
  }
}
