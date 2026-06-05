import Foundation

public struct FocusedFileState: Codable, Equatable, Sendable {
  public var activePath: WorkspaceRelativePath?
  public var recentPaths: [FocusedPath]
  public var snapshots: [WorkspaceRelativePath: FocusedFileSnapshot]

  public init(
    activePath: WorkspaceRelativePath? = nil,
    recentPaths: [FocusedPath] = [],
    snapshots: [WorkspaceRelativePath: FocusedFileSnapshot] = [:]
  ) {
    self.activePath = activePath
    self.recentPaths = recentPaths
    self.snapshots = snapshots
  }

  public static let empty = FocusedFileState()
}

public struct FocusedPath: Codable, Equatable, Sendable {
  public var path: WorkspaceRelativePath
  public var source: FocusedPathSource
  public var confidence: FocusConfidence
  public var updatedAt: Date

  public init(
    path: WorkspaceRelativePath,
    source: FocusedPathSource,
    confidence: FocusConfidence,
    updatedAt: Date = Date()
  ) {
    self.path = path
    self.source = source
    self.confidence = confidence
    self.updatedAt = updatedAt
  }
}

public enum FocusedPathSource: String, Codable, Equatable, Sendable {
  case readFile
  case writeFile
  case editFile
  case attachment
}

public enum FocusConfidence: String, Codable, Equatable, Sendable {
  case active
  case recent
  case ambiguous
}

public struct FocusedFileSnapshot: Codable, Equatable, Sendable {
  public var contentHash: String
  public var excerpt: String?
  public var fullContentAvailable: Bool
  public var updatedAt: Date

  public init(
    contentHash: String,
    excerpt: String?,
    fullContentAvailable: Bool,
    updatedAt: Date = Date()
  ) {
    self.contentHash = contentHash
    self.excerpt = excerpt
    self.fullContentAvailable = fullContentAvailable
    self.updatedAt = updatedAt
  }
}
