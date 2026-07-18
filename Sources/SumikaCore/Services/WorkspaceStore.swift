import Foundation

#if canImport(OSLog)
  import OSLog
#endif

public protocol WorkspaceStoring: Sendable {
  func loadLibrary() async -> WorkspaceLibraryLoadResult
  func saveLibrary(_ library: WorkspaceLibrary) async throws
}

/// The loaded library plus every issue encountered while loading it. An empty
/// `issues` array means the on-disk state was read back verbatim.
public struct WorkspaceLibraryLoadResult: Equatable, Sendable {
  public let library: WorkspaceLibrary
  public let issues: [WorkspaceLibraryLoadIssue]

  public init(library: WorkspaceLibrary, issues: [WorkspaceLibraryLoadIssue] = []) {
    self.library = library
    self.issues = issues
  }

  public var canPersist: Bool {
    issues.allSatisfy(\.isSafeToPersistOver)
  }
}

public enum WorkspaceLibraryLoadIssue: Equatable, Sendable {
  /// A persisted document exists but could not be read. All files remain untouched.
  case readFailed(message: String)
  /// A persisted document is invalid for its declared format. All files remain untouched.
  case decodeFailed(message: String)
  /// The one supported legacy migration could not complete losslessly.
  case migrationFailed(message: String)
  /// A persisted document belongs to a newer or otherwise unsupported format.
  case unsupportedVersion(path: String, found: Int, supported: Int)
  /// Versioned data loaded successfully, but the obsolete legacy file remains.
  case legacyCleanupFailed(message: String)

  public var isSafeToPersistOver: Bool {
    switch self {
    case .legacyCleanupFailed:
      true
    case .readFailed, .decodeFailed, .migrationFailed, .unsupportedVersion:
      false
    }
  }
}

