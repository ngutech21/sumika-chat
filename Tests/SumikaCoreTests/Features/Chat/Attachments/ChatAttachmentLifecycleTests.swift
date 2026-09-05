import Foundation
import SumikaTestSupport
import Synchronization
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "attachment-lifecycle"))
struct ChatAttachmentLifecycleTests {
  @Test
  func discardedImportsRemoveCopiesButPreserveSourcesAndOtherImports() async throws {
    let root = try scopedTemporaryDirectory()
    let source = root.appending(path: "private.txt")
    try Data("private bytes".utf8).write(to: source)
    let store = ChatAttachmentStore(baseURL: root.appending(path: "attachments"))
    let loader = ChatAttachmentLoader(attachmentStore: store)
    let first = try await loader.loadAttachments(from: [source], existingAttachments: [])
    let second = try await loader.loadAttachments(from: [source], existingAttachments: [])
    let firstID = try #require(first.attachments.first?.id)
    let secondID = try #require(second.attachments.first?.id)
    #expect(firstID != secondID)

    #expect(await first.discard().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.directoryURL(for: firstID).path))
    #expect(try Data(contentsOf: store.localURL(for: secondID)) == Data("private bytes".utf8))
    #expect(await second.discard().isEmpty)
    #expect(try store.storedAttachmentIDs().isEmpty)
    #expect(try Data(contentsOf: source) == Data("private bytes".utf8))
  }

  @Test
  func reconciliationCannotCollectAnImportWhileItsWriteIsSuspended() async throws {
    let root = try scopedTemporaryDirectory()
    let gate = AttachmentCleanupGate()
    defer { Task { await gate.open() } }
    let store = ChatAttachmentStore(
      baseURL: root.appending(path: "attachments"),
      writeFile: { data, url in
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        await gate.pause()
      }
    )
    let loader = ChatAttachmentLoader(attachmentStore: store)
    loader.lifecycle.recordCommittedReferences([])
    let source = root.appending(path: "source.txt")
    try Data("retained".utf8).write(to: source)
    let task = Task { try await loader.loadAttachments(from: [source], existingAttachments: []) }
    await gate.waitUntilReached()
    #expect(await loader.lifecycle.cleanup(reconcile: true).isEmpty)
    #expect(try store.storedAttachmentIDs().count == 1)
    await gate.open()
    let batch = try await task.value
    #expect(await batch.discard().isEmpty)
    #expect(try store.storedAttachmentIDs().isEmpty)
  }

  @Test
  func failedCleanupIsReportedAndRetried() async throws {
    let root = try scopedTemporaryDirectory()
    let fails = Mutex(true)
    let store = ChatAttachmentStore(
      baseURL: root.appending(path: "attachments"),
      writeFile: { data, url in
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
      },
      removeItem: { url in
        if fails.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
      }
    )
    let source = root.appending(path: "source.txt")
    try Data("retained".utf8).write(to: source)
    let loader = ChatAttachmentLoader(attachmentStore: store)
    let batch = try await loader.loadAttachments(from: [source], existingAttachments: [])
    #expect(await batch.discard().count == 1)
    #expect(try store.storedAttachmentIDs().count == 1)
    fails.withLock { $0 = false }
    #expect(await loader.lifecycle.cleanup().isEmpty)
    #expect(try store.storedAttachmentIDs().isEmpty)
  }

