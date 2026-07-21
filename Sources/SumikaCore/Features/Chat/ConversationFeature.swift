import Foundation

package enum ConversationActivity: Equatable, Sendable {
  case idle
  case working
  case awaitingApproval
  case awaitingUserAnswer

  package var isBusy: Bool {
    self != .idle
  }
}

package struct ActiveConversationState: Equatable, Sendable {
  package let workspaceID: Workspace.ID
  package let sessionID: ChatSession.ID
  package let composer: ChatComposerSessionState
  package let turns: [ChatTurn]
  package let activity: ConversationActivity
  package let isGenerating: Bool
  package let contextUsage: ChatContextUsage?
  package let errorMessage: String?
  package let modelContextDebug: ModelContextDebugState
  package let canChangeInteractionMode: Bool
  package let canChangeMCPServerSelection: Bool
  package let canEnableAutomaticToolApproval: Bool
}

package enum ConversationFeatureState: Equatable, Sendable {
  case inactive
  case active(ActiveConversationState)

  package var active: ActiveConversationState? {
    guard case .active(let state) = self else {
      return nil
    }
    return state
  }
}

package enum ConversationIntentError: LocalizedError, Equatable, Sendable {
  case inactive
  case sessionNotFound(workspaceID: Workspace.ID, sessionID: ChatSession.ID)
  case sessionCreationFailed(workspaceID: Workspace.ID)
  case busy(workspaceID: Workspace.ID, sessionID: ChatSession.ID)
  case emptyPrompt
  case modelNotReady
  case unsupportedInteractionMode
  case unsupportedImageInput

  package var errorDescription: String? {
    switch self {
    case .inactive:
      "Activate a workspace conversation before performing this action."
    case .sessionNotFound:
      "The chat session does not belong to the workspace."
    case .sessionCreationFailed:
      "A chat session could not be created for the workspace."
    case .busy:
      "Another chat operation is still active."
    case .emptyPrompt:
      "Enter a message before sending."
    case .modelNotReady:
      "Load a model before sending a message."
    case .unsupportedInteractionMode:
      "The selected model does not support this interaction mode."
    case .unsupportedImageInput:
      "The selected model does not support image attachments."
    }
  }
}

/// The package-visible conversation interface. It owns activation and keeps
/// workspace/session identity out of subsequent conversation intents.
@MainActor
package final class ConversationFeature {
  private let engine: ConversationEngine
  private let sessionCoordinator: ConversationSessionCoordinator

  init(
    engine: ConversationEngine,
    sessionCoordinator: ConversationSessionCoordinator
  ) {
    self.engine = engine
    self.sessionCoordinator = sessionCoordinator
  }

  package var state: ConversationFeatureState {
    guard let workspaceID = engine.activeWorkspaceID,
      let sessionID = engine.activeSessionID
    else {
      return .inactive
    }

    return .active(
      ActiveConversationState(
        workspaceID: workspaceID,
        sessionID: sessionID,
        composer: engine.composerSessionState,
        turns: engine.turns,
        activity: engine.activity,
        isGenerating: engine.isGenerating,
        contextUsage: engine.contextUsage,
        errorMessage: engine.errorMessage,
        modelContextDebug: engine.modelContextDebugState,
        canChangeInteractionMode: engine.canChangeInteractionMode,
        canChangeMCPServerSelection: engine.canChangeMCPServerSelection,
        canEnableAutomaticToolApproval: engine.canEnableAutomaticToolApproval
      ))
  }

  package func activate(
    sessionID: ChatSession.ID,
    in workspace: Workspace
  ) throws {
    try sessionCoordinator.activate(sessionID: sessionID, in: workspace)
  }

  package func deactivate() {
    sessionCoordinator.deactivate()
  }

  package func setSessionChangeHandler(
    _ handler: (@MainActor @Sendable (Workspace.ID, ChatSession) -> Void)?
  ) {
    engine.setSessionChangeHandler(handler)
  }

  package func sendMessage(prompt: String) throws {
    try engine.sendMessage(prompt: prompt)
  }

  @discardableResult
  package func renameSession(to title: String) throws -> Bool {
    try requireActiveConversation()
    return engine.renameSession(to: title)
  }

  package func setInteractionMode(_ mode: WorkspaceInteractionMode) throws {
    try requireIdleConversation()
    engine.setInteractionMode(mode)
  }

  package func setReasoningEnabled(_ isEnabled: Bool) throws {
    try requireIdleConversation()
    engine.setReasoningEnabled(isEnabled)
  }

  package func enableAutomaticToolApproval() throws {
    try requireActiveConversation()
    engine.enableAutomaticToolApproval()
  }

  package func disableAutomaticToolApproval() throws {
    try requireActiveConversation()
    engine.disableAutomaticToolApproval()
  }

  package func addAttachments(from urls: [URL]) throws {
    try requireIdleConversation()
    engine.addAttachments(from: urls)
  }

  package func removeAttachment(id: ChatAttachment.ID) throws {
    try requireIdleConversation()
    engine.removeAttachment(id: id)
  }

  package func cancelGeneration() {
    engine.cancelGeneration()
  }

  package func approveToolCall(id: ToolCallRecord.ID) throws {
    try requireActiveConversation()
    engine.approveToolCall(id: id)
  }

  package func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID
  ) throws {
    try requireActiveConversation()
    engine.approveToolCallBatch(containing: batchAnchorID)
  }

  package func resumeAutomaticApprovalBatch(
    containing batchAnchorID: ToolCallRecord.ID
  ) throws {
    try requireActiveConversation()
    engine.resumeAutomaticApprovalBatch(containing: batchAnchorID)
  }

  package func denyToolCall(id: ToolCallRecord.ID) throws {
    try requireActiveConversation()
    engine.denyToolCall(id: id)
  }

  package func answerAskUserToolCall(
    id: ToolCallRecord.ID,
    answer: String
  ) throws {
    try requireActiveConversation()
    engine.answerAskUserToolCall(id: id, answer: answer)
  }

  package func modelContextDebugDocument() throws -> ModelContextDebugDocument {
    try requireActiveConversation()
    return try engine.modelContextDebugDocument()
  }

  package func snapshot() -> ChatSession? {
    engine.activeSessionSnapshot()
  }

  #if DEBUG
    package func refreshContextUsageForTesting() {
      engine.refreshContextUsage()
    }
  #endif

  private func requireActiveConversation() throws {
    guard engine.hasActiveConversation else {
      throw ConversationIntentError.inactive
    }
  }

  private func requireIdleConversation() throws {
    try requireActiveConversation()
    guard !engine.activity.isBusy else {
      throw engine.busyError
    }
  }
}
