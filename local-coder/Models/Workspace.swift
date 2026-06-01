import Foundation

struct CodingSession: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var title: String
  var selectedModelID: ManagedModel.ID
  var messages: [ChatMessage]
  var toolCalls: [ToolCallRecord]
  var systemPrompt: String
  var generationSettings: ChatGenerationSettings
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    title: String = "New Session",
    selectedModelID: ManagedModel.ID,
    messages: [ChatMessage] = [],
    toolCalls: [ToolCallRecord] = [],
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.selectedModelID = selectedModelID
    self.messages = messages
    self.toolCalls = toolCalls
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case selectedModelID
    case messages
    case toolCalls
    case systemPrompt
    case generationSettings
    case createdAt
    case updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    selectedModelID = try container.decode(ManagedModel.ID.self, forKey: .selectedModelID)
    messages = try container.decode([ChatMessage].self, forKey: .messages)
    toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    generationSettings = try container.decode(
      ChatGenerationSettings.self, forKey: .generationSettings)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }
}

struct Workspace: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var rootURL: URL
  var bookmarkData: Data?
  var sessions: [CodingSession]
  var createdAt: Date
  var updatedAt: Date

  init(
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

  var normalizedRootPath: String {
    Self.normalizedPath(for: rootURL)
  }

  static func normalizedPath(for url: URL) -> String {
    normalizedPathString(for: url.standardizedFileURL.resolvingSymlinksInPath())
  }

  /// Tool executors must call this again directly before file IO.
  func resolveAllowedPath(_ input: String) throws -> URL {
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

  private static func normalizedPathString(for url: URL) -> String {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }
}

enum WorkspacePathResolutionError: LocalizedError, Equatable {
  case emptyPath
  case unsupportedURLScheme(String)
  case pathOutsideWorkspace

  var errorDescription: String? {
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

struct WorkspaceLibrary: Codable, Equatable, Sendable {
  var workspaces: [Workspace]
  var activeWorkspaceID: Workspace.ID?
  var activeSessionID: CodingSession.ID?

  init(
    workspaces: [Workspace] = [],
    activeWorkspaceID: Workspace.ID? = nil,
    activeSessionID: CodingSession.ID? = nil
  ) {
    self.workspaces = workspaces
    self.activeWorkspaceID = activeWorkspaceID
    self.activeSessionID = activeSessionID
  }
}
