import Foundation

/// The monolithic import must not accept new session/tool variants through current Codable types.
struct WorkspaceLibraryV0: Decodable {
  private let workspaces: [WorkspaceV0]
  private let activeWorkspaceID: UUID?
  private let activeSessionID: UUID?

  private enum CodingKeys: String, CodingKey {
    case workspaces, activeWorkspaceID, activeSessionID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workspaces = try container.decodeLossyArray([WorkspaceV0].self, forKey: .workspaces)
    activeWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
    activeSessionID = try container.decodeIfPresent(UUID.self, forKey: .activeSessionID)
  }

  var value: WorkspaceLibrary {
    WorkspaceLibrary(
      workspaces: workspaces.map(\.value), activeWorkspaceID: activeWorkspaceID,
      activeSessionID: activeSessionID)
  }
}

private struct WorkspaceV0: Decodable {
  let id: UUID
  let name: String
  let rootURL: URL
  let bookmarkData: Data?
  let sessions: [WorkspaceSessionV1]
  let createdAt: Date
  let updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, name, rootURL, bookmarkData, sessions, createdAt, updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rootURL = try container.decode(URL.self, forKey: .rootURL)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    name = try container.decodeIfPresent(
      String.self, forKey: .name, default: rootURL.lastPathComponent)
    bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
    sessions = try container.decodeLossyArray([WorkspaceSessionV1].self, forKey: .sessions)
    createdAt = try container.decodeIfPresent(
      Date.self, forKey: .createdAt, default: decoder.defaultDate)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt, default: createdAt)
  }

  var value: Workspace {
    Workspace(
      id: id, name: name, rootURL: rootURL, bookmarkData: bookmarkData,
      sessions: sessions.map(\.value), createdAt: createdAt, updatedAt: updatedAt)
  }
}
