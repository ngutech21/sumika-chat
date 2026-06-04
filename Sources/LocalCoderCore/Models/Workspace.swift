import Foundation

public struct CodingSession: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var selectedModelID: ManagedModel.ID
  public var messages: [ChatMessage]
  public var modelContextMessages: [ChatModelContextMessage]
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurnRecord]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String = "New Session",
    selectedModelID: ManagedModel.ID,
    messages: [ChatMessage] = [],
    modelContextMessages: [ChatModelContextMessage] = [],
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurnRecord] = [],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode = .chat,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.selectedModelID = selectedModelID
    self.messages = messages
    self.modelContextMessages = modelContextMessages
    self.toolCalls = toolCalls
    self.turns = turns
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case selectedModelID
    case messages
    case modelContextMessages
    case toolCalls
    case turns
    case focusedFileState
    case systemPrompt
    case generationSettings
    case interactionMode
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    selectedModelID = try container.decode(ManagedModel.ID.self, forKey: .selectedModelID)
    messages = try container.decode([ChatMessage].self, forKey: .messages)
    modelContextMessages =
      try container.decodeIfPresent([ChatModelContextMessage].self, forKey: .modelContextMessages)
      ?? ChatModelContextBackfill.messages(from: messages)
    toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
    turns = try container.decodeIfPresent([ChatTurnRecord].self, forKey: .turns) ?? []
    focusedFileState =
      try container.decodeIfPresent(FocusedFileState.self, forKey: .focusedFileState) ?? .empty
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    generationSettings = try container.decode(
      ChatGenerationSettings.self, forKey: .generationSettings)
    interactionMode =
      try container.decodeIfPresent(WorkspaceInteractionMode.self, forKey: .interactionMode)
      ?? .chat
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }
}

public struct Workspace: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var rootURL: URL
  public var bookmarkData: Data?
  public var sessions: [CodingSession]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    rootURL: URL,
    bookmarkData: Data? = nil,
    sessions: [CodingSession] = [],
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

  public var normalizedRootPath: String {
    Self.normalizedPath(for: rootURL)
  }

  public static func normalizedPath(for url: URL) -> String {
    normalizedPathString(for: url.standardizedFileURL.resolvingSymlinksInPath())
  }

  /// Tool executors must call this again directly before file IO.
  public func resolveAllowedPath(_ input: String) throws -> URL {
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

  public func relativePath(for resolvedURL: URL) -> WorkspaceRelativePath {
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

  public func withSecurityScopedAccess<Result>(_ body: () throws -> Result) rethrows -> Result {
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

public enum WorkspacePathResolutionError: LocalizedError, Equatable {
  case emptyPath
  case unsupportedURLScheme(String)
  case pathOutsideWorkspace

  public var errorDescription: String? {
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

public struct WorkspaceLibrary: Codable, Equatable, Sendable {
  public var workspaces: [Workspace]
  public var activeWorkspaceID: Workspace.ID?
  public var activeSessionID: CodingSession.ID?

  public init(
    workspaces: [Workspace] = [],
    activeWorkspaceID: Workspace.ID? = nil,
    activeSessionID: CodingSession.ID? = nil
  ) {
    self.workspaces = workspaces
    self.activeWorkspaceID = activeWorkspaceID
    self.activeSessionID = activeSessionID
  }
}
