import Foundation

package struct Workspace: Codable, Identifiable, Equatable, Sendable {
  package let id: UUID
  package var name: String
  package var rootURL: URL
  package var bookmarkData: Data?
  package var sessions: [ChatSession]
  package var createdAt: Date
  package var updatedAt: Date

  package init(
    id: UUID = UUID(),
    name: String,
    rootURL: URL,
    bookmarkData: Data? = nil,
    sessions: [ChatSession] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.rootURL = rootURL
    self.bookmarkData = bookmarkData
    self.sessions = sessions
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case rootURL
    case bookmarkData
    case sessions
    case createdAt
    case updatedAt
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedRootURL = try container.decode(URL.self, forKey: .rootURL)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    name = try container.decodeIfPresent(
      String.self,
      forKey: .name,
      default: decodedRootURL.lastPathComponent
    )
    rootURL = decodedRootURL
    bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
    sessions = try container.decodeLossyArray([ChatSession].self, forKey: .sessions)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt, default: Date())
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt, default: createdAt)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(rootURL, forKey: .rootURL)
    try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
    try container.encode(sessions, forKey: .sessions)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  package var normalizedRootPath: String {
    Self.normalizedPath(for: rootURL)
  }

  package static func normalizedPath(for url: URL) -> String {
    normalizedPathString(for: url.standardizedFileURL.resolvingSymlinksInPath())
  }

  /// Tool executors must call this again directly before file IO.
  package func resolveAllowedPath(_ input: String) throws -> URL {
    let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInput.isEmpty else {
      throw WorkspacePathResolutionError.emptyPath
    }

    let candidateURL: URL
    if let url = URL(string: trimmedInput), let scheme = url.scheme {
      guard scheme == "file" else {
        throw WorkspacePathResolutionError.unsupportedURLScheme(scheme)
      }
      candidateURL = url
    } else if trimmedInput.hasPrefix("/") {
      candidateURL = URL(filePath: trimmedInput)
    } else {
      candidateURL = rootURL.appending(path: trimmedInput)
    }

    if candidateURL.pathComponents.contains("..") {
      throw WorkspacePathResolutionError.pathOutsideWorkspace
    }

    let resolvedRootURL = Self.resolveSymlinksPreservingMissingPath(for: rootURL)
    let resolvedCandidateURL = Self.resolveSymlinksPreservingMissingPath(for: candidateURL)
    let rootPath = Self.normalizedPathString(for: resolvedRootURL)
    let candidatePath = Self.normalizedPathString(for: resolvedCandidateURL)

    guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
      throw WorkspacePathResolutionError.pathOutsideWorkspace
    }

    return URL(filePath: candidatePath)
  }

  package func relativePath(for resolvedURL: URL) -> WorkspaceRelativePath {
    let rootPath = Self.normalizedPath(for: rootURL)
    let candidatePath = Self.normalizedPath(for: resolvedURL)
    if candidatePath == rootPath {
      return WorkspaceRelativePath(rawValue: ".")
    }
    if candidatePath.hasPrefix(rootPath + "/") {
      return WorkspaceRelativePath(rawValue: String(candidatePath.dropFirst(rootPath.count + 1)))
    }
    return WorkspaceRelativePath(rawValue: candidatePath)
  }

  package func withSecurityScopedAccess<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(Darwin)
      let accessURL = securityScopedAccessURL()
      let didStartSecurityScope = accessURL.startAccessingSecurityScopedResource()
      defer {
        if didStartSecurityScope {
          accessURL.stopAccessingSecurityScopedResource()
        }
      }

      return try body()
    #else
      return try body()
    #endif
  }

  package func withAsyncSecurityScopedAccess<Result>(
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    #if canImport(Darwin)
      let accessURL = securityScopedAccessURL()
      let didStartSecurityScope = accessURL.startAccessingSecurityScopedResource()
      defer {
        if didStartSecurityScope {
          accessURL.stopAccessingSecurityScopedResource()
        }
      }

      return try await body()
    #else
      return try await body()
    #endif
  }

  private static func resolveSymlinksPreservingMissingPath(for url: URL) -> URL {
    let fileManager = FileManager.default
    var existingURL = url.standardizedFileURL
    var missingComponents: [String] = []

    while !fileManager.fileExists(atPath: existingURL.path(percentEncoded: false)) {
      let lastComponent = existingURL.lastPathComponent
      let parentURL = existingURL.deletingLastPathComponent()
      guard parentURL != existingURL, !lastComponent.isEmpty else {
        break
      }

      missingComponents.insert(lastComponent, at: 0)
      existingURL = parentURL
    }

    var resolvedURL = existingURL.resolvingSymlinksInPath()
    for component in missingComponents {
      resolvedURL.append(path: component)
    }

    return resolvedURL.standardizedFileURL
  }

  private func securityScopedAccessURL() -> URL {
    #if canImport(Darwin)
      guard let bookmarkData else {
        return rootURL
      }

      do {
        var isStale = false
        return try URL(
          resolvingBookmarkData: bookmarkData,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
        )
      } catch {
        return rootURL
      }
    #else
      return rootURL
    #endif
  }

  private static func normalizedPathString(for url: URL) -> String {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }
}

package enum WorkspacePathResolutionError: LocalizedError, Equatable {
  case emptyPath
  case unsupportedURLScheme(String)
  case pathOutsideWorkspace

  package var errorDescription: String? {
    switch self {
    case .emptyPath:
      "Path is empty."
    case .unsupportedURLScheme(let scheme):
      "Unsupported URL scheme: \(scheme)."
    case .pathOutsideWorkspace:
      "Path is outside the workspace."
    }
  }
}

package struct WorkspaceLibrary: Codable, Equatable, Sendable {
  package var workspaces: [Workspace]
  package var activeWorkspaceID: Workspace.ID?
  package var activeSessionID: ChatSession.ID?

  package init(
    workspaces: [Workspace] = [],
    activeWorkspaceID: Workspace.ID? = nil,
    activeSessionID: ChatSession.ID? = nil
  ) {
    self.workspaces = workspaces
    self.activeWorkspaceID = activeWorkspaceID
    self.activeSessionID = activeSessionID
  }

  private enum CodingKeys: String, CodingKey {
    case workspaces
    case activeWorkspaceID
    case activeSessionID
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workspaces = try container.decodeLossyArray([Workspace].self, forKey: .workspaces)
    activeWorkspaceID = try container.decodeIfPresent(Workspace.ID.self, forKey: .activeWorkspaceID)
    activeSessionID = try container.decodeIfPresent(ChatSession.ID.self, forKey: .activeSessionID)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(workspaces, forKey: .workspaces)
    try container.encodeIfPresent(activeWorkspaceID, forKey: .activeWorkspaceID)
    try container.encodeIfPresent(activeSessionID, forKey: .activeSessionID)
  }
}
