import Foundation

public struct ChatComposerSessionState: Equatable, Sendable {
  public var pendingAttachments: [ChatAttachment]
  public var activeAttachments: [ChatAttachment]
  public var interactionMode: WorkspaceInteractionMode
  public var reasoningEnabled: Bool
  public var todoState: TodoState?

  public init(
    pendingAttachments: [ChatAttachment] = [],
    activeAttachments: [ChatAttachment] = [],
    interactionMode: WorkspaceInteractionMode = .chat,
    reasoningEnabled: Bool = true,
    todoState: TodoState? = nil
  ) {
    self.pendingAttachments = pendingAttachments
    self.activeAttachments = activeAttachments
    self.interactionMode = interactionMode
    self.reasoningEnabled = reasoningEnabled
    self.todoState = todoState
  }
}
