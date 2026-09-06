import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "workspace-session-migration"))
struct WorkspaceSessionMigrationTests {
  @Test
  func frozenV1GoldenSessionMapsWithoutLoss() throws {
    let url = try #require(
      Bundle.module.url(forResource: "workspace-session-v1-golden", withExtension: "json"))
    let decoder = WorkspacePersistenceCoding.makeDecoder()
    let document = try decoder.decode(WorkspaceSessionDocumentV1.self, from: Data(contentsOf: url))
    #expect(document.version == 1)
    #expect(
      document.session.value
        == WorkspaceLibraryGoldenFixture.makeLibrary().workspaces[0].sessions[0])
  }

  @Test
  func migrationPreservesMultipleFocusedFileSnapshots() async throws {
    let (base, original) = try await prepareLegacySessions()
    var library = original
    let timestamp = library.workspaces[0].sessions[0].updatedAt
    for index in 0..<24 {
      library.workspaces[0].sessions[0].focusedFileState.snapshots[
        .init(rawValue: "file-\(index).swift")
      ] = .init(
        contentHash: "hash-\(index)", excerpt: "content-\(index)",
        fullContentAvailable: true, updatedAt: timestamp)
    }
    let session = library.workspaces[0].sessions[0]
    let url = sessionURL(base: base, id: session.id)
    try WorkspacePersistenceCoding.makeEncoder().encode(
      WorkspaceSessionDocument(version: 1, session: session)
    ).write(to: url)

    let result = await WorkspaceStore(baseURL: base).loadLibrary()

    #expect(result.canPersist)
    #expect(result.library == library)
    #expect(try version(at: url) == 2)
    #expect(await WorkspaceStore(baseURL: base).loadLibrary().library == library)
  }

  @Test(arguments: ["missing", "invalid", "future"])
  func restoresReadableSessionsWhenOneSessionIsUnavailable(failure: String) async throws {
    let (base, library) = try await prepareLegacySessions()
    let unavailable = library.workspaces[0].sessions[0]
    let url = sessionURL(base: base, id: unavailable.id)
    let original = try Data(contentsOf: url)
    switch failure {
    case "missing":
      try FileManager.default.removeItem(at: url)
    case "future":
      try WorkspacePersistenceCoding.makeEncoder().encode(
        WorkspaceSessionDocument(version: 9, session: unavailable)
      ).write(to: url)
    default:
      try Data("invalid".utf8).write(to: url)
    }
    let manifest = base.appending(path: "WorkspaceLibrary/workspaces.json")
    let manifestBefore = try Data(contentsOf: manifest)
    let sibling = sessionURL(base: base, id: library.workspaces[0].sessions[1].id)
    let siblingBefore = try Data(contentsOf: sibling)
    var expected = library
    expected.workspaces[0].sessions.removeFirst()
    if expected.activeSessionID == unavailable.id { expected.activeSessionID = nil }
    let store = WorkspaceStore(baseURL: base)

    let result = await store.loadLibrary()

    #expect(result.library == expected)
    #expect(!result.canPersist)
    #expect(result.issues.count == 1)
    #expect(try Data(contentsOf: manifest) == manifestBefore)
    #expect(try Data(contentsOf: sibling) == siblingBefore)
    await #expect(throws: Error.self) { try await store.saveLibrary(result.library) }
    #expect(await store.retryCleanup().isEmpty)
    try original.write(to: url)
    let recovered = await store.loadLibrary()
    #expect(recovered.canPersist)
    #expect(recovered.library == library)
  }

  @Test
  func migrationPreservesDefaultsForMissingTimestamps() async throws {
    let (base, library) = try await prepareLegacySessions()
    let url = sessionURL(base: base, id: library.workspaces[0].sessions[0].id)
    var document = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var session = try #require(document["session"] as? [String: Any])
    session.removeValue(forKey: "createdAt")
    session.removeValue(forKey: "updatedAt")
    session["todoState"] = ["items": []]
    var turns = try #require(session["turns"] as? [[String: Any]])
    for index in turns.indices {
      turns[index].removeValue(forKey: "createdAt")
      turns[index].removeValue(forKey: "updatedAt")
    }
    session["turns"] = turns
    document["session"] = session
    try JSONSerialization.data(withJSONObject: document).write(to: url)

    let result = await WorkspaceStore(baseURL: base).loadLibrary()

    #expect(result.canPersist)
    #expect(result.library.workspaces.first?.sessions.first?.turns.count == turns.count)
    #expect(try version(at: url) == 2)
  }

  @Test
  func migrationPreservesV1DefaultsForOmittedFields() async throws {
    let (base, library) = try await prepareLegacySessions()
    let url = sessionURL(base: base, id: library.workspaces[0].sessions[0].id)
    var document = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var session = try #require(document["session"] as? [String: Any])
    for key in [
      "title", "selectedModelID", "focusedFileState", "modeSettings", "interactionMode",
      "toolApprovalPolicy", "selectedMCPServerIDs", "todoState", "updatedAt",
    ] {
      session.removeValue(forKey: key)
    }
    var turns = try #require(session["turns"] as? [[String: Any]])
    for index in turns.indices {
      for key in ["status", "modelContextPolicy", "updatedAt"] {
        turns[index].removeValue(forKey: key)
      }
    }
    session["turns"] = turns
    document["session"] = session
    let bytes = try JSONSerialization.data(withJSONObject: document)
    let expected = try WorkspacePersistenceCoding.makeDecoder().decode(
      WorkspaceSessionDocument.self, from: bytes
    ).session
    try bytes.write(to: url)
    let result = await WorkspaceStore(baseURL: base).loadLibrary()
    #expect(result.canPersist)
    #expect(result.library.workspaces.first?.sessions.first == expected)
    #expect(try version(at: url) == 2)
  }

  @Test
  func upgradesV1AndMixedSessionsWithoutChangingManifest() async throws {
    let (base, library) = try await prepareLegacySessions()
    let manifest = base.appending(path: "WorkspaceLibrary/workspaces.json")
    let before = try Data(contentsOf: manifest)
    let result = await WorkspaceStore(baseURL: base).loadLibrary()
    #expect(result.issues.isEmpty)
    #expect(result.library == library)
    #expect(try Data(contentsOf: manifest) == before)
    for session in library.workspaces[0].sessions {
      #expect(try version(at: sessionURL(base: base, id: session.id)) == 2)
    }
    let restarted = await WorkspaceStore(baseURL: base).loadLibrary()
    #expect(restarted.library == library)
    #expect(restarted.issues.isEmpty)
  }

  @Test
  func interruptedUpgradeBlocksWritesAndResumesMixedVersions() async throws {
    let (base, library) = try await prepareLegacySessions()
    let ids = library.workspaces[0].sessions.map(\.id)
    let second = sessionURL(base: base, id: ids[1])
    let original = try Data(contentsOf: second)
    let store = WorkspaceStore(
      baseURL: base,
      writeData: { data, url in
        if url == second { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
      })
    let failed = await store.loadLibrary()
    #expect(!failed.canPersist)
    #expect(failed.library == library)
    #expect(try version(at: sessionURL(base: base, id: ids[0])) == 2)
    #expect(try Data(contentsOf: second) == original)
    await #expect(throws: Error.self) { try await store.saveLibrary(library) }
    #expect(await store.retryCleanup().isEmpty)
    let retried = await WorkspaceStore(baseURL: base).loadLibrary()
    #expect(retried.issues.isEmpty)
    #expect(retried.library == library)
    #expect(try version(at: second) == 2)
  }

  @Test
  func invalidSiblingPreventsAllMigrationWrites() async throws {
    let (base, library) = try await prepareLegacySessions()
    let ids = library.workspaces[0].sessions.map(\.id)
    let first = sessionURL(base: base, id: ids[0])
    let before = try Data(contentsOf: first)
    try Data("invalid".utf8).write(to: sessionURL(base: base, id: ids[1]))
    let result = await WorkspaceStore(baseURL: base).loadLibrary()
    #expect(!result.canPersist)
    #expect(try Data(contentsOf: first) == before)
  }

  @Test(arguments: ["pending", "completed", "preview"])
  func newToolVariantsAreNeverAcceptedAsV1(location: String) async throws {
    let (base, library) = try await prepareLegacySessions()
    let session = library.workspaces[0].sessions[0]
    let content = try ReadDocumentContent(path: .init(rawValue: "report.pdf"), markdown: "document")
    let toolName: ToolName = location == "pending" ? .readDocument : .readFile
    let input: ToolCallPayload =
      location == "pending"
      ? .readDocument(.init(path: "report.pdf")) : .readFile(.init(path: "notes.txt"))
    let request = ToolCallRequest.validated(
      raw: RawToolCallRequest(
        workspaceID: library.workspaces[0].id, sessionID: session.id, toolName: toolName),
      payload: input)
    let state: ToolCallState =
      location == "pending"
      ? .pending
      : location == "completed"
        ? .completed(.readDocument(.success(content)))
        : .awaitingApproval(
          preview: .init(text: "preview", resultPayload: .readDocument(.success(content))))
    let record = ToolCallRecord(
      request: request, evaluation: .init(decision: .allowed, reason: "test", riskLevel: .low),
      state: state)
    let changed = ChatSession(
      id: session.id, turns: [.init(status: .completed, items: [.tool(record)])])
    let url = sessionURL(base: base, id: session.id)
    let bytes = try WorkspacePersistenceCoding.makeEncoder().encode(
      WorkspaceSessionDocument(version: 1, session: changed))
    try bytes.write(to: url)
    let store = WorkspaceStore(baseURL: base)
    #expect(await store.loadLibrary().canPersist == false)
    await #expect(throws: Error.self) { try await store.saveLibrary(library) }
    #expect(try Data(contentsOf: url) == bytes)
  }

  @Test
  func preservesFutureAndCorruptOrphans() async throws {
    let (base, _) = try await prepareLegacySessions()
    for version in [2, 9] {
      let session = ChatSession()
      var bytes = try WorkspacePersistenceCoding.makeEncoder().encode(
        WorkspaceSessionDocument(version: version, session: session))
      if version == 2 {
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var body = try #require(object["session"] as? [String: Any])
        body["turns"] = [["items": [["kind": "future", "payload": [:]]]]]
        object["session"] = body
        bytes = try JSONSerialization.data(withJSONObject: object)
      }
      let url = sessionURL(base: base, id: session.id)
      try bytes.write(to: url)
      #expect(await WorkspaceStore(baseURL: base).loadLibrary().canPersist)
      #expect(try Data(contentsOf: url) == bytes)
    }
  }

  private func prepareLegacySessions() async throws -> (URL, WorkspaceLibrary) {
    let base = try scopedTemporaryDirectory()
    let library = WorkspaceLibraryGoldenFixture.makeLibrary()
    try await WorkspaceStore(baseURL: base).saveLibrary(library)
    for session in library.workspaces[0].sessions {
      let bytes = try WorkspacePersistenceCoding.makeEncoder().encode(
        WorkspaceSessionDocument(version: 1, session: session))
      try bytes.write(to: sessionURL(base: base, id: session.id))
    }
    return (base, library)
  }

  private func sessionURL(base: URL, id: UUID) -> URL {
    base.appending(path: "WorkspaceLibrary/sessions/\(id.uuidString.lowercased()).json")
  }

  private func version(at url: URL) throws -> Int {
    try JSONDecoder().decode(WorkspacePersistenceVersionProbe.self, from: Data(contentsOf: url))
      .version
  }
}
