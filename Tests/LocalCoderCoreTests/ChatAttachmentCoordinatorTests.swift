import Foundation
import Testing

@testable import LocalCoderCore

@MainActor
struct ChatAttachmentCoordinatorTests {
  @Test
  func addAttachmentsPublishesLoadedAttachments() async throws {
    let attachment = makeAttachment(name: "README.md", content: "notes")
    let loader = AttachmentFakeLoader(result: .success([attachment]))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [attachment.url],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await waitUntil { events == [.appendAttachments([attachment])] }
  }

  @Test
  func addAttachmentsPublishesLoadFailure() async throws {
    let loader = AttachmentFakeLoader(result: .failure(ChatAttachmentTestError()))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [URL(filePath: "/tmp/failing.swift")],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await waitUntil { events == [.error("Attachment test error")] }
  }

  @Test
  func newerLoadInvalidatesOlderResult() async throws {
    let loader = AttachmentControlledLoader()
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    let firstAttachment = makeAttachment(name: "first.swift", content: "first")
    let secondAttachment = makeAttachment(name: "second.swift", content: "second")
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [URL(filePath: "/tmp/first.swift")],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )
    try await waitUntil { loader.startedCount == 1 }

    coordinator.addAttachments(
      from: [URL(filePath: "/tmp/second.swift")],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )
    try await waitUntil { loader.startedCount == 2 }

    loader.resolve(at: 1, with: [secondAttachment])
    try await waitUntil {
      events == [.appendAttachments([secondAttachment])]
    }

    loader.resolve(at: 0, with: [firstAttachment])
    try await Task.sleep(for: .milliseconds(60))

    #expect(events == [.appendAttachments([secondAttachment])])
  }

  @Test
  func convertDroppedFilePathsPublishesDraftReplacementAndLoadsAttachments() async throws {
    let attachment = makeAttachment(name: "Dropped.swift", content: "dropped")
    let loader = AttachmentFakeLoader(
      result: .success([attachment]),
      droppedExtraction: DroppedAttachmentExtraction(
        urls: [attachment.url],
        cleanedDraft: "please inspect this"
      )
    )
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.convertDroppedFilePaths(
      in: "please inspect /tmp/Dropped.swift",
      isGenerating: false,
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await waitUntil {
      events == [
        .replaceDraft("please inspect this"),
        .appendAttachments([attachment]),
      ]
    }
  }

  @Test
  func convertDroppedFilePathsDoesNothingWhileGenerating() async throws {
    let attachment = makeAttachment(name: "Dropped.swift", content: "dropped")
    let loader = AttachmentFakeLoader(
      result: .success([attachment]),
      droppedExtraction: DroppedAttachmentExtraction(
        urls: [attachment.url],
        cleanedDraft: "cleaned"
      )
    )
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.convertDroppedFilePaths(
      in: "/tmp/Dropped.swift",
      isGenerating: true,
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await Task.sleep(for: .milliseconds(60))

    #expect(events.isEmpty)
    #expect(loader.loadCallCount == 0)
  }

  @Test
  func removeAttachmentPublishesRemovalEvent() {
    let loader = AttachmentFakeLoader(result: .success([]))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    let id = UUID()
    var events: [ChatAttachmentEvent] = []

    coordinator.removeAttachment(id: id) {
      events.append($0)
    }

    #expect(events == [.removeAttachment(id)])
  }
}

private final class AttachmentFakeLoader: ChatAttachmentLoading, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<[ChatAttachment], Error>
  private let droppedExtraction: DroppedAttachmentExtraction
  private var _loadCallCount = 0

  var loadCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _loadCallCount
  }

  init(
    result: Result<[ChatAttachment], Error>,
    droppedExtraction: DroppedAttachmentExtraction = DroppedAttachmentExtraction(cleanedDraft: "")
  ) {
    self.result = result
    self.droppedExtraction = droppedExtraction
  }

  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    _ = urls
    _ = existingAttachments
    lock.lock()
    _loadCallCount += 1
    lock.unlock()
    return try result.get()
  }

  func extractDroppedAttachments(from draft: String) -> DroppedAttachmentExtraction {
    _ = draft
    return droppedExtraction
  }
}

private final class AttachmentControlledLoader: ChatAttachmentLoading, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [ControlledAttachmentLoad] = []

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls.count
  }

  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    _ = urls
    _ = existingAttachments
    let call = ControlledAttachmentLoad()
    lock.lock()
    calls.append(call)
    lock.unlock()

    call.wait()
    return call.attachments
  }

  func extractDroppedAttachments(from draft: String) -> DroppedAttachmentExtraction {
    DroppedAttachmentExtraction(cleanedDraft: draft)
  }

  func resolve(at index: Int, with attachments: [ChatAttachment]) {
    let call: ControlledAttachmentLoad? = {
      lock.lock()
      defer { lock.unlock() }
      guard calls.indices.contains(index) else {
        return nil
      }
      return calls[index]
    }()

    call?.resolve(with: attachments)
  }
}

private final class ControlledAttachmentLoad: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var _attachments: [ChatAttachment] = []

  var attachments: [ChatAttachment] {
    lock.lock()
    defer { lock.unlock() }
    return _attachments
  }

  func wait() {
    semaphore.wait()
  }

  func resolve(with attachments: [ChatAttachment]) {
    lock.lock()
    _attachments = attachments
    lock.unlock()
    semaphore.signal()
  }
}

private struct ChatAttachmentTestError: LocalizedError {
  var errorDescription: String? {
    "Attachment test error"
  }
}

private func makeAttachment(name: String, content: String) -> ChatAttachment {
  ChatAttachment(
    url: URL(filePath: "/tmp/\(name)"),
    displayName: name,
    kind: .text,
    content: content
  )
}

private func waitUntil(
  timeout: Duration = .seconds(1),
  condition: @escaping @MainActor () -> Bool
) async throws {
  let start = ContinuousClock.now
  while !(await condition()) {
    if ContinuousClock.now - start > timeout {
      Issue.record("Timed out waiting for condition")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
