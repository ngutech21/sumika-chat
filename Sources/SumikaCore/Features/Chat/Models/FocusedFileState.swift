import Foundation

public struct FocusedFileState: Codable, Equatable, Sendable {
  public var activePath: WorkspaceRelativePath?
  public var recentPaths: [FocusedPath]
  public var snapshots: [WorkspaceRelativePath: FocusedFileSnapshot]
  public var focusedAttachments: [AttachmentID]

  public init(
    activePath: WorkspaceRelativePath? = nil,
    recentPaths: [FocusedPath] = [],
    snapshots: [WorkspaceRelativePath: FocusedFileSnapshot] = [:],
    focusedAttachments: [AttachmentID] = []
  ) {
    self.activePath = activePath
    self.recentPaths = recentPaths
    self.snapshots = snapshots
    self.focusedAttachments = focusedAttachments
  }

  public static let empty = FocusedFileState()

  private enum CodingKeys: String, CodingKey {
    case activePath
    case recentPaths
    case snapshots
    case focusedAttachments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activePath = try container.decodeIfPresent(WorkspaceRelativePath.self, forKey: .activePath)
    recentPaths = try container.decodeLossyArray([FocusedPath].self, forKey: .recentPaths)
    snapshots = try container.decodeIfPresent(
      [WorkspaceRelativePath: FocusedFileSnapshot].self,
      forKey: .snapshots,
      default: [:]
    )
    focusedAttachments = try container.decodeIfPresent(
      [AttachmentID].self,
      forKey: .focusedAttachments,
      default: []
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(activePath, forKey: .activePath)
    try container.encode(recentPaths, forKey: .recentPaths)
    try container.encode(snapshots, forKey: .snapshots)
    try container.encode(focusedAttachments, forKey: .focusedAttachments)
  }
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
