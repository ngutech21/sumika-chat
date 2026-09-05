import Foundation

enum ChatAttachmentEvent: Equatable, Sendable {
  case appendAttachments([ChatAttachment])
  case error(String)
}

@MainActor
final class ChatAttachmentCoordinator {
  private let loader: any ChatAttachmentLoading
  private let referenceLease: ChatAttachmentLease
  private var loadTasks: [UUID: Task<Void, Never>] = [:]
  private var cleanupTask: Task<Void, Never>?
  private var loadRequestID = UUID()
  private var referencedIDs: Set<AttachmentID> = []
  var onCleanup: (@MainActor @Sendable ([FileCleanupIssue]) -> Void)?

  init(loader: any ChatAttachmentLoading) {
    self.loader = loader
    self.referenceLease = loader.lifecycle.protect([])
  }

  deinit {
    for task in loadTasks.values { task.cancel() }
    referenceLease.release()
  }

  func cancelLoading() {
    loadRequestID = UUID()
    for task in loadTasks.values { task.cancel() }
  }

  func setReferences(_ ids: Set<AttachmentID>) {
    guard ids != referencedIDs else { return }
    referencedIDs = ids
    referenceLease.replace(with: ids)
    scheduleCleanup()
  }

  func drain() async {
    cancelLoading()
    for task in loadTasks.values { await task.value }
    await cleanupTask?.value
    report(await loader.lifecycle.cleanup())
  }

  private func scheduleCleanup() {
    let previous = cleanupTask
    cleanupTask = Task { [weak self, lifecycle = loader.lifecycle] in
      await previous?.value
      let issues = await lifecycle.cleanup()
      self?.report(issues)
    }
  }

  private func report(_ issues: [FileCleanupIssue]) {
    onCleanup?(issues)
  }

  func addAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment],
    onEvent: @escaping @MainActor @Sendable (ChatAttachmentEvent) -> Void
  ) {
    let requestID = UUID()
    loadRequestID = requestID
    for task in loadTasks.values { task.cancel() }
    let loader = loader

    loadTasks[requestID] = Task {
      defer {
        Self.removeAppOwnedPasteboardTempFiles(from: urls)
        loadTasks[requestID] = nil
      }
      do {
        let batch = try await loader.loadAttachments(
          from: urls,
          existingAttachments: existingAttachments
        )
        guard !Task.isCancelled, requestID == loadRequestID else {
          report(await batch.discard())
          return
        }
        batch.adopt(into: referenceLease)
        referencedIDs.formUnion(batch.attachments.map(\.id))
        onEvent(.appendAttachments(batch.attachments))
      } catch is CancellationError {
        report(await loader.lifecycle.cleanup())
      } catch {
        report(await loader.lifecycle.cleanup())
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