  @Test
  @MainActor
  func cleanupFailureAfterDeactivationReachesTheAppErrorHandler() async throws {
    let root = try scopedTemporaryDirectory()
    let source = root.appending(path: "source.txt")
    try Data("pending".utf8).write(to: source)
    let store = ChatAttachmentStore(
      baseURL: root.appending(path: "attachments"),
      writeFile: { data, url in
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
      },
      removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
    )
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(), modelPath: "/tmp/model",
      chatAttachmentLoader: ChatAttachmentLoader(attachmentStore: store)
    )
    var reportedIssues: [FileCleanupIssue] = []
    engine.setAttachmentCleanupFailureHandler { reportedIssues += $0 }
    engine.addAttachments(from: [source])
    try await waitForAttachment(in: engine)
    engine.deactivate()
    await engine.drainAttachments()
    #expect(!reportedIssues.isEmpty)
    #expect(!engine.hasActiveConversation)
    #expect(try store.storedAttachmentIDs().count == 1)
  }

  @Test
  func reconciliationPreservesUnknownEntriesAndSymlinks() async throws {
    let root = try scopedTemporaryDirectory()
    let store = ChatAttachmentStore(baseURL: root.appending(path: "attachments"))
    let orphanID = UUID()
    _ = try await store.storeFile(data: Data("orphan".utf8), id: orphanID, displayName: "file.txt")
    let unknown = store.baseURL.appending(path: "unknown")
    try Data("keep".utf8).write(to: unknown)
    let source = root.appending(path: "source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let marker = source.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: marker)
    let link = store.directoryURL(for: UUID())
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let nestedID = UUID()
    let nested = store.directoryURL(for: nestedID)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: nested.appending(path: "link"), withDestinationURL: marker)
    let lifecycle = ChatAttachmentLifecycle(store: store)
    lifecycle.recordCommittedReferences([])
    #expect(await lifecycle.cleanup(reconcile: true).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.directoryURL(for: orphanID).path))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    #expect(FileManager.default.fileExists(atPath: link.path))
    #expect(FileManager.default.fileExists(atPath: nested.path))
    #expect(try Data(contentsOf: marker) == Data("keep".utf8))
  }

  @Test(arguments: ["remove", "switch", "deactivate", "clear"])
  @MainActor
  func abandoningPendingAttachmentsReclaimsFiles(action: String) async throws {
    let root = try scopedTemporaryDirectory()
    let store = ChatAttachmentStore(baseURL: root.appending(path: "attachments"))
    let source = root.appending(path: "source.txt")
    try Data("private".utf8).write(to: source)
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(), modelPath: "/tmp/model",
      chatAttachmentLoader: ChatAttachmentLoader(attachmentStore: store)
    )
    engine.addAttachments(from: [source])
    try await waitForAttachment(in: engine)
    let id = try #require(engine.composerSessionState.pendingAttachments.first?.id)
    switch action {
    case "remove": engine.removeAttachment(id: id)
    case "switch":
      engine.installConversation(
        ChatSession(), in: Workspace(name: "Other", rootURL: root), modelRuntimeWasReset: true)
    case "clear": engine.clearChatHistory()
    default: engine.deactivate()
    }
    await engine.drainAttachments()
    #expect(!FileManager.default.fileExists(atPath: store.directoryURL(for: id).path))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test
  @MainActor
  func staleSuccessfulImportIsDiscardedWhileTheNewComposerAttachmentSurvives() async throws {
    let root = try scopedTemporaryDirectory()
    let store = ChatAttachmentStore(baseURL: root.appending(path: "attachments"))
    let first = root.appending(path: "first.txt")
    let second = root.appending(path: "second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let gate = AttachmentCleanupGate()
    defer { Task { await gate.open() } }
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(), modelPath: "/tmp/model",
      chatAttachmentLoader: HoldingImportLoader(
        loader: ChatAttachmentLoader(attachmentStore: store), gates: ["first.txt": gate]
      )
    )
    engine.addAttachments(from: [first])
    await gate.waitUntilReached()
    let staleID = try #require(store.storedAttachmentIDs().first)
    engine.addAttachments(from: [second])
    try await waitForAttachment(in: engine)
    let survivor = try #require(engine.composerSessionState.pendingAttachments.first)
    await gate.open()
    await engine.drainAttachments()
    #expect(!FileManager.default.fileExists(atPath: store.directoryURL(for: staleID).path))
    #expect(try store.validateStoredFile(for: survivor).lastPathComponent == "second.txt")
    engine.deactivate()
    await engine.drainAttachments()
    #expect(try store.storedAttachmentIDs().isEmpty)
  }

  @Test
  @MainActor
  func shutdownDrainsCurrentAndSupersededImports() async throws {
    let root = try scopedTemporaryDirectory()
    let store = ChatAttachmentStore(baseURL: root.appending(path: "attachments"))
    let first = root.appending(path: "first.txt")
    let second = root.appending(path: "second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let firstGate = AttachmentCleanupGate()
    let secondGate = AttachmentCleanupGate()
    defer {
      Task {
        await firstGate.open()
        await secondGate.open()
      }
    }
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(), modelPath: "/tmp/model",
      chatAttachmentLoader: HoldingImportLoader(
        loader: ChatAttachmentLoader(attachmentStore: store),
        gates: ["first.txt": firstGate, "second.txt": secondGate]
      )
    )
    engine.addAttachments(from: [first])
    await firstGate.waitUntilReached()
    engine.addAttachments(from: [second])
    await secondGate.waitUntilReached()
    engine.deactivate()
    var drained = false
    let started = AttachmentCleanupGate()
    await started.open()
    let task = Task {
      await started.pause()
      await engine.drainAttachments()
      drained = true
    }
    await started.waitUntilReached()
    #expect(!drained)
    #expect(try store.storedAttachmentIDs().count == 2)
    await secondGate.open()
    #expect(!drained)
    await firstGate.open()
    await task.value
    #expect(drained)
    #expect(try store.storedAttachmentIDs().isEmpty)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
  }

  @Test
  @MainActor
  func sendingProtectsLiveAndQueuedSnapshotsUntilPersistenceTakesOwnership() async throws {
    let root = try scopedTemporaryDirectory()
    let store = WorkspaceStore(baseURL: root)
    let attachmentStore = ChatAttachmentStore(baseURL: root.appending(path: "Attachments"))
    try await store.saveLibrary(WorkspaceLibrary())
    let source = root.appending(path: "source.txt")
    try Data("private".utf8).write(to: source)
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(chunks: ["answer"]), modelPath: "/tmp/model",
      chatAttachmentLoader: ChatAttachmentLoader(lifecycle: store.attachmentLifecycle)
    )
    var snapshots: [(ChatSession, ChatAttachmentLease)] = []
    engine.setSessionChangeHandler { _, session in
      snapshots.append((session, store.attachmentLifecycle.protect(session.attachmentIDs)))
    }
    engine.addAttachments(from: [source])
    try await waitForAttachment(in: engine)
    let id = try #require(engine.composerSessionState.pendingAttachments.first?.id)
    await #expect(throws: (any Error).self) { try await engine.sendMessage(prompt: "question") }
    #expect(engine.composerSessionState.pendingAttachments.count == 1)
    engine.modelRuntime.modelState = .ready
    try await engine.sendMessageInTestWorkspace(prompt: "question")
    engine.deactivate()
    await engine.drainAttachments()
    #expect(try Data(contentsOf: attachmentStore.localURL(for: id)) == Data("private".utf8))
    let session = try #require(snapshots.last?.0)
    let library = WorkspaceLibrary(workspaces: [
      Workspace(name: "Project", rootURL: root, sessions: [session])
    ])
    try await store.saveLibrary(library)
    for (_, lease) in snapshots { lease.release() }
    await store.attachmentLifecycle.cleanup()
    #expect(FileManager.default.fileExists(atPath: attachmentStore.directoryURL(for: id).path))
    try await store.saveLibrary(WorkspaceLibrary())
    #expect(!FileManager.default.fileExists(atPath: attachmentStore.directoryURL(for: id).path))
  }

  @MainActor
  private func waitForAttachment(in engine: ConversationEngine) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while engine.composerSessionState.pendingAttachments.isEmpty {
      guard ContinuousClock.now < deadline else { throw TestWaitTimeoutError() }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private struct HoldingImportLoader: ChatAttachmentLoading {
  let loader: ChatAttachmentLoader
  let gates: [String: AttachmentCleanupGate]
  var lifecycle: ChatAttachmentLifecycle { loader.lifecycle }

  func loadAttachments(
    from urls: [URL], existingAttachments: [ChatAttachment]
  ) async throws -> ChatAttachmentImport {
    let batch = try await loader.loadAttachments(
      from: urls, existingAttachments: existingAttachments)
    if let name = urls.first?.lastPathComponent, let gate = gates[name] {
      await gate.pause()
    }
    return batch
  }
}

actor AttachmentCleanupGate {
  private var reached = false
  private var released = false
  private var reachWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func pause() async {
    reached = true
    for waiter in reachWaiters { waiter.resume() }
    reachWaiters.removeAll()
    if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
  }

  func waitUntilReached() async {
    if !reached { await withCheckedContinuation { reachWaiters.append($0) } }
  }

  func open() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}
