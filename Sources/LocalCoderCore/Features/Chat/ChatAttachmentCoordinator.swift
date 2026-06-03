import Foundation

public enum ChatAttachmentEvent: Equatable, Sendable {
  case appendAttachments([ChatAttachment])
  case replaceDraft(String)
  case removeAttachment(ChatAttachment.ID)
  case error(String)
}

@MainActor
public final class ChatAttachmentCoordinator {
  private let loader: any ChatAttachmentLoading
  private var loadTask: Task<Void, Never>?
  private var loadRequestID = UUID()
  private var isHandlingDroppedDraftPath = false

  public init(loader: any ChatAttachmentLoading) {
    self.loader = loader
  }

  deinit {
    loadTask?.cancel()
  }

  public func cancel() {
    loadTask?.cancel()
    loadTask = nil
  }

  public func addAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment],
    onEvent: @escaping @MainActor @Sendable (ChatAttachmentEvent) -> Void
  ) {
    let requestID = UUID()
    loadRequestID = requestID
    loadTask?.cancel()
    let loader = loader

    loadTask = Task {
      do {
        let attachments = try await Task.detached {
          try loader.loadAttachments(
            from: urls,
            existingAttachments: existingAttachments
          )
        }.value
        guard requestID == loadRequestID else {
          return
        }
        onEvent(.appendAttachments(attachments))
      } catch is CancellationError {
      } catch {
        guard requestID == loadRequestID else {
          return
        }
        onEvent(.error(error.localizedDescription))
      }

      if requestID == loadRequestID {
        loadTask = nil
      }
    }
  }

  public func convertDroppedFilePaths(
    in draft: String,
    isGenerating: Bool,
    existingAttachments: [ChatAttachment],
    onEvent: @escaping @MainActor @Sendable (ChatAttachmentEvent) -> Void
  ) {
    guard !isHandlingDroppedDraftPath, !isGenerating else {
      return
    }

    let droppedFiles = loader.extractDroppedAttachments(from: draft)
    guard !droppedFiles.urls.isEmpty else {
      return
    }

    isHandlingDroppedDraftPath = true
    onEvent(.replaceDraft(droppedFiles.cleanedDraft))
    addAttachments(
      from: droppedFiles.urls,
      existingAttachments: existingAttachments,
      onEvent: onEvent
    )
    isHandlingDroppedDraftPath = false
  }

  public func removeAttachment(
    id: ChatAttachment.ID,
    onEvent: @escaping @MainActor @Sendable (ChatAttachmentEvent) -> Void
  ) {
    onEvent(.removeAttachment(id))
  }
}
