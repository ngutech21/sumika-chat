import Foundation

enum ChatAttachmentEvent: Equatable, Sendable {
  case appendAttachments([ChatAttachment])
  case error(String)
}

@MainActor
final class ChatAttachmentCoordinator {
  private let loader: any ChatAttachmentLoading
  private var loadTask: Task<Void, Never>?
  private var loadRequestID = UUID()

  init(loader: any ChatAttachmentLoading) {
    self.loader = loader
  }

  deinit {
    loadTask?.cancel()
  }

  func cancelLoading() {
    loadRequestID = UUID()
    loadTask?.cancel()
    loadTask = nil
  }

  func addAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment],
    onEvent: @escaping @MainActor @Sendable (ChatAttachmentEvent) -> Void
  ) {
    let requestID = UUID()
    loadRequestID = requestID
    loadTask?.cancel()
    let loader = loader

    loadTask = Task {
      defer {
        Self.removeAppOwnedPasteboardTempFiles(from: urls)
        if requestID == loadRequestID {
          loadTask = nil
        }
      }
      do {
        let attachments = try await loader.loadAttachments(
          from: urls,
          existingAttachments: existingAttachments
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
}
