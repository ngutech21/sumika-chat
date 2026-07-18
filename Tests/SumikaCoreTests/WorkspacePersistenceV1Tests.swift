import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
struct WorkspacePersistenceV1Tests {
  @Test
  func saveUsesVersionedManifestAndOneLowercaseFilePerSession() async throws {
    let baseURL = temporaryBaseURL()
    let library = makeLibrary()
    let store = WorkspaceStore(
      baseURL: baseURL,
      now: { Date(timeIntervalSince1970: 1_700_000_000.123) }
    )

    try await store.saveLibrary(library)

    let manifestData = try Data(contentsOf: manifestURL(baseURL: baseURL))
    let manifestText = try #require(String(data: manifestData, encoding: .utf8))
    let manifest = try WorkspacePersistenceCoding.makeDecoder().decode(
      WorkspaceLibraryManifest.self,
      from: manifestData
    )
    #expect(manifest.version == 1)
    #expect(manifest.workspaces.count == 1)
    #expect(manifest.workspaces[0].sessionIDs == library.workspaces[0].sessions.map(\.id))
    #expect(!manifestText.contains("\"sessions\""))
    #expect(manifestText.contains("\"updatedAt\" : \"2023-11-14T22:13:20.123Z\""))

    let sessionURLs = try FileManager.default.contentsOfDirectory(
      at: sessionsDirectoryURL(baseURL: baseURL),
      includingPropertiesForKeys: nil
    )
    let expectedSessionFileNames = Set(
      library.workspaces[0].sessions.map {
        "\($0.id.uuidString.lowercased()).json"
      }
    )
    #expect(
      Set(sessionURLs.map(\.lastPathComponent))
        == expectedSessionFileNames
    )

