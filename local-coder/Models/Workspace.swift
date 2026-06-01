import Foundation

struct CodingSession: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var title: String
  var selectedModelID: ManagedModel.ID
  var messages: [ChatMessage]
  var systemPrompt: String
  var generationSettings: ChatGenerationSettings
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    title: String = "New Session",
    selectedModelID: ManagedModel.ID,
    messages: [ChatMessage] = [],
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.selectedModelID = selectedModelID
    self.messages = messages
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.createdAt = createdAt
    self.updatedAt = updatedAt
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
    url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
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
