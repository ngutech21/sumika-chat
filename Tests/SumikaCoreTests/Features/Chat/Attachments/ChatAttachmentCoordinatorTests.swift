import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-attachment-coordinator-tests"))
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
    defer { removeTemporaryItemIfPresent(tempFile) }
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
    defer { removeTemporaryItemIfPresent(tempFile) }
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
    defer { removeTemporaryItemIfPresent(tempFile) }
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
      Task {
        await loader.resolve(at: 0, with: [])
        await loader.resolve(at: 1, with: [])
      }
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
    try await waitUntil { await loader.startedCount == 1 }

    coordinator.addAttachments(
      from: [URL(filePath: "/tmp/second.swift")],
      existingAttachments: [],
      onEvent: { events.append($0) }
    )
    try await waitUntil { await loader.startedCount == 2 }

    await loader.resolve(at: 1, with: [secondAttachment])
    try await waitUntil {
      events == [.appendAttachments([secondAttachment])]
    }

    await loader.resolve(at: 0, with: [firstAttachment])
    try await waitUntil { await loader.completedCount == 2 }
    await Task.yield()

    #expect(events == [.appendAttachments([secondAttachment])])
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
  ) async throws -> [ChatAttachment] {
    _ = urls
    _ = existingAttachments
    return try result.get()
  }
}

private actor AttachmentControlledLoader: ChatAttachmentLoading {
  private var calls: [CheckedContinuation<[ChatAttachment], Never>?] = []
  private var completedCalls = 0

  var startedCount: Int { calls.count }

  var completedCount: Int { completedCalls }

  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) async throws -> [ChatAttachment] {
    _ = urls
    _ = existingAttachments
    return await withCheckedContinuation { continuation in
      calls.append(continuation)
    }
  }

  func resolve(at index: Int, with attachments: [ChatAttachment]) {
    guard calls.indices.contains(index), let continuation = calls[index] else {
      return
    }
    calls[index] = nil
    completedCalls += 1
    continuation.resume(returning: attachments)
  }
}

private func makePasteboardTempFile(name: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "sumika-pasteboard", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appending(path: name, directoryHint: .notDirectory)
  try Data("temporary image".utf8).write(to: url)
  return url
}

private func makeNormalTempFile(name: String) throws -> URL {
  let directory = try scopedTemporaryDirectory()
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
  makeTextChatAttachment(
    displayName: name,
    content: content
  )
}

private func waitUntil(
  timeout: Duration = .seconds(1),
  condition: @escaping @MainActor () async -> Bool
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
