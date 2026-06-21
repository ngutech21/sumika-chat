import Foundation

public struct ChatComposerSessionState: Equatable, Sendable {
  public var pendingAttachments: [ChatAttachment]
  public var activeAttachments: [ChatAttachment]
  public var interactionMode: WorkspaceInteractionMode
  public var todoState: TodoState?

  public init(
    pendingAttachments: [ChatAttachment] = [],
    activeAttachments: [ChatAttachment] = [],
    interactionMode: WorkspaceInteractionMode = .chat,
    todoState: TodoState? = nil
  ) {
    self.pendingAttachments = pendingAttachments
    self.activeAttachments = activeAttachments
    self.interactionMode = interactionMode
    self.todoState = todoState
  }
}
