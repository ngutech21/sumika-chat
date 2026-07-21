import Foundation

package struct ConversationFeatureState: Equatable, Sendable {
  package let composer: ChatComposerSessionState
  package let sessionID: ChatSession.ID
  package let turns: [ChatTurn]
  package let modeSettings: ChatModeSettingsSet
  package let isGenerating: Bool
  package let contextUsage: ChatContextUsage?
  package let errorMessage: String?
  package let modelContextDebug: ModelContextDebugState
  package let canChangeInteractionMode: Bool
  package let canChangeMCPServerSelection: Bool
  package let canEnableAutomaticToolApproval: Bool
}

/// The package-visible conversation interface. Turn execution and lifecycle
/// coordination stay behind this seam in `ConversationEngine`.
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
    ConversationFeatureState(
      composer: engine.composerSessionState,
      sessionID: engine.sessionID,
      turns: engine.turns,
      modeSettings: engine.modeSettings,
      isGenerating: engine.isGenerating,
      contextUsage: engine.contextUsage,
      errorMessage: engine.errorMessage,
      modelContextDebug: engine.modelContextDebugState,
      canChangeInteractionMode: engine.canChangeInteractionMode,
      canChangeMCPServerSelection: engine.canChangeMCPServerSelection,
      canEnableAutomaticToolApproval: engine.canEnableAutomaticToolApproval
    )
  }

  package func activate(_ session: ChatSession) {
    sessionCoordinator.switchSession(to: session)
  }

  package func setSessionChangeHandler(
    _ handler: (@MainActor @Sendable (ChatSession) -> Void)?
  ) {
    guard let handler else {
      engine.setSessionChangeHandler(nil)
      return
    }
    engine.setSessionChangeHandler { [weak engine] in
      guard let engine else {
        return
      }
      handler(engine.sessionSnapshot())
    }
  }

  @discardableResult
  package func sendMessage(
    prompt: String,
    in workspace: Workspace,
    sessionID: ChatSession.ID
  ) -> Bool {
    engine.sendMessage(prompt: prompt, in: workspace, sessionID: sessionID)
  }

  @discardableResult
  package func renameSession(to title: String) -> Bool {
    engine.renameSession(to: title)
  }

  package func setInteractionMode(_ mode: WorkspaceInteractionMode) {
    engine.setInteractionMode(mode)
  }

  package func setReasoningEnabled(_ isEnabled: Bool) {
    engine.setReasoningEnabled(isEnabled)
  }

  package func enableAutomaticToolApproval(in workspace: Workspace) {
    engine.enableAutomaticToolApproval(in: workspace)
  }

  package func disableAutomaticToolApproval() {
    engine.disableAutomaticToolApproval()
  }

  package func addAttachments(from urls: [URL]) {
    engine.addAttachments(from: urls)
  }

  package func removeAttachment(id: ChatAttachment.ID) {
    engine.removeAttachment(id: id)
  }

  package func cancelGeneration() {
    engine.cancelGeneration()
  }

  package func approveToolCall(id: ToolCallRecord.ID, in workspace: Workspace) {
    engine.approveToolCall(id: id, in: workspace)
  }

  package func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace
  ) {
    engine.approveToolCallBatch(containing: batchAnchorID, in: workspace)
  }

  package func resumeAutomaticApprovalBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace
  ) {
    engine.resumeAutomaticApprovalBatch(containing: batchAnchorID, in: workspace)
  }

  package func denyToolCall(id: ToolCallRecord.ID) {
    engine.denyToolCall(id: id)
  }

  package func answerAskUserToolCall(
    id: ToolCallRecord.ID,
    answer: String,
    in workspace: Workspace
  ) {
    engine.answerAskUserToolCall(id: id, answer: answer, in: workspace)
  }

  package func modelContextDebugDocument(
    workspace: Workspace?,
    sessionID: ChatSession.ID?
  ) throws -> ModelContextDebugDocument {
    try engine.modelContextDebugDocument(workspace: workspace, sessionID: sessionID)
  }

  package func snapshot() -> ChatSession {
    engine.sessionSnapshot()
  }

  #if DEBUG
    package func refreshContextUsageForTesting() {
      engine.refreshContextUsage()
    }
  #endif
}
