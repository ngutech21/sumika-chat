import Foundation

package struct FocusedFileState: Codable, Equatable, Sendable {
  package var activePath: WorkspaceRelativePath?
  package var recentPaths: [FocusedPath]
  package var snapshots: [WorkspaceRelativePath: FocusedFileSnapshot]

  package init(
    activePath: WorkspaceRelativePath? = nil,
    recentPaths: [FocusedPath] = [],
    snapshots: [WorkspaceRelativePath: FocusedFileSnapshot] = [:]
  ) {
    self.activePath = activePath
    self.recentPaths = recentPaths
    self.snapshots = snapshots
  }

  package static let empty = FocusedFileState()

  private enum CodingKeys: String, CodingKey {
    case activePath
    case recentPaths
    case snapshots
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activePath = try container.decodeIfPresent(WorkspaceRelativePath.self, forKey: .activePath)
    recentPaths = try container.decodeLossyArray([FocusedPath].self, forKey: .recentPaths)
    snapshots = try container.decodeIfPresent(
      [WorkspaceRelativePath: FocusedFileSnapshot].self,
      forKey: .snapshots,
      default: [:]
    )
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(activePath, forKey: .activePath)
    try container.encode(recentPaths, forKey: .recentPaths)
    try container.encode(snapshots, forKey: .snapshots)
  }
}

package struct FocusedPath: Codable, Equatable, Sendable {
  package var path: WorkspaceRelativePath
  package var source: FocusedPathSource
  package var confidence: FocusConfidence
  package var updatedAt: Date

  package init(
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

package enum FocusedPathSource: String, Codable, Equatable, Sendable {
  case readFile
  case writeFile
  case editFile
  case attachment
}

package enum FocusConfidence: String, Codable, Equatable, Sendable {
  case active
  case recent
  case ambiguous
}

package struct FocusedFileSnapshot: Codable, Equatable, Sendable {
  package var contentHash: String
  package var excerpt: String?
  package var fullContentAvailable: Bool
  package var updatedAt: Date

  package init(
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