public actor WorkspaceStore: WorkspaceStoring {
  nonisolated private let baseURL: URL
  nonisolated private let libraryDirectoryURL: URL
  nonisolated private let manifestURL: URL
  nonisolated private let sessionsDirectoryURL: URL
  nonisolated private let legacyLibraryURL: URL
  nonisolated private let now: @Sendable () -> Date

  private var isPersistenceBlocked = false
  private var lastPersistedLibrary: WorkspaceLibrary?
  private var lastPersistedManifest: WorkspaceLibraryManifest?

  public init(
    baseURL: URL = LocalModelDirectory.defaultBaseURL.deletingLastPathComponent(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.baseURL = baseURL
    self.libraryDirectoryURL = baseURL.appending(
      path: "WorkspaceLibrary",
      directoryHint: .isDirectory
    )
    self.manifestURL = libraryDirectoryURL.appending(
      path: "workspaces.json",
      directoryHint: .notDirectory
    )
    self.sessionsDirectoryURL = libraryDirectoryURL.appending(
      path: "sessions",
      directoryHint: .isDirectory
    )
    self.legacyLibraryURL = baseURL.appending(
      path: "workspaces.json",
      directoryHint: .notDirectory
    )
    self.now = now
  }

  public func loadLibrary() async -> WorkspaceLibraryLoadResult {
    do {
      let loaded: LoadedWorkspaceLibrary
      if FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) {
        loaded = try loadVersionedLibrary(from: libraryDirectoryURL)
      } else if FileManager.default.fileExists(
        atPath: legacyLibraryURL.path(percentEncoded: false)
      ) {
        loaded = try migrateLegacyLibrary()
      } else if FileManager.default.fileExists(
        atPath: libraryDirectoryURL.path(percentEncoded: false)
      ) {
        throw WorkspacePersistenceError.invalidData(
          path: manifestURL.path(percentEncoded: false),
          reason: "The versioned workspace directory exists without its manifest."
        )
      } else {
        let library = WorkspaceLibrary()
        lastPersistedLibrary = library
        lastPersistedManifest = nil
        isPersistenceBlocked = false
        return WorkspaceLibraryLoadResult(library: library)
      }

      lastPersistedLibrary = loaded.library
      lastPersistedManifest = loaded.manifest
      isPersistenceBlocked = false

      if FileManager.default.fileExists(atPath: legacyLibraryURL.path(percentEncoded: false)) {
        do {
          try FileManager.default.removeItem(at: legacyLibraryURL)
        } catch {
          let message =
            "Failed to remove legacy workspace library. "
            + "error=\(String(reflecting: error))"
          logIssue(message)
          return WorkspaceLibraryLoadResult(
            library: loaded.library,
            issues: [.legacyCleanupFailed(message: message)]
          )
        }
      }

      return WorkspaceLibraryLoadResult(library: loaded.library)
    } catch {
      isPersistenceBlocked = true
      lastPersistedLibrary = nil
      lastPersistedManifest = nil
      let issue = loadIssue(for: error)
      logIssue(issue.logMessage)
      return WorkspaceLibraryLoadResult(library: WorkspaceLibrary(), issues: [issue])
    }
  }

  public func saveLibrary(_ library: WorkspaceLibrary) async throws {
    guard !isPersistenceBlocked else {
      throw WorkspacePersistenceError.persistenceBlocked
    }
    if lastPersistedLibrary == nil,
      FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false))
        || FileManager.default.fileExists(atPath: legacyLibraryURL.path(percentEncoded: false))
        || FileManager.default.fileExists(
          atPath: libraryDirectoryURL.path(percentEncoded: false)
        )
    {
      let loadResult = await loadLibrary()
      guard loadResult.canPersist else {
        throw WorkspacePersistenceError.persistenceBlocked
      }
    }
    try Self.validate(library)

    let previousSessions = Self.sessionsByID(in: lastPersistedLibrary)
    let nextSessions = Self.sessionsByID(in: library)
    let changedSessions = nextSessions.values.filter { session in
      previousSessions[session.id] != session
    }
    let removedSessionIDs = Set(previousSessions.keys).subtracting(nextSessions.keys)

    let candidateManifest = WorkspaceLibraryManifest(
      library: library,
      updatedAt: lastPersistedManifest?.updatedAt ?? now()
    )
    let manifestChanged =
      lastPersistedManifest?.hasSameLogicalContent(as: candidateManifest) != true
    let manifestUpdatedAt: Date
    if manifestChanged {
      manifestUpdatedAt = WorkspacePersistenceCoding.normalizedToMilliseconds(now())
    } else if let persistedUpdatedAt = lastPersistedManifest?.updatedAt {
      manifestUpdatedAt = persistedUpdatedAt
    } else {
      manifestUpdatedAt = WorkspacePersistenceCoding.normalizedToMilliseconds(now())
    }
    let nextManifest = WorkspaceLibraryManifest(
      library: library,
      updatedAt: manifestUpdatedAt
    )

    if !changedSessions.isEmpty || manifestChanged {
      try FileManager.default.createDirectory(
        at: sessionsDirectoryURL,
        withIntermediateDirectories: true
      )
    }

    for session in changedSessions {
      try writeSession(session, to: sessionsDirectoryURL)
    }

    if manifestChanged {
      try writeManifest(nextManifest, to: manifestURL)
    }

    for sessionID in removedSessionIDs {
      try removeSessionFileIfPresent(sessionID, from: sessionsDirectoryURL)
    }

    lastPersistedLibrary = library
    if manifestChanged {
      lastPersistedManifest = nextManifest
    }
  }

  private func migrateLegacyLibrary() throws -> LoadedWorkspaceLibrary {
    let legacyData: Data
    do {
      legacyData = try Data(contentsOf: legacyLibraryURL)
    } catch {
      throw WorkspacePersistenceError.readFailed(
        path: legacyLibraryURL.path(percentEncoded: false),
        underlying: error
      )
    }

    do {
      let rootObject = try JSONSerialization.jsonObject(with: legacyData)
      guard let root = rootObject as? [String: Any], root["version"] == nil else {
        throw WorkspacePersistenceError.invalidLegacy(
          "Only an unversioned object at the legacy path can be migrated."
        )
      }
    } catch let error as WorkspacePersistenceError {
      throw error
    } catch {
      throw WorkspacePersistenceError.invalidLegacy(
        "Legacy workspace library is not a JSON object. error=\(String(reflecting: error))"
      )
    }

    let diagnostics = DecodeDiagnostics()
    let library: WorkspaceLibrary
    do {
      library = try Self.makeLegacyDecoder(diagnostics: diagnostics).decode(
        WorkspaceLibrary.self,
        from: legacyData
      )
    } catch {
      throw WorkspacePersistenceError.invalidLegacy(
        "Legacy workspace library could not be decoded. error=\(String(reflecting: error))"
      )
    }
    guard diagnostics.droppedElements.isEmpty else {
      throw WorkspacePersistenceError.invalidLegacy(
        "Legacy workspace library dropped elements: \(diagnostics.summaries.joined(separator: "; "))"
      )
    }
    do {
      try Self.validate(library)
    } catch {
      throw WorkspacePersistenceError.invalidLegacy(
        "Legacy workspace library violates v1 invariants. error=\(String(reflecting: error))"
      )
    }

    let stagingURL = baseURL.appending(
      path: "WorkspaceLibrary.migrating-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    let migrationTimestamp = WorkspacePersistenceCoding.normalizedToMilliseconds(now())
    do {
      let manifest = try writeCompleteLibrary(
        library,
        to: stagingURL,
        manifestUpdatedAt: migrationTimestamp
      )
      let staged = try loadVersionedLibrary(from: stagingURL)
      try validateMigrationResult(
        source: library,
        staged: staged.library,
        manifestUpdatedAt: manifest.updatedAt
      )
      guard
        !FileManager.default.fileExists(
          atPath: libraryDirectoryURL.path(percentEncoded: false)
        )
      else {
        throw WorkspacePersistenceError.invalidLegacy(
          "Versioned workspace directory already exists without a readable manifest."
        )
      }
      try FileManager.default.moveItem(at: stagingURL, to: libraryDirectoryURL)
      return staged
    } catch {
      try? FileManager.default.removeItem(at: stagingURL)
      if let persistenceError = error as? WorkspacePersistenceError {
        throw persistenceError
      }
      throw WorkspacePersistenceError.invalidLegacy(
        "Failed to write and validate versioned workspace data. error=\(String(reflecting: error))"
      )
    }
  }

  private func writeCompleteLibrary(
    _ library: WorkspaceLibrary,
    to directoryURL: URL,
    manifestUpdatedAt: Date
  ) throws -> WorkspaceLibraryManifest {
    let sessionDirectoryURL = directoryURL.appending(
      path: "sessions",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: sessionDirectoryURL,
      withIntermediateDirectories: true
    )
    for session in Self.sessionsByID(in: library).values {
      try writeSession(session, to: sessionDirectoryURL)
    }

    let manifest = WorkspaceLibraryManifest(
      library: library,
      updatedAt: manifestUpdatedAt
    )
    try writeManifest(
      manifest,
      to: directoryURL.appending(path: "workspaces.json", directoryHint: .notDirectory)
    )
    return manifest
  }

  private func loadVersionedLibrary(from directoryURL: URL) throws -> LoadedWorkspaceLibrary {
    let manifestURL = directoryURL.appending(
      path: "workspaces.json",
      directoryHint: .notDirectory
    )
    let sessionDirectoryURL = directoryURL.appending(
      path: "sessions",
      directoryHint: .isDirectory
    )
    let manifestData = try readData(from: manifestURL)
    try validateVersion(
      in: manifestData,
      path: manifestURL,
      supported: WorkspaceLibraryManifest.currentVersion
    )

    let diagnostics = DecodeDiagnostics()
    let manifest: WorkspaceLibraryManifest
    do {
      manifest = try WorkspacePersistenceCoding.makeDecoder(diagnostics: diagnostics).decode(
        WorkspaceLibraryManifest.self,
        from: manifestData
      )
    } catch {
      throw WorkspacePersistenceError.decodeFailed(
        path: manifestURL.path(percentEncoded: false),
        underlying: error
      )
    }
    guard diagnostics.droppedElements.isEmpty else {
      throw WorkspacePersistenceError.invalidData(
        path: manifestURL.path(percentEncoded: false),
        reason: diagnostics.summaries.joined(separator: "; ")
      )
    }
    try Self.validate(manifest)

    var sessions: [ChatSession.ID: ChatSession] = [:]
    for persistedWorkspace in manifest.workspaces {
      for sessionID in persistedWorkspace.sessionIDs {
        let sessionURL = sessionDirectoryURL.appending(
          path: WorkspacePersistenceCoding.sessionFileName(for: sessionID),
          directoryHint: .notDirectory
        )
        let sessionData = try readData(from: sessionURL)
        try validateVersion(
          in: sessionData,
          path: sessionURL,
          supported: WorkspaceSessionDocument.currentVersion
        )
        let sessionDiagnostics = DecodeDiagnostics()
        let document: WorkspaceSessionDocument
        do {
          document = try WorkspacePersistenceCoding.makeDecoder(
            diagnostics: sessionDiagnostics
          ).decode(WorkspaceSessionDocument.self, from: sessionData)
        } catch {
          throw WorkspacePersistenceError.decodeFailed(
            path: sessionURL.path(percentEncoded: false),
            underlying: error
          )
        }
        guard sessionDiagnostics.droppedElements.isEmpty else {
          throw WorkspacePersistenceError.invalidData(
            path: sessionURL.path(percentEncoded: false),
            reason: sessionDiagnostics.summaries.joined(separator: "; ")
          )
        }
        guard document.session.id == sessionID else {
          throw WorkspacePersistenceError.invalidData(
            path: sessionURL.path(percentEncoded: false),
            reason: "Session ID does not match its manifest reference and file name."
          )
        }
        sessions[sessionID] = document.session
      }
    }

    let workspaces = try manifest.workspaces.map { persistedWorkspace in
      let workspaceSessions = try persistedWorkspace.sessionIDs.map { sessionID in
        guard let session = sessions[sessionID] else {
          throw WorkspacePersistenceError.invalidData(
            path: manifestURL.path(percentEncoded: false),
            reason: "Manifest references an unloaded session: \(sessionID.uuidString)."
          )
        }
        return session
      }
      return persistedWorkspace.workspace(sessions: workspaceSessions)
    }
    let library = WorkspaceLibrary(
      workspaces: workspaces,
      activeWorkspaceID: manifest.activeWorkspaceID,
      activeSessionID: manifest.activeSessionID
    )
    try Self.validate(library)
    return LoadedWorkspaceLibrary(library: library, manifest: manifest)
  }

  private func validateMigrationResult(
    source: WorkspaceLibrary,
    staged: WorkspaceLibrary,
    manifestUpdatedAt: Date
  ) throws {
    let sourceManifest = WorkspaceLibraryManifest(
      library: source,
      updatedAt: manifestUpdatedAt
    )
    let stagedManifest = WorkspaceLibraryManifest(
      library: staged,
      updatedAt: manifestUpdatedAt
    )
    guard
      try WorkspacePersistenceCoding.makeEncoder().encode(sourceManifest)
        == WorkspacePersistenceCoding.makeEncoder().encode(stagedManifest)
    else {
      throw WorkspacePersistenceError.invalidLegacy(
        "Versioned manifest differs from the legacy source after normalization."
      )
    }

    let sourceSessions = Self.sessionsByID(in: source)
    let stagedSessions = Self.sessionsByID(in: staged)
    guard sourceSessions.keys == stagedSessions.keys else {
      throw WorkspacePersistenceError.invalidLegacy(
        "Versioned session membership differs from the legacy source."
      )
    }
    for (sessionID, sourceSession) in sourceSessions {
      guard let stagedSession = stagedSessions[sessionID] else {
        throw WorkspacePersistenceError.invalidLegacy(
          "Versioned session is missing after validation: \(sessionID.uuidString)."
        )
      }
      let sourceData = try WorkspacePersistenceCoding.makeEncoder().encode(
        WorkspaceSessionDocument(session: sourceSession)
      )
      let stagedData = try WorkspacePersistenceCoding.makeEncoder().encode(
        WorkspaceSessionDocument(session: stagedSession)
      )
      guard sourceData == stagedData else {
        throw WorkspacePersistenceError.invalidLegacy(
          "Versioned session differs from the legacy source: \(sessionID.uuidString)."
        )
      }
    }
  }

  private func validateVersion(in data: Data, path: URL, supported: Int) throws {
    let probe: WorkspacePersistenceVersionProbe
    do {
      probe = try JSONDecoder().decode(WorkspacePersistenceVersionProbe.self, from: data)
    } catch {
      throw WorkspacePersistenceError.decodeFailed(
        path: path.path(percentEncoded: false),
        underlying: error
      )
    }
    guard probe.version == supported else {
      throw WorkspacePersistenceError.unsupportedVersion(
        path: path.path(percentEncoded: false),
        found: probe.version,
        supported: supported
      )
    }
  }

  private func readData(from url: URL) throws -> Data {
    do {
      return try Data(contentsOf: url)
    } catch {
      throw WorkspacePersistenceError.readFailed(
        path: url.path(percentEncoded: false),
        underlying: error
      )
    }
  }

  private func writeManifest(_ manifest: WorkspaceLibraryManifest, to url: URL) throws {
    let data = try WorkspacePersistenceCoding.makeEncoder().encode(manifest)
    try data.write(to: url, options: .atomic)
  }

  private func writeSession(_ session: ChatSession, to directoryURL: URL) throws {
    let url = directoryURL.appending(
      path: WorkspacePersistenceCoding.sessionFileName(for: session.id),
      directoryHint: .notDirectory
    )
    let data = try WorkspacePersistenceCoding.makeEncoder().encode(
      WorkspaceSessionDocument(session: session)
    )
    try data.write(to: url, options: .atomic)
  }

  private func removeSessionFileIfPresent(
    _ sessionID: ChatSession.ID,
    from directoryURL: URL
  ) throws {
    let url = directoryURL.appending(
      path: WorkspacePersistenceCoding.sessionFileName(for: sessionID),
      directoryHint: .notDirectory
    )
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return
    }
    try FileManager.default.removeItem(at: url)
  }

  private static func sessionsByID(
    in library: WorkspaceLibrary?
  ) -> [ChatSession.ID: ChatSession] {
    guard let library else {
      return [:]
    }
    return Dictionary(
      uniqueKeysWithValues: library.workspaces.flatMap(\.sessions).map { ($0.id, $0) }
    )
  }

  private static func validate(_ manifest: WorkspaceLibraryManifest) throws {
    var workspaceIDs = Set<Workspace.ID>()
    var sessionIDs = Set<ChatSession.ID>()
    for workspace in manifest.workspaces {
      guard workspaceIDs.insert(workspace.id).inserted else {
        throw WorkspacePersistenceError.invalidLibrary(
          "Duplicate workspace ID: \(workspace.id.uuidString)."
        )
      }
      for sessionID in workspace.sessionIDs {
        guard sessionIDs.insert(sessionID).inserted else {
          throw WorkspacePersistenceError.invalidLibrary(
            "Duplicate session ID: \(sessionID.uuidString)."
          )
        }
      }
    }
    try validateActiveSelection(
      workspaceIDs: workspaceIDs,
      activeWorkspaceID: manifest.activeWorkspaceID,
      activeSessionID: manifest.activeSessionID,
      activeWorkspaceSessionIDs: manifest.workspaces.first {
        $0.id == manifest.activeWorkspaceID
      }?.sessionIDs ?? []
    )
  }

  private static func validate(_ library: WorkspaceLibrary) throws {
    var workspaceIDs = Set<Workspace.ID>()
    var sessionIDs = Set<ChatSession.ID>()
    for workspace in library.workspaces {
      guard workspaceIDs.insert(workspace.id).inserted else {
        throw WorkspacePersistenceError.invalidLibrary(
          "Duplicate workspace ID: \(workspace.id.uuidString)."
        )
      }
      for session in workspace.sessions {
        guard sessionIDs.insert(session.id).inserted else {
          throw WorkspacePersistenceError.invalidLibrary(
            "Duplicate session ID: \(session.id.uuidString)."
          )
        }
      }
    }
    try validateActiveSelection(
      workspaceIDs: workspaceIDs,
      activeWorkspaceID: library.activeWorkspaceID,
      activeSessionID: library.activeSessionID,
      activeWorkspaceSessionIDs: library.workspaces.first {
        $0.id == library.activeWorkspaceID
      }?.sessions.map(\.id) ?? []
    )
  }

  private static func validateActiveSelection(
    workspaceIDs: Set<Workspace.ID>,
    activeWorkspaceID: Workspace.ID?,
    activeSessionID: ChatSession.ID?,
    activeWorkspaceSessionIDs: [ChatSession.ID]
  ) throws {
    if let activeWorkspaceID, !workspaceIDs.contains(activeWorkspaceID) {
      throw WorkspacePersistenceError.invalidLibrary(
        "Active workspace ID does not reference a persisted workspace."
      )
    }
    if let activeSessionID {
      guard activeWorkspaceID != nil else {
        throw WorkspacePersistenceError.invalidLibrary(
          "An active session requires an active workspace."
        )
      }
      guard activeWorkspaceSessionIDs.contains(activeSessionID) else {
        throw WorkspacePersistenceError.invalidLibrary(
          "Active session ID does not belong to the active workspace."
        )
      }
    }
  }

  private func loadIssue(for error: Error) -> WorkspaceLibraryLoadIssue {
    switch error {
    case WorkspacePersistenceError.unsupportedVersion(let path, let found, let supported):
      .unsupportedVersion(path: path, found: found, supported: supported)
    case WorkspacePersistenceError.invalidLegacy(let message):
      .migrationFailed(message: message)
    case WorkspacePersistenceError.readFailed(let path, let underlying):
      .readFailed(message: "\(path): \(String(reflecting: underlying))")
    case WorkspacePersistenceError.decodeFailed(let path, let underlying):
      .decodeFailed(message: "\(path): \(String(reflecting: underlying))")
    case WorkspacePersistenceError.invalidData(let path, let reason):
      .decodeFailed(message: "\(path): \(reason)")
    case WorkspacePersistenceError.invalidLibrary(let reason):
      .decodeFailed(message: reason)
    case WorkspacePersistenceError.persistenceBlocked:
      .readFailed(message: WorkspacePersistenceError.persistenceBlocked.localizedDescription)
    default:
      .decodeFailed(message: String(reflecting: error))
    }
  }

  private static func makeLegacyDecoder(diagnostics: DecodeDiagnostics) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[.decodeDiagnostics] = diagnostics
    return decoder
  }

  #if canImport(OSLog)
    nonisolated private static let logger = Logger(
      subsystem: SumikaTelemetry.subsystem,
      category: "WorkspaceStore"
    )
  #endif

  nonisolated private func logIssue(_ message: String) {
    #if canImport(OSLog)
      Self.logger.error("\(message, privacy: .public)")
    #else
      FileHandle.standardError.write(Data((message + "\n").utf8))
    #endif
  }
}

