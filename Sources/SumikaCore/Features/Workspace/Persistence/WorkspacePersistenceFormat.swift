import Foundation

struct WorkspaceLibraryManifest: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  var updatedAt: Date
  var activeWorkspaceID: Workspace.ID?
  var activeSessionID: ChatSession.ID?
  var workspaces: [PersistedWorkspace]

  init(
    version: Int = currentVersion,
    updatedAt: Date,
    activeWorkspaceID: Workspace.ID?,
    activeSessionID: ChatSession.ID?,
    workspaces: [PersistedWorkspace]
  ) {
    self.version = version
    self.updatedAt = updatedAt
    self.activeWorkspaceID = activeWorkspaceID
    self.activeSessionID = activeSessionID
    self.workspaces = workspaces
  }

  init(library: WorkspaceLibrary, updatedAt: Date) {
    self.init(
      updatedAt: updatedAt,
      activeWorkspaceID: library.activeWorkspaceID,
      activeSessionID: library.activeSessionID,
      workspaces: library.workspaces.map(PersistedWorkspace.init)
    )
  }

  func hasSameLogicalContent(as other: WorkspaceLibraryManifest) -> Bool {
    activeWorkspaceID == other.activeWorkspaceID
      && activeSessionID == other.activeSessionID
      && workspaces == other.workspaces
  }
}

struct PersistedWorkspace: Codable, Equatable, Sendable {
  let id: Workspace.ID
  var name: String
  var rootURL: URL
  var bookmarkData: Data?
  var sessionIDs: [ChatSession.ID]
  var createdAt: Date
  var updatedAt: Date

  init(workspace: Workspace) {
    self.id = workspace.id
    self.name = workspace.name
    self.rootURL = workspace.rootURL
    self.bookmarkData = workspace.bookmarkData
    self.sessionIDs = workspace.sessions.map(\.id)
    self.createdAt = workspace.createdAt
    self.updatedAt = workspace.updatedAt
  }

  func workspace(sessions: [ChatSession]) -> Workspace {
    Workspace(
      id: id,
      name: name,
      rootURL: rootURL,
      bookmarkData: bookmarkData,
      sessions: sessions,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

struct WorkspaceSessionDocument: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let session: ChatSession

  init(version: Int = currentVersion, session: ChatSession) {
    self.version = version
    self.session = session
  }
}

struct WorkspacePersistenceVersionProbe: Decodable {
  let version: Int
}

enum WorkspacePersistenceCoding {
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(makeDateFormatter())
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  static func makeDecoder(diagnostics: DecodeDiagnostics = DecodeDiagnostics()) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .formatted(makeDateFormatter())
    decoder.userInfo[.decodeDiagnostics] = diagnostics
    return decoder
  }

  static func sessionFileName(for sessionID: ChatSession.ID) -> String {
    "\(sessionID.uuidString.lowercased()).json"
  }

  static func normalizedToMilliseconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
  }

  private static func makeDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
  }
}
