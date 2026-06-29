import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ChatAttachmentCoordinatorTests {
  @Test
  func addAttachmentsPublishesLoadedAttachments() async throws {
    let attachment = makeAttachment(name: "README.md", content: "notes")
    let loader = AttachmentFakeLoader(result: .success([attachment]))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [URL(filePath: "/tmp/README.md")],
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
  func addAttachmentsRemovesPasteboardTempFileAfterSuccess() async throws {
    let tempFile = try makePasteboardTempFile(name: "clipboard-image-\(UUID().uuidString).png")
    let attachment = makeAttachment(name: "clipboard.png", content: "notes")
    let loader = AttachmentFakeLoader(result: .success([attachment]))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [tempFile],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await waitUntil { events == [.appendAttachments([attachment])] }
    #expect(!FileManager.default.fileExists(atPath: tempFile.path(percentEncoded: false)))
  }

  @Test
  func addAttachmentsRemovesPasteboardTempFileAfterFailure() async throws {
    let tempFile = try makePasteboardTempFile(name: "clipboard-image-\(UUID().uuidString).png")
    let loader = AttachmentFakeLoader(result: .failure(ChatAttachmentTestError()))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [tempFile],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await waitUntil { events == [.error("Attachment test error")] }
    #expect(!FileManager.default.fileExists(atPath: tempFile.path(percentEncoded: false)))
  }

  @Test
  func addAttachmentsKeepsNormalSourceFileAfterSuccess() async throws {
    let file = try makeNormalTempFile(name: "clipboard-image-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let attachment = makeAttachment(name: "clipboard.png", content: "notes")
    let loader = AttachmentFakeLoader(result: .success([attachment]))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [file],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await waitUntil { events == [.appendAttachments([attachment])] }
    #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
  }

  @Test
  func addAttachmentsKeepsNonMatchingPasteboardTempFileAfterSuccess() async throws {
    let tempFile = try makePasteboardTempFile(name: "not-clipboard-image-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: tempFile) }
    let attachment = makeAttachment(name: "clipboard.png", content: "notes")
    let loader = AttachmentFakeLoader(result: .success([attachment]))
    let coordinator = ChatAttachmentCoordinator(loader: loader)
    var events: [ChatAttachmentEvent] = []

    coordinator.addAttachments(
      from: [tempFile],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )

    try await waitUntil { events == [.appendAttachments([attachment])] }
    #expect(FileManager.default.fileExists(atPath: tempFile.path(percentEncoded: false)))
  }

  @Test
  func newerLoadInvalidatesOlderResult() async throws {
    let loader = AttachmentControlledLoader()
    defer {
      loader.resolve(at: 0, with: [])
      loader.resolve(at: 1, with: [])
    }
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
    try await waitUntil { loader.completedCount == 2 }
    await Task.yield()

    #expect(events == [.appendAttachments([secondAttachment])])
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
  private let result: Result<[ChatAttachment], Error>

  init(result: Result<[ChatAttachment], Error>) {
    self.result = result
  }

  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    _ = urls
    _ = existingAttachments
    return try result.get()
  }
}

private final class AttachmentControlledLoader: ChatAttachmentLoading, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [ControlledAttachmentLoad] = []
  private var completedCalls = 0

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls.count
  }

  var completedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return completedCalls
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

    try call.wait()
    lock.lock()
    completedCalls += 1
    lock.unlock()
    return call.attachments
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

  func wait() throws {
    guard semaphore.wait(timeout: .now() + .seconds(2)) == .success else {
      throw TestWaitTimeoutError()
    }
  }

  func resolve(with attachments: [ChatAttachment]) {
    lock.lock()
    _attachments = attachments
    lock.unlock()
    semaphore.signal()
  }
}

private func makePasteboardTempFile(name: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "sumika-chat-pasteboard", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appending(path: name, directoryHint: .notDirectory)
  try Data("temporary image".utf8).write(to: url)
  return url
}

private func makeNormalTempFile(name: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "sumika-chat-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appending(path: name, directoryHint: .notDirectory)
  try Data("normal file".utf8).write(to: url)
  return url
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
      throw TestWaitTimeoutError()
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
