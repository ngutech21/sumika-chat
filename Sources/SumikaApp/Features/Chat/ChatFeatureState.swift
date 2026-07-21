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
  let sessionID: ChatSession.ID?
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
  typealias ConversationActivator = @MainActor (Workspace.ID, ChatSession.ID?) throws -> Void

  @ObservationIgnored private let conversation: ConversationFeature
  @ObservationIgnored private let workspaceState: WorkspaceFeatureState
  @ObservationIgnored private var activateConversation: ConversationActivator?
  private var intentErrorMessage: String?

  init(
    conversation: ConversationFeature,
    workspaceState: WorkspaceFeatureState
  ) {
    self.conversation = conversation
    self.workspaceState = workspaceState
  }

  func setConversationActivator(_ activator: @escaping ConversationActivator) {
    activateConversation = activator
  }

  var composer: ChatComposerPresentation {
    let selectedActiveState = selectedActiveConversationState
    let sessionState = selectedActiveState?.composer ?? selectedComposerState
    let anotherConversationIsBusy = isAnotherConversationBusy

    return ChatComposerPresentation(
      session: sessionState,
      isGenerating: selectedActiveState?.isGenerating == true,
      contextUsage: selectedActiveState?.contextUsage,
      errorMessage: intentErrorMessage
        ?? (anotherConversationIsBusy ? "Another chat operation is still active." : nil)
          ?? selectedActiveState?.errorMessage,
      canChangeInteractionMode: !anotherConversationIsBusy
        && (selectedActiveState?.canChangeInteractionMode ?? true),
      canChangeMCPServerSelection: !anotherConversationIsBusy
        && sessionState.interactionMode == .agent
        && (selectedActiveState?.canChangeMCPServerSelection ?? true),
      canEnableAutomaticToolApproval: !anotherConversationIsBusy
        && sessionState.interactionMode == .agent
        && sessionState.toolApprovalPolicy == .manual
        && (selectedActiveState?.canEnableAutomaticToolApproval ?? true)
    )
  }

  var transcript: ChatTranscriptPresentation {
    let selectedActiveState = selectedActiveConversationState
    let session = workspaceState.activeSession
    return ChatTranscriptPresentation(
      sessionID: session?.id,
      turns: selectedActiveState?.turns ?? session?.turns ?? [],
      isGenerating: selectedActiveState?.isGenerating == true,
      toolApprovalPolicy: selectedActiveState?.composer.toolApprovalPolicy
        ?? session?.toolApprovalPolicy
        ?? .manual
    )
  }

  var modelContextDebug: ChatModelContextDebugPresentation {
    ChatModelContextDebugPresentation(
      state: selectedActiveConversationState?.modelContextDebug ?? ModelContextDebugState()
    )
  }

  var busySessionID: ChatSession.ID? {
    guard let active = conversation.state.active, active.activity.isBusy else {
      return nil
    }
    return active.sessionID
  }

  @discardableResult
  func activateSelectedConversation() -> Bool {
    do {
      guard let activateConversation else {
        throw ConversationIntentError.inactive
      }
      guard let workspaceID = workspaceState.activeWorkspace?.id else {
        throw ConversationIntentError.inactive
      }
      try activateConversation(workspaceID, workspaceState.activeSessionID)
      intentErrorMessage = nil
      return true
    } catch {
      intentErrorMessage = error.localizedDescription
      return false
    }
  }

  func setInteractionMode(_ mode: WorkspaceInteractionMode) {
    performIntent {
      try conversation.setInteractionMode(mode)
    }
  }

  func setReasoningEnabled(_ isEnabled: Bool) {
    performIntent {
      try conversation.setReasoningEnabled(isEnabled)
    }
  }

  func enableAutomaticToolApproval() {
    performIntent {
      try conversation.enableAutomaticToolApproval()
    }
  }

  func disableAutomaticToolApproval() {
    performIntent {
      try conversation.disableAutomaticToolApproval()
    }
  }

  func addAttachments(from urls: [URL]) {
    performIntent {
      try conversation.addAttachments(from: urls)
    }
  }

  func removeAttachment(id: ChatAttachment.ID) {
    performIntent {
      try conversation.removeAttachment(id: id)
    }
  }

  func cancelGeneration() {
    conversation.cancelGeneration()
  }

  func approveToolCall(
    id toolCallID: ToolCallRecord.ID
  ) {
    performIntent {
      try conversation.approveToolCall(id: toolCallID)
    }
  }

  func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID
  ) {
    performIntent {
      try conversation.approveToolCallBatch(containing: batchAnchorID)
    }
  }

  func resumeAutomaticApprovalBatch(
    containing batchAnchorID: ToolCallRecord.ID
  ) {
    performIntent {
      try conversation.resumeAutomaticApprovalBatch(containing: batchAnchorID)
    }
  }

  func denyToolCall(
    id toolCallID: ToolCallRecord.ID
  ) {
    performIntent {
      try conversation.denyToolCall(id: toolCallID)
    }
  }

  func answerAskUserToolCall(
    id toolCallID: ToolCallRecord.ID,
    answer: String
  ) {
    performIntent {
      try conversation.answerAskUserToolCall(id: toolCallID, answer: answer)
    }
  }

  func modelContextDebugDocument() throws -> ModelContextDebugDocument {
    guard activateSelectedConversation() else {
      throw ConversationIntentError.inactive
    }
    return try conversation.modelContextDebugDocument()
  }

  private var selectedActiveConversationState: ActiveConversationState? {
    guard let active = conversation.state.active,
      active.workspaceID == workspaceState.activeWorkspace?.id,
      active.sessionID == workspaceState.activeSessionID
    else {
      return nil
    }
    return active
  }

  private var isAnotherConversationBusy: Bool {
    guard let active = conversation.state.active, active.activity.isBusy else {
      return false
    }
    return active.workspaceID != workspaceState.activeWorkspace?.id
      || active.sessionID != workspaceState.activeSessionID
  }

  private var selectedComposerState: ChatComposerSessionState {
    guard let session = workspaceState.activeSession else {
      return ChatComposerSessionState()
    }
    let activeAttachmentIDs = Set(session.activeAttachmentContext.attachmentIDs)
    return ChatComposerSessionState(
      pendingAttachments: session.pendingAttachments,
      activeAttachments: session.pendingAttachments.filter {
        activeAttachmentIDs.contains($0.id)
      },
      interactionMode: session.interactionMode,
      toolApprovalPolicy: session.toolApprovalPolicy,
      selectedMCPServerIDs: session.selectedMCPServerIDs,
      reasoningEnabled: session.generationSettings.reasoningEnabled,
      todoState: session.interactionMode == .agent ? session.todoState : nil
    )
  }

  private func performIntent(_ intent: () throws -> Void) {
    guard activateSelectedConversation() else {
      return
    }
    do {
      try intent()
      intentErrorMessage = nil
    } catch {
      intentErrorMessage = error.localizedDescription
    }
  }

  #if DEBUG
    func refreshContextUsageForTesting() {
      conversation.refreshContextUsageForTesting()
    }

    var sessionSnapshotForTesting: ChatSession? {
      conversation.snapshot()
    }
  #endif
}
