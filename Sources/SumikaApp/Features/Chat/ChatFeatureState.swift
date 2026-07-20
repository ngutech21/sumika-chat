import Foundation
import Observation
import SumikaCore

struct ChatComposerPresentation: Equatable {
  let session: ChatComposerSessionState
  let isGenerating: Bool
  let contextUsage: ChatContextUsage?
  let errorMessage: String?
  let canChangeInteractionMode: Bool
  let canChangeMCPServerSelection: Bool
  let canEnableAutomaticToolApproval: Bool
}

struct ChatTranscriptPresentation: Equatable {
  let sessionID: ChatSession.ID
  let turns: [ChatTurn]
  let isGenerating: Bool
  let toolApprovalPolicy: ToolApprovalPolicy
}

struct ChatModelContextDebugPresentation: Equatable {
  let state: ModelContextDebugState
}

@MainActor
@Observable
final class ChatFeatureState {
  @ObservationIgnored private let engine: ConversationEngine

  init(engine: ConversationEngine) {
    self.engine = engine
  }

  var composer: ChatComposerPresentation {
    ChatComposerPresentation(
      session: engine.composerSessionState,
      isGenerating: engine.isGenerating,
      contextUsage: engine.contextUsage,
      errorMessage: engine.errorMessage,
      canChangeInteractionMode: engine.canChangeInteractionMode,
      canChangeMCPServerSelection: engine.canChangeMCPServerSelection,
      canEnableAutomaticToolApproval: engine.canEnableAutomaticToolApproval
    )
  }

  var transcript: ChatTranscriptPresentation {
    ChatTranscriptPresentation(
      sessionID: engine.sessionID,
      turns: engine.turns,
      isGenerating: engine.isGenerating,
      toolApprovalPolicy: engine.composerSessionState.toolApprovalPolicy
    )
  }

  var modelContextDebug: ChatModelContextDebugPresentation {
    ChatModelContextDebugPresentation(state: engine.modelContextDebugState)
  }

  func setInteractionMode(_ mode: WorkspaceInteractionMode) {
    engine.setInteractionMode(mode)
  }

  func setReasoningEnabled(_ isEnabled: Bool) {
    engine.setReasoningEnabled(isEnabled)
  }

  func enableAutomaticToolApproval(
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    engine.enableAutomaticToolApproval(in: toolWorkspace(in: context, sessionID: sessionID))
  }

  func disableAutomaticToolApproval() {
    engine.disableAutomaticToolApproval()
  }

  func addAttachments(from urls: [URL]) {
    engine.addAttachments(from: urls)
  }

  func removeAttachment(id: ChatAttachment.ID) {
    engine.removeAttachment(id: id)
  }

  func cancelGeneration() {
    engine.cancelGeneration()
  }

  func approveToolCall(
    id toolCallID: ToolCallRecord.ID,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    engine.approveToolCall(
      id: toolCallID,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    engine.approveToolCallBatch(
      containing: batchAnchorID,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func resumeAutomaticApprovalBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    engine.resumeAutomaticApprovalBatch(
      containing: batchAnchorID,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func denyToolCall(id toolCallID: ToolCallRecord.ID) {
    engine.denyToolCall(id: toolCallID)
  }

  func answerAskUserToolCall(
    id toolCallID: ToolCallRecord.ID,
    answer: String,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    engine.answerAskUserToolCall(
      id: toolCallID,
      answer: answer,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func modelContextDebugDocument(
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) throws -> ModelContextDebugDocument {
    try engine.modelContextDebugDocument(
      workspace: context.workspace(containing: sessionID ?? engine.sessionID),
      sessionID: sessionID
    )
  }

  private func toolWorkspace(
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) -> Workspace {
    context.workspace(containing: sessionID ?? engine.sessionID)
  }

  #if DEBUG
    func refreshContextUsageForTesting() {
      engine.refreshContextUsage()
    }

    var sessionSnapshotForTesting: ChatSession {
      engine.sessionSnapshot()
    }
  #endif
}
