import Foundation

public enum ChatAttachmentEvent: Equatable, Sendable {
  case appendAttachments([ChatAttachment])
  case removeAttachment(ChatAttachment.ID)
  case error(String)
}

@MainActor
public final class ChatAttachmentCoordinator {
  private let loader: any ChatAttachmentLoading
  private let loadQueue = DispatchQueue(
    label: "chat.sumika.chat-attachments.load",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private var loadTask: Task<Void, Never>?
  private var loadRequestID = UUID()

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
    let loadQueue = loadQueue

    loadTask = Task {
      do {
        let attachments = try await Self.loadAttachments(
          from: urls,
          existingAttachments: existingAttachments,
          loader: loader,
          loadQueue: loadQueue
        )
        guard !Task.isCancelled, requestID == loadRequestID else {
          return
        }
        onEvent(.appendAttachments(attachments))
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, requestID == loadRequestID else {
          return
        }
        onEvent(.error(error.localizedDescription))
      }

      if requestID == loadRequestID {
        loadTask = nil
      }
    }
  }

  private nonisolated static func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment],
    loader: any ChatAttachmentLoading,
    loadQueue: DispatchQueue
  ) async throws -> [ChatAttachment] {
    try await withCheckedThrowingContinuation { continuation in
      loadQueue.async {
        do {
          let attachments = try loader.loadAttachments(
            from: urls,
            existingAttachments: existingAttachments
          )
          removeAppOwnedPasteboardTempFiles(from: urls)
          continuation.resume(returning: attachments)
        } catch {
          removeAppOwnedPasteboardTempFiles(from: urls)
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private nonisolated static func removeAppOwnedPasteboardTempFiles(from urls: [URL]) {
    let fileManager = FileManager.default
    for url in urls where isAppOwnedPasteboardTempFile(url) {
      try? fileManager.removeItem(at: url)
    }
  }

  private nonisolated static func isAppOwnedPasteboardTempFile(_ url: URL) -> Bool {
    let standardizedURL = url.standardizedFileURL
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "sumika-pasteboard", directoryHint: .isDirectory)
      .standardizedFileURL
    let parent = standardizedURL.deletingLastPathComponent().standardizedFileURL
    let fileName = standardizedURL.lastPathComponent

    return parent.path(percentEncoded: false) == directory.path(percentEncoded: false)
      && fileName.hasPrefix("clipboard-image-")
      && fileName.hasSuffix(".png")
  }

  public func removeAttachment(
    id: ChatAttachment.ID,
    onEvent: @MainActor @Sendable (ChatAttachmentEvent) -> Void
  ) {
    onEvent(.removeAttachment(id))
  }
}
