import Foundation
import SumikaTestSupport
import Synchronization
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "workspace-cleanup"))
struct WorkspaceCleanupTests {
  @Test(arguments: [true, false], [true, false])
  func initialSaveFailureCanBeRetriedWithoutPrematureCleanup(
    loadFirst: Bool, failManifest: Bool
  ) async throws {
    let root = try scopedTemporaryDirectory()
    let fail = Mutex(true)
    let store = WorkspaceStore(
      baseURL: root,
      writeData: { data, url in
        if (url.lastPathComponent == "workspaces.json") == failManifest,
          fail.withLock({ $0 })
        {
          throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: url, options: .atomic)
      })
    if loadFirst {
      #expect(await store.loadLibrary().canPersist)
    }
    let batch = try await importedFile(in: root, lifecycle: store.attachmentLifecycle)
    let attachment = try #require(batch.attachments.first)
    let session = session(with: attachment)
    let candidate = library(with: session, root: root)
    await #expect(throws: (any Error).self) { try await store.saveLibrary(candidate) }
    #expect(!FileManager.default.fileExists(atPath: manifestURL(root).path))
    #expect(
      FileManager.default.fileExists(atPath: root.appending(path: "WorkspaceLibrary/sessions").path)
    )
    await batch.discard()
    #expect(await store.retryCleanup().isEmpty)
    await store.attachmentLifecycle.cleanup(reconcile: true)
    let attachments = ChatAttachmentStore(baseURL: root.appending(path: "Attachments"))
    #expect(try attachments.validateStoredFile(for: attachment).lastPathComponent == "source.txt")
    #expect(
      FileManager.default.fileExists(atPath: sessionURL(root, session.id).path) == failManifest)
    let reopened = await WorkspaceStore(baseURL: root).loadLibrary()
    #expect(!reopened.canPersist)

    fail.withLock { $0 = false }
    #expect(try await store.saveLibrary(candidate).cleanupIssues.isEmpty)
    let loaded = await WorkspaceStore(baseURL: root).loadLibrary()
    #expect(loaded.canPersist)
    #expect(loaded.library.attachmentIDs == [attachment.id])
    #expect(try attachments.validateStoredFile(for: attachment).lastPathComponent == "source.txt")
    try await store.saveLibrary(WorkspaceLibrary())
    #expect(try attachments.storedAttachmentIDs().isEmpty)
  }

  @Test
  func deletingChatsAndWorkspacesPreservesSharedUserAndAssistantAttachments() async throws {
    let root = try scopedTemporaryDirectory()
    let store = WorkspaceStore(baseURL: root)
    let batch = try await importedFile(in: root, lifecycle: store.attachmentLifecycle)
    let attachment = try #require(batch.attachments.first)
    let first = session(with: attachment)
    let second = session(with: attachment, assistant: true)
    var library = WorkspaceLibrary(workspaces: [
      Workspace(name: "First", rootURL: root, sessions: [first]),
      Workspace(name: "Second", rootURL: root, sessions: [second]),
    ])
    try await store.saveLibrary(library)
    await batch.discard()
    library.workspaces[0].sessions.removeAll()
    try await store.saveLibrary(library)
    #expect(!FileManager.default.fileExists(atPath: sessionURL(root, first.id).path))
    let attachments = ChatAttachmentStore(baseURL: root.appending(path: "Attachments"))
    #expect(try attachments.validateStoredFile(for: attachment).lastPathComponent == "source.txt")
    library.workspaces.removeAll()
    let outcome = try await store.saveLibrary(library)
    #expect(outcome.cleanupIssues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: sessionURL(root, second.id).path))
    #expect(try attachments.storedAttachmentIDs().isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "source.txt").path))
  }

  @Test
  func restartReconcilesInterruptedDeletionButPreservesDiagnosticsAndUnknownFiles() async throws {
    let root = try scopedTemporaryDirectory()
    let store = WorkspaceStore(baseURL: root)
    let batch = try await importedFile(in: root, lifecycle: store.attachmentLifecycle)
    let attachment = try #require(batch.attachments.first)
    let session = session(with: attachment)
    try await store.saveLibrary(library(with: session, root: root))
    await batch.discard()
    let unknown = sessionURL(root, session.id).deletingLastPathComponent().appending(
      path: "orphan.json")
    try Data("unknown".utf8).write(to: unknown)
    let corrupt = sessionURL(root, UUID())
    try Data("unknown".utf8).write(to: corrupt)
    let symlink = sessionURL(root, UUID())
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unknown)
    let trace = root.appending(path: "debug/traces/keep.jsonl")
    try FileManager.default.createDirectory(
      at: trace.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("diagnostics".utf8).write(to: trace)
    let emptyManifest = WorkspaceLibraryManifest(library: WorkspaceLibrary(), updatedAt: Date())
    try WorkspacePersistenceCoding.makeEncoder().encode(emptyManifest).write(to: manifestURL(root))

    let loaded = await WorkspaceStore(baseURL: root).loadLibrary()
    #expect(loaded.canPersist)
    #expect(loaded.cleanupIssues.isEmpty)
    #expect(loaded.library.workspaces.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: sessionURL(root, session.id).path))
    #expect(
      try ChatAttachmentStore(baseURL: root.appending(path: "Attachments")).storedAttachmentIDs()
        .isEmpty)
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
    #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try Data(contentsOf: trace) == Data("diagnostics".utf8))
  }

  @Test
  func missingReferencedSessionSuspendsCollectionDespiteAnOtherwiseValidManifest() async throws {
    let root = try scopedTemporaryDirectory()
    let store = WorkspaceStore(baseURL: root)
    let batch = try await importedFile(in: root, lifecycle: store.attachmentLifecycle)
    let attachment = try #require(batch.attachments.first)
    let session = session(with: attachment)
    try await store.saveLibrary(library(with: session, root: root))
    await batch.discard()
    try FileManager.default.removeItem(at: sessionURL(root, session.id))
    let restarted = WorkspaceStore(baseURL: root)
    let result = await restarted.loadLibrary()
    #expect(!result.canPersist)
    await restarted.attachmentLifecycle.cleanup(reconcile: true)
    #expect(await restarted.retryCleanup().isEmpty)
    let files = ChatAttachmentStore(baseURL: root.appending(path: "Attachments"))
    #expect(try files.validateStoredFile(for: attachment).lastPathComponent == "source.txt")
  }

  @Test
  func failedManifestCommitPreservesFilesUntilARecoverySaveSucceeds() async throws {
    let root = try scopedTemporaryDirectory()
    let fail = Mutex(false)
    let store = WorkspaceStore(
      baseURL: root,
      writeData: { data, url in
        if url.lastPathComponent == "workspaces.json", fail.withLock({ $0 }) {
          throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: url, options: .atomic)
      })
    let batch = try await importedFile(in: root, lifecycle: store.attachmentLifecycle)
    let attachment = try #require(batch.attachments.first)
    let session = session(with: attachment)
    let library = library(with: session, root: root)
    try await store.saveLibrary(library)
    await batch.discard()
    let originalManifest = try Data(contentsOf: manifestURL(root))
    fail.withLock { $0 = true }
    await #expect(throws: (any Error).self) { try await store.saveLibrary(WorkspaceLibrary()) }
    await store.attachmentLifecycle.cleanup(reconcile: true)
    #expect(try Data(contentsOf: manifestURL(root)) == originalManifest)
    #expect(FileManager.default.fileExists(atPath: sessionURL(root, session.id).path))
    let attachments = ChatAttachmentStore(baseURL: root.appending(path: "Attachments"))
    #expect(try attachments.validateStoredFile(for: attachment).lastPathComponent == "source.txt")
    fail.withLock { $0 = false }
    #expect(try await store.saveLibrary(WorkspaceLibrary()).cleanupIssues.isEmpty)
    #expect(try attachments.storedAttachmentIDs().isEmpty)
  }

  @Test
  func partialSessionWriteInvalidatesTheCachedSnapshotBeforeRetry() async throws {
    let root = try scopedTemporaryDirectory()
    let fail = Mutex(false)
    let store = WorkspaceStore(
      baseURL: root,
      writeData: { data, url in
        if url.lastPathComponent == "workspaces.json", fail.withLock({ $0 }) {
          throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: url, options: .atomic)
      })
    let original = ChatSession(title: "Original")
    let originalLibrary = library(with: original, root: root)
    try await store.saveLibrary(originalLibrary)
    var changed = originalLibrary
    changed.workspaces[0].name = "Changed"
    changed.workspaces[0].sessions[0].title = "Partially written"
    fail.withLock { $0 = true }
    await #expect(throws: (any Error).self) { try await store.saveLibrary(changed) }
    fail.withLock { $0 = false }
    try await store.saveLibrary(originalLibrary)
    let loaded = await WorkspaceStore(baseURL: root).loadLibrary()
    #expect(loaded.library.workspaces[0].sessions[0].title == "Original")
  }

  @Test
  func committedDeletionReportsUnlinkFailureAndRetriesWithoutRewritingTheManifest() async throws {
    let root = try scopedTemporaryDirectory()
    let fail = Mutex(true)
    let store = WorkspaceStore(
      baseURL: root,
      removeFile: { url in
        if fail.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
      })
    let session = ChatSession()
    try await store.saveLibrary(library(with: session, root: root))
    let result = try await store.saveLibrary(WorkspaceLibrary())
    #expect(result.cleanupIssues.count == 1)
    let committedManifest = try Data(contentsOf: manifestURL(root))
    #expect(FileManager.default.fileExists(atPath: sessionURL(root, session.id).path))
    fail.withLock { $0 = false }
    #expect(await store.retryCleanup().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: sessionURL(root, session.id).path))
    #expect(try Data(contentsOf: manifestURL(root)) == committedManifest)
  }

  @Test(arguments: ["not json", "{\"version\":999}"])
  func unreadableReferencesSuspendAllReconciliation(manifest: String) async throws {
    let root = try scopedTemporaryDirectory()
    let store = WorkspaceStore(baseURL: root)
    let batch = try await importedFile(in: root, lifecycle: store.attachmentLifecycle)
    let attachment = try #require(batch.attachments.first)
    let session = session(with: attachment)
    try await store.saveLibrary(library(with: session, root: root))
    await batch.discard()
    try Data(manifest.utf8).write(to: manifestURL(root))
    let restarted = WorkspaceStore(baseURL: root)
    let loaded = await restarted.loadLibrary()
    #expect(!loaded.canPersist)
    await restarted.attachmentLifecycle.cleanup(reconcile: true)
    #expect(FileManager.default.fileExists(atPath: sessionURL(root, session.id).path))
    #expect(
      try ChatAttachmentStore(baseURL: root.appending(path: "Attachments")).storedAttachmentIDs()
        == [attachment.id])
  }

  @Test
  func queuedSnapshotLeaseSurvivesAnOlderCommitAndFullReconciliation() async throws {
    let root = try scopedTemporaryDirectory()
    let store = WorkspaceStore(baseURL: root)
    let batch = try await importedFile(in: root, lifecycle: store.attachmentLifecycle)
    let attachment = try #require(batch.attachments.first)
    let candidate = library(with: session(with: attachment), root: root)
    let queued = store.attachmentLifecycle.protect(candidate.attachmentIDs)
    await batch.discard()
    try await store.saveLibrary(WorkspaceLibrary())
    await store.attachmentLifecycle.cleanup(reconcile: true)
    let attachments = ChatAttachmentStore(baseURL: root.appending(path: "Attachments"))
    #expect(try attachments.storedAttachmentIDs() == [attachment.id])
    try await store.saveLibrary(candidate)
    queued.release()
    #expect(await store.retryCleanup().isEmpty)
    #expect(try attachments.storedAttachmentIDs() == [attachment.id])
    try await store.saveLibrary(WorkspaceLibrary())
    #expect(try attachments.storedAttachmentIDs().isEmpty)
  }

  private func importedFile(in root: URL, lifecycle: ChatAttachmentLifecycle) async throws
    -> ChatAttachmentImport
  {
    let source = root.appending(path: "source.txt")
    try Data("private bytes".utf8).write(to: source)
    return try await ChatAttachmentLoader(lifecycle: lifecycle).loadAttachments(
      from: [source], existingAttachments: [])
  }

  private func session(with attachment: ChatAttachment, assistant: Bool = false) -> ChatSession {
    let item: ChatTurnItem =
      assistant
      ? .assistantMessage(
        AssistantTurnMessage(
          content: "Answer", attachments: [attachment], deliveryStatus: .complete))
      : .userMessage(UserTurnMessage(content: "Question", attachments: [attachment]))
    return ChatSession(turns: [ChatTurn(status: .cancelled, items: [item])])
  }

  private func library(with session: ChatSession, root: URL) -> WorkspaceLibrary {
    WorkspaceLibrary(workspaces: [Workspace(name: "Project", rootURL: root, sessions: [session])])
  }

  private func manifestURL(_ root: URL) -> URL {
    root.appending(path: "WorkspaceLibrary/workspaces.json")
  }

  private func sessionURL(_ root: URL, _ id: UUID) -> URL {
    root.appending(path: "WorkspaceLibrary/sessions/\(id.uuidString.lowercased()).json")
  }
}
