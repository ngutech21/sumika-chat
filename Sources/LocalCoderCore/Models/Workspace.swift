import Foundation

public struct ChatSession: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var selectedModelID: ManagedModel.ID
  public var modelContextSnapshot: ModelContextSnapshot
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurn]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode
  public var pendingAttachments: [ChatAttachment]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String = "New Session",
    selectedModelID: ManagedModel.ID = ManagedModelCatalog.defaultModelID,
    modelContextSnapshot: ModelContextSnapshot = ModelContextSnapshot(),
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurn] = [],
    pendingAttachments: [ChatAttachment] = [],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String = ChatPromptDefaults.codingSystemPrompt,
    generationSettings: ChatGenerationSettings = .codingDefault,
    interactionMode: WorkspaceInteractionMode = .chat,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.selectedModelID = selectedModelID
    self.modelContextSnapshot = modelContextSnapshot
    self.toolCalls = toolCalls
    self.turns = turns
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
    self.pendingAttachments = pendingAttachments
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let codingDefault = ChatSession()

  public static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
    lhs.id == rhs.id
      && lhs.title == rhs.title
      && lhs.selectedModelID == rhs.selectedModelID
      && lhs.modelContextSnapshot == rhs.modelContextSnapshot
      && lhs.toolCalls == rhs.toolCalls
      && lhs.turns == rhs.turns
      && lhs.focusedFileState == rhs.focusedFileState
      && lhs.systemPrompt == rhs.systemPrompt
      && lhs.generationSettings == rhs.generationSettings
      && lhs.interactionMode == rhs.interactionMode
      && lhs.createdAt == rhs.createdAt
      && lhs.updatedAt == rhs.updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case selectedModelID
    case modelContextSnapshot
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
    modelContextSnapshot = try container.decode(
      ModelContextSnapshot.self,
      forKey: .modelContextSnapshot
    )
    toolCalls = try container.decode([ToolCallRecord].self, forKey: .toolCalls)
    turns = try container.decode([ChatTurn].self, forKey: .turns)
    focusedFileState = try container.decode(FocusedFileState.self, forKey: .focusedFileState)
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    generationSettings = try container.decode(
      ChatGenerationSettings.self,
      forKey: .generationSettings
    )
    interactionMode = try container.decode(
      WorkspaceInteractionMode.self,
      forKey: .interactionMode
    )
    pendingAttachments = []
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(selectedModelID, forKey: .selectedModelID)
    try container.encode(modelContextSnapshot, forKey: .modelContextSnapshot)
    try container.encode(toolCalls, forKey: .toolCalls)
    try container.encode(turns, forKey: .turns)
    try container.encode(focusedFileState, forKey: .focusedFileState)
    try container.encode(systemPrompt, forKey: .systemPrompt)
    try container.encode(generationSettings, forKey: .generationSettings)
    try container.encode(interactionMode, forKey: .interactionMode)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  public func turnID(containingToolCall toolCallID: ToolCallRecord.ID) -> ChatTurn.ID? {
    turns.first { turn in
      turn.items.contains { item in
        switch item {
        case .toolCall(let id), .toolResult(let id):
          id == toolCallID
        case .userMessage, .assistantMessage:
          false
        }
      }
    }?.id
  }
}

public struct Workspace: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var rootURL: URL
  public var bookmarkData: Data?
  public var sessions: [ChatSession]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
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
  public var activeSessionID: ChatSession.ID?

  public init(
    workspaces: [Workspace] = [],
    activeWorkspaceID: Workspace.ID? = nil,
    activeSessionID: ChatSession.ID? = nil
  ) {
    self.workspaces = workspaces
    self.activeWorkspaceID = activeWorkspaceID
    self.activeSessionID = activeSessionID
  }
}