    let sessionURL = sessionFileURL(
      baseURL: baseURL,
      sessionID: library.workspaces[0].sessions[0].id
    )
    let sessionData = try Data(contentsOf: sessionURL)
    let document = try WorkspacePersistenceCoding.makeDecoder().decode(
      WorkspaceSessionDocument.self,
      from: sessionData
    )
    let sessionObject = try #require(
      JSONSerialization.jsonObject(with: sessionData) as? [String: Any]
    )
    #expect(document.version == 1)
    #expect(document.session.id == library.workspaces[0].sessions[0].id)
    #expect(sessionObject["workspaceID"] == nil)
    #expect(sessionObject["transcriptPath"] == nil)
    #expect(sessionObject["session"] != nil)
  }

  @Test
  func migrationMovesLegacyFixtureLosslesslyIntoV1AndDeletesLegacy() async throws {
    let baseURL = temporaryBaseURL()
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let legacyData = try Data(contentsOf: legacyFixtureURL)
    try legacyData.write(to: legacyURL(baseURL: baseURL))
    let diagnostics = DecodeDiagnostics()
    let expected = try legacyDecoder(diagnostics: diagnostics).decode(
      WorkspaceLibrary.self,
      from: legacyData
    )
    #expect(diagnostics.droppedElements.isEmpty)

    let result = await WorkspaceStore(
      baseURL: baseURL,
      now: { Date(timeIntervalSince1970: 1_700_000_000.123) }
    ).loadLibrary()

    #expect(result.issues.isEmpty)
    #expect(result.library == expected)
    #expect(FileManager.default.fileExists(atPath: manifestURL(baseURL: baseURL).path))
    #expect(!FileManager.default.fileExists(atPath: legacyURL(baseURL: baseURL).path))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: sessionsDirectoryURL(baseURL: baseURL),
        includingPropertiesForKeys: nil
      ).count == expected.workspaces.flatMap(\.sessions).count
    )

    let restarted = await WorkspaceStore(baseURL: baseURL).loadLibrary()
    #expect(restarted.issues.isEmpty)
    #expect(restarted.library == expected)
  }

  @Test
  func staleMigrationDirectoryDoesNotPreventRepeatableMigration() async throws {
    let baseURL = temporaryBaseURL()
    let staleStagingURL = baseURL.appending(
      path: "WorkspaceLibrary.migrating-stale",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: staleStagingURL,
      withIntermediateDirectories: true
    )
    try Data("interrupted".utf8).write(
      to: staleStagingURL.appending(path: "workspaces.json")
    )
    try Data(contentsOf: legacyFixtureURL).write(to: legacyURL(baseURL: baseURL))

    let result = await WorkspaceStore(baseURL: baseURL).loadLibrary()

    #expect(result.issues.isEmpty)
    #expect(!result.library.workspaces.isEmpty)
    #expect(FileManager.default.fileExists(atPath: manifestURL(baseURL: baseURL).path))
  }

  @Test
  func invalidLegacyDropsDuplicateIDsAndActiveReferencesBlockMigrationWithoutWrites()
    async throws
  {
    try await assertInvalidLegacyRemainsUntouched(makeLegacyWithDroppedSession())

    let duplicateSessionID = fixedUUID("BBBBBBBB-0000-0000-0000-000000000001")
    let duplicateLibrary = WorkspaceLibrary(
      workspaces: [
        Workspace(
          id: fixedUUID("AAAAAAAA-0000-0000-0000-000000000001"),
          name: "First",
          rootURL: URL(filePath: "/tmp/first", directoryHint: .isDirectory),
          sessions: [makeSession(id: duplicateSessionID, title: "First")]
        ),
        Workspace(
          id: fixedUUID("AAAAAAAA-0000-0000-0000-000000000002"),
          name: "Second",
          rootURL: URL(filePath: "/tmp/second", directoryHint: .isDirectory),
          sessions: [makeSession(id: duplicateSessionID, title: "Duplicate")]
        ),
      ]
    )
    try await assertInvalidLegacyRemainsUntouched(
      JSONEncoder().encode(duplicateLibrary)
    )

    let duplicateWorkspaceID = fixedUUID("AAAAAAAA-0000-0000-0000-000000000010")
    let duplicateWorkspaceLibrary = WorkspaceLibrary(
      workspaces: [
        Workspace(
          id: duplicateWorkspaceID,
          name: "First",
          rootURL: URL(filePath: "/tmp/first", directoryHint: .isDirectory)
        ),
        Workspace(
          id: duplicateWorkspaceID,
          name: "Duplicate",
          rootURL: URL(filePath: "/tmp/duplicate", directoryHint: .isDirectory)
        ),
      ]
    )
    try await assertInvalidLegacyRemainsUntouched(
      JSONEncoder().encode(duplicateWorkspaceLibrary)
    )

    let invalidActiveLibrary = WorkspaceLibrary(
      workspaces: [makeLibrary().workspaces[0]],
      activeWorkspaceID: fixedUUID("AAAAAAAA-0000-0000-0000-000000000099"),
      activeSessionID: nil
    )
    try await assertInvalidLegacyRemainsUntouched(
      JSONEncoder().encode(invalidActiveLibrary)
    )

    let validLibrary = makeLibrary()
    let invalidActiveSessionLibrary = WorkspaceLibrary(
      workspaces: validLibrary.workspaces,
      activeWorkspaceID: validLibrary.activeWorkspaceID,
      activeSessionID: fixedUUID("BBBBBBBB-0000-0000-0000-000000000099")
    )
    try await assertInvalidLegacyRemainsUntouched(
      JSONEncoder().encode(invalidActiveSessionLibrary)
    )
  }

  @Test
  func missingAndUnsupportedManifestVersionsFailClosed() async throws {
    try await assertManifestMutationFailsClosed { object in
      object.removeValue(forKey: "version")
    }

    try await assertManifestMutationFailsClosed(
      expectedIssue: { issue in
        guard case .unsupportedVersion(_, 2, 1) = issue else {
          return false
        }
        return true
      },
      mutation: { object in
        object["version"] = 2
      }
    )
  }

  @Test
  func versionedDirectoryWithoutManifestFailsClosed() async throws {
    let baseURL = temporaryBaseURL()
    let sessionsURL = sessionsDirectoryURL(baseURL: baseURL)
    try FileManager.default.createDirectory(
      at: sessionsURL,
      withIntermediateDirectories: true
    )
    let existingURL = sessionsURL.appending(
      path: "existing.json",
      directoryHint: .notDirectory
    )
    let existingData = Data("unreferenced".utf8)
    try existingData.write(to: existingURL)
    let store = WorkspaceStore(baseURL: baseURL)

    let result = await store.loadLibrary()

    #expect(!result.canPersist)
    guard case .decodeFailed = result.issues.first else {
      Issue.record("Expected decodeFailed, got \(result.issues)")
      return
    }
    #expect(try Data(contentsOf: existingURL) == existingData)
    await #expect(throws: Error.self) {
      try await store.saveLibrary(makeLibrary())
    }
    #expect(!FileManager.default.fileExists(atPath: manifestURL(baseURL: baseURL).path))
    #expect(try Data(contentsOf: existingURL) == existingData)
  }

  @Test
  func missingInvalidAndMismatchedReferencedSessionsFailClosed() async throws {
    try await assertSessionMutationFailsClosed { baseURL, sessionID in
      try FileManager.default.removeItem(
        at: sessionFileURL(baseURL: baseURL, sessionID: sessionID)
      )
    }

    try await assertSessionMutationFailsClosed { baseURL, sessionID in
      try FileManager.default.moveItem(
        at: sessionFileURL(baseURL: baseURL, sessionID: sessionID),
        to: sessionsDirectoryURL(baseURL: baseURL).appending(
          path: "bbbbbbbb-0000-0000-0000-000000000099.json",
          directoryHint: .notDirectory
        )
      )
    }

    try await assertSessionMutationFailsClosed { baseURL, sessionID in
      let url = sessionFileURL(baseURL: baseURL, sessionID: sessionID)
      var object = try jsonObject(at: url)
      object.removeValue(forKey: "version")
      try writeJSONObject(object, to: url)
    }

    try await assertSessionMutationFailsClosed(
      expectedIssue: { issue in
        guard case .unsupportedVersion(_, 9, 1) = issue else {
          return false
        }
        return true
      },
      mutation: { baseURL, sessionID in
        let url = sessionFileURL(baseURL: baseURL, sessionID: sessionID)
        var object = try jsonObject(at: url)
        object["version"] = 9
        try writeJSONObject(object, to: url)
      }
    )

    try await assertSessionMutationFailsClosed { baseURL, sessionID in
      let url = sessionFileURL(baseURL: baseURL, sessionID: sessionID)
      var object = try jsonObject(at: url)
      var session = try #require(object["session"] as? [String: Any])
      session["id"] = "BBBBBBBB-0000-0000-0000-000000000099"
      object["session"] = session
      try writeJSONObject(object, to: url)
    }
  }

  @Test
  func unreferencedSessionFileIsIgnored() async throws {
    let baseURL = temporaryBaseURL()
    let library = makeLibrary()
    let store = WorkspaceStore(baseURL: baseURL)
    try await store.saveLibrary(library)
    let orphanURL = sessionsDirectoryURL(baseURL: baseURL)
      .appending(path: "orphan.json", directoryHint: .notDirectory)
    try Data("not json".utf8).write(to: orphanURL)

    let result = await WorkspaceStore(baseURL: baseURL).loadLibrary()

    #expect(result.issues.isEmpty)
    #expect(result.library == library)
    #expect(FileManager.default.fileExists(atPath: orphanURL.path))
  }

  @Test
  func sessionOnlySaveDoesNotRewriteManifestOrSiblingSession() async throws {
    let baseURL = temporaryBaseURL()
    let library = makeLibrary()
    let store = WorkspaceStore(baseURL: baseURL)
    try await store.saveLibrary(library)

    let manifestURL = manifestURL(baseURL: baseURL)
    let firstSessionURL = sessionFileURL(
      baseURL: baseURL,
      sessionID: library.workspaces[0].sessions[0].id
    )
    let siblingSessionURL = sessionFileURL(
      baseURL: baseURL,
      sessionID: library.workspaces[0].sessions[1].id
    )
    let sentinelDate = Date(timeIntervalSince1970: 100)
    try setModificationDate(sentinelDate, for: manifestURL)
    try setModificationDate(sentinelDate, for: siblingSessionURL)
    let originalManifest = try Data(contentsOf: manifestURL)
    let originalSibling = try Data(contentsOf: siblingSessionURL)
    let originalWorkspaceUpdatedAt = library.workspaces[0].updatedAt

    var updatedLibrary = library
    updatedLibrary.workspaces[0].sessions[0].title = "Session-only change"
    updatedLibrary.workspaces[0].sessions[0].updatedAt =
      Date(timeIntervalSince1970: 1_700_000_010.456)
    try await store.saveLibrary(updatedLibrary)

    #expect(updatedLibrary.workspaces[0].updatedAt == originalWorkspaceUpdatedAt)
    #expect(try Data(contentsOf: manifestURL) == originalManifest)
    #expect(try Data(contentsOf: siblingSessionURL) == originalSibling)
    #expect(try modificationDate(for: manifestURL) == sentinelDate)
    #expect(try modificationDate(for: siblingSessionURL) == sentinelDate)
    #expect(try modificationDate(for: firstSessionURL) != sentinelDate)
  }

  @Test
  func freshStoreLoadsItsSnapshotBeforeSavingAndKeepsANoOpSaveByteStable() async throws {
    let baseURL = temporaryBaseURL()
    let library = makeLibrary()
    try await WorkspaceStore(baseURL: baseURL).saveLibrary(library)
    let manifestURL = manifestURL(baseURL: baseURL)
    let sessionURLs = library.workspaces[0].sessions.map {
      sessionFileURL(baseURL: baseURL, sessionID: $0.id)
    }
    let sentinelDate = Date(timeIntervalSince1970: 100)
    try setModificationDate(sentinelDate, for: manifestURL)
    for url in sessionURLs {
      try setModificationDate(sentinelDate, for: url)
    }

    try await WorkspaceStore(baseURL: baseURL).saveLibrary(library)

    #expect(try modificationDate(for: manifestURL) == sentinelDate)
    for url in sessionURLs {
      #expect(try modificationDate(for: url) == sentinelDate)
    }
  }

  @Test
  func workspaceAndSelectionChangesRewriteOnlyManifest() async throws {
    let baseURL = temporaryBaseURL()
    var library = makeLibrary()
    let store = WorkspaceStore(baseURL: baseURL)
    try await store.saveLibrary(library)

    let sessionURLs = library.workspaces[0].sessions.map {
      sessionFileURL(baseURL: baseURL, sessionID: $0.id)
    }
    let sentinelDate = Date(timeIntervalSince1970: 100)
    for url in sessionURLs {
      try setModificationDate(sentinelDate, for: url)
    }
    let manifestBefore = try Data(contentsOf: manifestURL(baseURL: baseURL))
    let manifestTimestampBefore = try WorkspacePersistenceCoding.makeDecoder().decode(
      WorkspaceLibraryManifest.self,
      from: manifestBefore
    ).updatedAt
    try await Task.sleep(for: .milliseconds(5))

    library.activeSessionID = library.workspaces[0].sessions[1].id
    library.workspaces[0].name = "Renamed Workspace"
    library.workspaces[0].updatedAt = Date(timeIntervalSince1970: 1_700_000_020.789)
    try await store.saveLibrary(library)

    let manifestAfterData = try Data(contentsOf: manifestURL(baseURL: baseURL))
    let manifestAfter = try WorkspacePersistenceCoding.makeDecoder().decode(
      WorkspaceLibraryManifest.self,
      from: manifestAfterData
    )
    #expect(manifestAfterData != manifestBefore)
    #expect(manifestAfter.updatedAt > manifestTimestampBefore)
    #expect(manifestAfter.activeSessionID == library.activeSessionID)
    #expect(manifestAfter.workspaces[0].name == "Renamed Workspace")
    for url in sessionURLs {
      #expect(try modificationDate(for: url) == sentinelDate)
    }
  }

  @Test
  func sessionCreationAndDeletionUpdateManifestMembershipAndFiles() async throws {
    let baseURL = temporaryBaseURL()
    var library = makeLibrary()
    let store = WorkspaceStore(baseURL: baseURL)
    try await store.saveLibrary(library)

    let newSession = makeSession(
      id: fixedUUID("BBBBBBBB-0000-0000-0000-000000000003"),
      title: "Third"
    )
    library.workspaces[0].sessions.append(newSession)
    library.workspaces[0].updatedAt = Date(timeIntervalSince1970: 1_700_000_030.123)
    try await store.saveLibrary(library)
    let newSessionURL = sessionFileURL(baseURL: baseURL, sessionID: newSession.id)
    #expect(FileManager.default.fileExists(atPath: newSessionURL.path))
    var manifest = try readManifest(baseURL: baseURL)
    #expect(manifest.workspaces[0].sessionIDs.last == newSession.id)

    library.workspaces[0].sessions.removeAll { $0.id == newSession.id }
    library.workspaces[0].updatedAt = Date(timeIntervalSince1970: 1_700_000_040.123)
    try await store.saveLibrary(library)
    manifest = try readManifest(baseURL: baseURL)
    #expect(!manifest.workspaces[0].sessionIDs.contains(newSession.id))
    #expect(!FileManager.default.fileExists(atPath: newSessionURL.path))
  }

  @Test
  func versionedLibraryWinsWhenLegacyFileAlsoExists() async throws {
    let baseURL = temporaryBaseURL()
    let library = makeLibrary()
    try await WorkspaceStore(baseURL: baseURL).saveLibrary(library)
    let legacyLibrary = WorkspaceLibrary(
      workspaces: [
        Workspace(
          name: "Must not merge",
          rootURL: URL(filePath: "/tmp/legacy", directoryHint: .isDirectory)
        )
      ]
    )
    try JSONEncoder().encode(legacyLibrary).write(to: legacyURL(baseURL: baseURL))

    let result = await WorkspaceStore(baseURL: baseURL).loadLibrary()

    #expect(result.issues.isEmpty)
    #expect(result.library == library)
    #expect(!FileManager.default.fileExists(atPath: legacyURL(baseURL: baseURL).path))
  }

  private func assertInvalidLegacyRemainsUntouched(_ data: Data) async throws {
    let baseURL = temporaryBaseURL()
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let legacyURL = legacyURL(baseURL: baseURL)
    try data.write(to: legacyURL)

    let result = await WorkspaceStore(baseURL: baseURL).loadLibrary()

    #expect(!result.canPersist)
    guard case .migrationFailed = result.issues.first else {
      Issue.record("Expected migrationFailed, got \(result.issues)")
      return
    }
    #expect(try Data(contentsOf: legacyURL) == data)
    #expect(!FileManager.default.fileExists(atPath: manifestURL(baseURL: baseURL).path))
  }

  private func assertManifestMutationFailsClosed(
    expectedIssue: (WorkspaceLibraryLoadIssue) -> Bool = { issue in
      guard case .decodeFailed = issue else {
        return false
      }
      return true
    },
    mutation: (inout [String: Any]) throws -> Void
  ) async throws {
    let baseURL = temporaryBaseURL()
    try await WorkspaceStore(baseURL: baseURL).saveLibrary(makeLibrary())
    let url = manifestURL(baseURL: baseURL)
    var object = try jsonObject(at: url)
    try mutation(&object)
    try writeJSONObject(object, to: url)
    let filesBefore = try persistenceFiles(baseURL: baseURL)
    let store = WorkspaceStore(baseURL: baseURL)

    let result = await store.loadLibrary()

    #expect(!result.canPersist)
    #expect(result.issues.first.map(expectedIssue) == true)
    #expect(try persistenceFiles(baseURL: baseURL) == filesBefore)
    await #expect(throws: Error.self) {
      try await store.saveLibrary(makeLibrary())
    }
    #expect(try persistenceFiles(baseURL: baseURL) == filesBefore)
  }

  private func assertSessionMutationFailsClosed(
    expectedIssue: (WorkspaceLibraryLoadIssue) -> Bool = { issue in
      switch issue {
      case .readFailed, .decodeFailed:
        true
      case .migrationFailed, .unsupportedVersion, .legacyCleanupFailed:
        false
      }
    },
    mutation: (URL, ChatSession.ID) throws -> Void
  ) async throws {
    let baseURL = temporaryBaseURL()
    let library = makeLibrary()
    try await WorkspaceStore(baseURL: baseURL).saveLibrary(library)
    let sessionID = library.workspaces[0].sessions[0].id
    try mutation(baseURL, sessionID)
    let filesBefore = try persistenceFiles(baseURL: baseURL)
    let store = WorkspaceStore(baseURL: baseURL)

    let result = await store.loadLibrary()

    #expect(!result.canPersist)
    #expect(result.issues.first.map(expectedIssue) == true)
    #expect(try persistenceFiles(baseURL: baseURL) == filesBefore)
    await #expect(throws: Error.self) {
      try await store.saveLibrary(library)
    }
    #expect(try persistenceFiles(baseURL: baseURL) == filesBefore)
  }

  private func makeLegacyWithDroppedSession() throws -> Data {
    let library = makeLibrary()
    var root = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any]
    )
    var workspaces = try #require(root["workspaces"] as? [[String: Any]])
    var sessions = try #require(workspaces[0]["sessions"] as? [[String: Any]])
    sessions[0]["interactionMode"] = 42
    workspaces[0]["sessions"] = sessions
    root["workspaces"] = workspaces
    return try JSONSerialization.data(withJSONObject: root)
  }

  private func makeLibrary() -> WorkspaceLibrary {
    let workspaceID = fixedUUID("AAAAAAAA-0000-0000-0000-000000000001")
    let firstSession = makeSession(
      id: fixedUUID("BBBBBBBB-0000-0000-0000-000000000001"),
      title: "First"
    )
    let secondSession = makeSession(
      id: fixedUUID("BBBBBBBB-0000-0000-0000-000000000002"),
      title: "Second"
    )
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      bookmarkData: Data([1, 2, 3]),
      sessions: [firstSession, secondSession],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    return WorkspaceLibrary(
      workspaces: [workspace],
      activeWorkspaceID: workspaceID,
      activeSessionID: firstSession.id
    )
  }

  private func makeSession(id: ChatSession.ID, title: String) -> ChatSession {
    ChatSession(
      id: id,
      title: title,
      selectedModelID: "gemma4-12b-qat-4bit",
      modeSettings: testModeSettings(
        systemPrompt: "Test",
        generationSettings: .agentDefault
      ),
      createdAt: Date(timeIntervalSince1970: 1_700_000_002),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_003)
    )
  }

  private func readManifest(baseURL: URL) throws -> WorkspaceLibraryManifest {
    try WorkspacePersistenceCoding.makeDecoder().decode(
      WorkspaceLibraryManifest.self,
      from: Data(contentsOf: manifestURL(baseURL: baseURL))
    )
  }

  private func jsonObject(at url: URL) throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
  }

  private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
  }

  private func persistenceFiles(baseURL: URL) throws -> [String: Data] {
    var files = [
      "workspaces.json": try Data(contentsOf: manifestURL(baseURL: baseURL))
    ]
    for url in try FileManager.default.contentsOfDirectory(
      at: sessionsDirectoryURL(baseURL: baseURL),
      includingPropertiesForKeys: nil
    ) {
      files["sessions/\(url.lastPathComponent)"] = try Data(contentsOf: url)
    }
    return files
  }

  private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  private func modificationDate(for url: URL) throws -> Date {
    try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    )
  }

  private func legacyDecoder(diagnostics: DecodeDiagnostics) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[.decodeDiagnostics] = diagnostics
    return decoder
  }

  private var legacyFixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures", directoryHint: .isDirectory)
      .appending(path: "workspace-library-golden.json", directoryHint: .notDirectory)
  }

  private func temporaryBaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(
        path: "sumika-workspace-v1-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
  }

  private func legacyURL(baseURL: URL) -> URL {
    baseURL.appending(path: "workspaces.json", directoryHint: .notDirectory)
  }

  private func manifestURL(baseURL: URL) -> URL {
    baseURL
      .appending(path: "WorkspaceLibrary", directoryHint: .isDirectory)
      .appending(path: "workspaces.json", directoryHint: .notDirectory)
  }

  private func sessionsDirectoryURL(baseURL: URL) -> URL {
    baseURL
      .appending(path: "WorkspaceLibrary", directoryHint: .isDirectory)
      .appending(path: "sessions", directoryHint: .isDirectory)
  }

  private func sessionFileURL(baseURL: URL, sessionID: ChatSession.ID) -> URL {
    sessionsDirectoryURL(baseURL: baseURL)
      .appending(
        path: "\(sessionID.uuidString.lowercased()).json",
        directoryHint: .notDirectory
      )
  }

  private func fixedUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
      preconditionFailure("Invalid fixed UUID: \(value)")
    }
    return uuid
  }
}
