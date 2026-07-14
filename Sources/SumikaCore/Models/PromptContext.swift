public struct ContextBudget: Codable, Equatable, Sendable {
  public let maxCharacters: Int

  private init(maxCharacters: Int) {
    self.maxCharacters = maxCharacters
  }

  public static let focusedFileDefault = ContextBudget(maxCharacters: 4_000)
  public static let workspaceInstructionsDefault = ContextBudget(maxCharacters: 8_000)

  public static func checked(maxCharacters: Int) -> ContextBudget? {
    guard maxCharacters > 0 else {
      return nil
    }
    return ContextBudget(maxCharacters: maxCharacters)
  }

  static func unsafe(maxCharacters: Int) -> ContextBudget {
    ContextBudget(maxCharacters: maxCharacters)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let maxCharacters = try container.decode(Int.self)
    guard maxCharacters > 0 else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "ContextBudget.maxCharacters must be greater than zero."
      )
    }
    self.init(maxCharacters: maxCharacters)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(maxCharacters)
  }
}

public struct PromptContextExcerpt: Codable, Equatable, Sendable {
  public let text: String
  public let truncated: Bool

  private init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }

  static func make(text: String, truncated: Bool) -> PromptContextExcerpt {
    PromptContextExcerpt(text: text, truncated: truncated)
  }
}

public enum PromptContextTruncation: String, Codable, Equatable, Sendable {
  case none
  case byCharacterBudget
}

public enum WorkspaceInstructionsPromptContext: Codable, Equatable, Sendable {
  case snapshot(WorkspaceInstructionsSnapshot)
  case removed(WorkspaceInstructionsRemoval)

  private enum CodingKeys: String, CodingKey {
    case kind
    case snapshot
    case removed
  }

  private enum Kind: String, Codable {
    case snapshot
    case removed
  }

  public var path: WorkspaceRelativePath {
    switch self {
    case .snapshot(let snapshot):
      snapshot.path
    case .removed(let removal):
      removal.path
    }
  }

  public var snapshot: WorkspaceInstructionsSnapshot? {
    guard case .snapshot(let snapshot) = self else {
      return nil
    }
    return snapshot
  }

  public static func makeSnapshot(
    path: WorkspaceRelativePath,
    contentHash: String,
    content: String,
    budget: ContextBudget = .workspaceInstructionsDefault
  ) -> WorkspaceInstructionsPromptContext? {
    guard !contentHash.isEmpty else {
      return nil
    }
    let truncated = content.count > budget.maxCharacters
    return .snapshot(
      WorkspaceInstructionsSnapshot(
        path: path,
        contentHash: contentHash,
        excerpt: .make(
          text: truncated ? String(content.prefix(budget.maxCharacters)) : content,
          truncated: truncated
        ),
        budget: budget,
        truncation: truncated ? .byCharacterBudget : .none
      )
    )
  }

  public static func makeRemoval(
    path: WorkspaceRelativePath
  ) -> WorkspaceInstructionsPromptContext {
    .removed(WorkspaceInstructionsRemoval(path: path))
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .snapshot:
      self = .snapshot(
        try container.decode(WorkspaceInstructionsSnapshot.self, forKey: .snapshot)
      )
    case .removed:
      self = .removed(
        try container.decode(WorkspaceInstructionsRemoval.self, forKey: .removed)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .snapshot(let snapshot):
      try container.encode(Kind.snapshot, forKey: .kind)
      try container.encode(snapshot, forKey: .snapshot)
    case .removed(let removal):
      try container.encode(Kind.removed, forKey: .kind)
      try container.encode(removal, forKey: .removed)
    }
  }
}

public struct WorkspaceInstructionsSnapshot: Codable, Equatable, Sendable {
  public let path: WorkspaceRelativePath
  public let contentHash: String
  public let excerpt: PromptContextExcerpt
  public let budget: ContextBudget
  public let truncation: PromptContextTruncation

  fileprivate init(
    path: WorkspaceRelativePath,
    contentHash: String,
    excerpt: PromptContextExcerpt,
    budget: ContextBudget,
    truncation: PromptContextTruncation
  ) {
    self.path = path
    self.contentHash = contentHash
    self.excerpt = excerpt
    self.budget = budget
    self.truncation = truncation
  }

  private enum CodingKeys: String, CodingKey {
    case path
    case contentHash
    case excerpt
    case budget
    case truncation
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let path = try container.decode(WorkspaceRelativePath.self, forKey: .path)
    let contentHash = try container.decode(String.self, forKey: .contentHash)
    let excerpt = try container.decode(PromptContextExcerpt.self, forKey: .excerpt)
    let budget = try container.decode(ContextBudget.self, forKey: .budget)
    let truncation = try container.decode(PromptContextTruncation.self, forKey: .truncation)
    let isTruncated = truncation == .byCharacterBudget
    guard !contentHash.isEmpty,
      excerpt.truncated == isTruncated,
      excerpt.text.count <= budget.maxCharacters,
      !isTruncated || excerpt.text.count == budget.maxCharacters
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .excerpt,
        in: container,
        debugDescription: "Workspace instructions excerpt and truncation metadata must agree."
      )
    }
    self.init(
      path: path,
      contentHash: contentHash,
      excerpt: excerpt,
      budget: budget,
      truncation: truncation
    )
  }
}

public struct WorkspaceInstructionsRemoval: Codable, Equatable, Sendable {
  public let path: WorkspaceRelativePath

  fileprivate init(path: WorkspaceRelativePath) {
    self.path = path
  }
}