private struct LoadedWorkspaceLibrary {
  let library: WorkspaceLibrary
  let manifest: WorkspaceLibraryManifest
}

private enum WorkspacePersistenceError: LocalizedError {
  case persistenceBlocked
  case readFailed(path: String, underlying: Error)
  case decodeFailed(path: String, underlying: Error)
  case invalidData(path: String, reason: String)
  case invalidLegacy(String)
  case invalidLibrary(String)
  case unsupportedVersion(path: String, found: Int, supported: Int)

  var errorDescription: String? {
    switch self {
    case .persistenceBlocked:
      "Workspace persistence is blocked because stored data could not be loaded safely."
    case .readFailed(let path, let underlying):
      "Could not read \(path): \(underlying.localizedDescription)"
    case .decodeFailed(let path, let underlying):
      "Could not decode \(path): \(underlying.localizedDescription)"
    case .invalidData(let path, let reason):
      "Invalid workspace data at \(path): \(reason)"
    case .invalidLegacy(let message), .invalidLibrary(let message):
      message
    case .unsupportedVersion(let path, let found, let supported):
      "Unsupported workspace format at \(path): found \(found), supported \(supported)."
    }
  }
}

extension WorkspaceLibraryLoadIssue {
  fileprivate var logMessage: String {
    switch self {
    case .readFailed(let message),
      .decodeFailed(let message),
      .migrationFailed(let message),
      .legacyCleanupFailed(let message):
      message
    case .unsupportedVersion(let path, let found, let supported):
      "Unsupported workspace format at \(path): found=\(found) supported=\(supported)"
    }
  }
}
