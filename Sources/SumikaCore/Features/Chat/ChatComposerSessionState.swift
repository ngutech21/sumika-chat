import Foundation

package struct ChatComposerSessionState: Equatable, Sendable {
  package var pendingAttachments: [ChatAttachment]
  package var activeAttachments: [ChatAttachment]
  package var interactionMode: WorkspaceInteractionMode
  package var toolApprovalPolicy: ToolApprovalPolicy
  package var selectedMCPServerIDs: [UUID]
  package var reasoningEnabled: Bool
  package var todoState: TodoState?

  package init(
    pendingAttachments: [ChatAttachment] = [],
    activeAttachments: [ChatAttachment] = [],
    interactionMode: WorkspaceInteractionMode = .chat,
    toolApprovalPolicy: ToolApprovalPolicy = .manual,
    selectedMCPServerIDs: [UUID] = [],
    reasoningEnabled: Bool = true,
    todoState: TodoState? = nil
  ) {
    self.pendingAttachments = pendingAttachments
    self.activeAttachments = activeAttachments
    self.interactionMode = interactionMode
    self.toolApprovalPolicy = toolApprovalPolicy
    self.selectedMCPServerIDs = selectedMCPServerIDs
    self.reasoningEnabled = reasoningEnabled
    self.todoState = todoState
  }

  package init(session: ChatSession) {
    let activeAttachmentIDs = Set(session.activeAttachmentContext.attachmentIDs)
    let visibleTodoState: TodoState? =
      if session.interactionMode == .agent,
        let todoState = session.todoState,
        !todoState.items.isEmpty
      {
        todoState
      } else {
        nil
      }

    self.init(
      pendingAttachments: session.pendingAttachments,
      activeAttachments: session.pendingAttachments.filter {
        activeAttachmentIDs.contains($0.id)
      },
      interactionMode: session.interactionMode,
      toolApprovalPolicy: session.toolApprovalPolicy,
      selectedMCPServerIDs: session.selectedMCPServerIDs,
      reasoningEnabled: session.generationSettings.reasoningEnabled,
      todoState: visibleTodoState
    )
  }
}
