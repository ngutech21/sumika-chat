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
  @ObservationIgnored private let conversation: ConversationFeature

  init(conversation: ConversationFeature) {
    self.conversation = conversation
  }

  var composer: ChatComposerPresentation {
    let state = conversation.state
    return ChatComposerPresentation(
      session: state.composer,
      isGenerating: state.isGenerating,
      contextUsage: state.contextUsage,
      errorMessage: state.errorMessage,
      canChangeInteractionMode: state.canChangeInteractionMode,
      canChangeMCPServerSelection: state.canChangeMCPServerSelection,
      canEnableAutomaticToolApproval: state.canEnableAutomaticToolApproval
    )
  }

  var transcript: ChatTranscriptPresentation {
    let state = conversation.state
    return ChatTranscriptPresentation(
      sessionID: state.sessionID,
      turns: state.turns,
      isGenerating: state.isGenerating,
      toolApprovalPolicy: state.composer.toolApprovalPolicy
    )
  }

  var modelContextDebug: ChatModelContextDebugPresentation {
    ChatModelContextDebugPresentation(state: conversation.state.modelContextDebug)
  }

  func setInteractionMode(_ mode: WorkspaceInteractionMode) {
    conversation.setInteractionMode(mode)
  }

  func setReasoningEnabled(_ isEnabled: Bool) {
    conversation.setReasoningEnabled(isEnabled)
  }

  func enableAutomaticToolApproval(
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    conversation.enableAutomaticToolApproval(in: toolWorkspace(in: context, sessionID: sessionID))
  }

  func disableAutomaticToolApproval() {
    conversation.disableAutomaticToolApproval()
  }

  func addAttachments(from urls: [URL]) {
    conversation.addAttachments(from: urls)
  }

  func removeAttachment(id: ChatAttachment.ID) {
    conversation.removeAttachment(id: id)
  }

  func cancelGeneration() {
    conversation.cancelGeneration()
  }

  func approveToolCall(
    id toolCallID: ToolCallRecord.ID,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    conversation.approveToolCall(
      id: toolCallID,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    conversation.approveToolCallBatch(
      containing: batchAnchorID,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func resumeAutomaticApprovalBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    conversation.resumeAutomaticApprovalBatch(
      containing: batchAnchorID,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func denyToolCall(id toolCallID: ToolCallRecord.ID) {
    conversation.denyToolCall(id: toolCallID)
  }

  func answerAskUserToolCall(
    id toolCallID: ToolCallRecord.ID,
    answer: String,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) {
    conversation.answerAskUserToolCall(
      id: toolCallID,
      answer: answer,
      in: toolWorkspace(in: context, sessionID: sessionID)
    )
  }

  func modelContextDebugDocument(
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) throws -> ModelContextDebugDocument {
    try conversation.modelContextDebugDocument(
      workspace: context.workspace(containing: sessionID ?? conversation.state.sessionID),
      sessionID: sessionID
    )
  }

  private func toolWorkspace(
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) -> Workspace {
    context.workspace(containing: sessionID ?? conversation.state.sessionID)
  }

  #if DEBUG
    func refreshContextUsageForTesting() {
      conversation.refreshContextUsageForTesting()
    }

    var sessionSnapshotForTesting: ChatSession {
      conversation.snapshot()
    }
  #endif
}
