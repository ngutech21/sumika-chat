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
}
