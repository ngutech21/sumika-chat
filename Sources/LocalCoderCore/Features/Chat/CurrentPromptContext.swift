import Foundation

public enum CurrentPromptContext: Equatable, Sendable {
  case empty(ContextBudget)
  case selected(CurrentPromptContextSelection)
}

public struct CurrentPromptContextSelection: Equatable, Sendable {
  public let blocks: NonEmptyPromptContextBlocks
  public let budget: ContextBudget
  public let truncation: PromptContextTruncation

  private init(
    blocks: NonEmptyPromptContextBlocks,
    budget: ContextBudget,
    truncation: PromptContextTruncation
  ) {
    self.blocks = blocks
    self.budget = budget
    self.truncation = truncation
  }

  fileprivate static func make(
    blocks: NonEmptyPromptContextBlocks,
    budget: ContextBudget,
    truncation: PromptContextTruncation
  ) -> CurrentPromptContextSelection {
    CurrentPromptContextSelection(
      blocks: blocks,
      budget: budget,
      truncation: truncation
    )
  }
}

public struct NonEmptyPromptContextBlocks: Equatable, Sendable {
  private let storage: [PromptContextBlock]

  public var values: [PromptContextBlock] {
    storage
  }

  private init(_ storage: [PromptContextBlock]) {
    self.storage = storage
  }

  fileprivate static func make(_ values: [PromptContextBlock]) -> NonEmptyPromptContextBlocks? {
    guard !values.isEmpty else {
      return nil
    }
    return NonEmptyPromptContextBlocks(values)
  }
}

public enum PromptContextBlock: Equatable, Sendable {
  case focusedFile(FocusedFilePromptContext)
  case ambiguousRecentFiles(AmbiguousRecentFilesPromptContext)
}

public struct FocusedFilePromptContext: Equatable, Sendable {
  public let path: WorkspaceRelativePath
  public let source: FocusedPathSource?
  public let contentHash: String?
  public let excerpt: PromptContextExcerpt?

  private init(
    path: WorkspaceRelativePath,
    source: FocusedPathSource?,
    contentHash: String?,
    excerpt: PromptContextExcerpt?
  ) {
    self.path = path
    self.source = source
    self.contentHash = contentHash
    self.excerpt = excerpt
  }

  fileprivate static func make(
    path: WorkspaceRelativePath,
    source: FocusedPathSource?,
    contentHash: String?,
    excerpt: PromptContextExcerpt?
  ) -> FocusedFilePromptContext {
    FocusedFilePromptContext(
      path: path,
      source: source,
      contentHash: contentHash,
      excerpt: excerpt
    )
  }
}

public struct PromptContextExcerpt: Equatable, Sendable {
  public let text: String
  public let truncated: Bool

  private init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }

  fileprivate static func make(text: String, truncated: Bool) -> PromptContextExcerpt {
    PromptContextExcerpt(text: text, truncated: truncated)
  }
}

public struct AmbiguousRecentFilesPromptContext: Equatable, Sendable {
  public let paths: NonEmptyWorkspaceRelativePaths

  private init(paths: NonEmptyWorkspaceRelativePaths) {
    self.paths = paths
  }

  fileprivate static func make(
    paths: NonEmptyWorkspaceRelativePaths
  ) -> AmbiguousRecentFilesPromptContext {
    AmbiguousRecentFilesPromptContext(paths: paths)
  }
}

public struct NonEmptyWorkspaceRelativePaths: Equatable, Sendable {
  private let storage: [WorkspaceRelativePath]

  public var values: [WorkspaceRelativePath] {
    storage
  }

  private init(_ storage: [WorkspaceRelativePath]) {
    self.storage = storage
  }

  fileprivate static func make(
    _ values: [WorkspaceRelativePath]
  ) -> NonEmptyWorkspaceRelativePaths? {
    guard !values.isEmpty else {
      return nil
    }
    return NonEmptyWorkspaceRelativePaths(values)
  }
}

public struct ContextBudget: Equatable, Sendable {
  public let maxCharacters: Int

  private init(maxCharacters: Int) {
    self.maxCharacters = maxCharacters
  }

  public static let focusedFileDefault = ContextBudget(maxCharacters: 4_000)

  public static func checked(maxCharacters: Int) -> ContextBudget? {
    guard maxCharacters > 0 else {
      return nil
    }
    return ContextBudget(maxCharacters: maxCharacters)
  }
}

public enum PromptContextTruncation: Equatable, Sendable {
  case none
  case byCharacterBudget
}

public protocol CurrentPromptContextSelecting: Sendable {
  func selectContext(
    userInput: String,
    mode: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    budget: ContextBudget
  ) -> CurrentPromptContext
}

public struct FocusedPromptContextSelector: CurrentPromptContextSelecting {
  public init() {}

  public func selectContext(
    userInput _: String,
    mode _: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    budget: ContextBudget
  ) -> CurrentPromptContext {
    if let activePath = focusedFileState.activePath {
      return selectedFocusedFileContext(
        activePath: activePath,
        focusedFileState: focusedFileState,
        budget: budget
      )
    }

    let ambiguousPaths = focusedFileState.recentPaths
      .filter { $0.confidence == .ambiguous }
      .prefix(3)
      .map(\.path)
    guard
      let paths = NonEmptyWorkspaceRelativePaths.make(Array(ambiguousPaths)),
      let blocks = NonEmptyPromptContextBlocks.make([
        .ambiguousRecentFiles(.make(paths: paths))
      ])
    else {
      return .empty(budget)
    }

    return .selected(.make(blocks: blocks, budget: budget, truncation: .none))
  }

  private func selectedFocusedFileContext(
    activePath: WorkspaceRelativePath,
    focusedFileState: FocusedFileState,
    budget: ContextBudget
  ) -> CurrentPromptContext {
    let focusedPath = focusedFileState.recentPaths.first { $0.path == activePath }
    let snapshot = focusedFileState.snapshots[activePath]
    let excerpt = snapshot?.excerpt.map { excerpt in
      truncatedExcerpt(excerpt, budget: budget)
    }
    let truncation =
      excerpt?.truncated == true
      ? PromptContextTruncation.byCharacterBudget
      : .none
    guard
      let blocks = NonEmptyPromptContextBlocks.make([
        .focusedFile(
          .make(
            path: activePath,
            source: focusedPath?.source,
            contentHash: snapshot?.contentHash,
            excerpt: excerpt
          ))
      ])
    else {
      return .empty(budget)
    }

    return .selected(.make(blocks: blocks, budget: budget, truncation: truncation))
  }

  private func truncatedExcerpt(
    _ excerpt: String,
    budget: ContextBudget
  ) -> PromptContextExcerpt {
    guard excerpt.count > budget.maxCharacters else {
      return .make(text: excerpt, truncated: false)
    }

    return .make(
      text: String(excerpt.prefix(budget.maxCharacters)),
      truncated: true
    )
  }
}

public enum CurrentPromptContextRenderer {
  public static func render(_ context: CurrentPromptContext) -> [String] {
    switch context {
    case .empty:
      return []
    case .selected(let selection):
      return selection.blocks.values.map(renderBlock)
    }
  }

  private static func renderBlock(_ block: PromptContextBlock) -> String {
    switch block {
    case .focusedFile(let context):
      return renderFocusedFile(context)
    case .ambiguousRecentFiles(let context):
      return renderAmbiguousRecentFiles(context)
    }
  }

  private static func renderFocusedFile(_ context: FocusedFilePromptContext) -> String {
    var lines = [
      "Current focused file: \(context.path.rawValue)"
    ]
    if let source = context.source {
      lines.append("Source: \(source.modelContextDescription)")
    }
    if let contentHash = context.contentHash {
      lines.append("Content hash: \(contentHash)")
    }
    if let excerpt = context.excerpt {
      lines.append("Known content excerpt:")
      lines.append(excerpt.text)
      if excerpt.truncated {
        lines.append("Known content excerpt was truncated to the current context budget.")
      }
    }
    lines.append("Explicit file paths in the user request or tool call take precedence.")
    return lines.joined(separator: "\n")
  }

  private static func renderAmbiguousRecentFiles(
    _ context: AmbiguousRecentFilesPromptContext
  ) -> String {
    let paths = context.paths.values.map { "- \($0.rawValue)" }
    return """
      Recent files are ambiguous:
      \(paths.joined(separator: "\n"))
      Do not assume a single active file unless the user names one.
      """
  }
}

nonisolated extension FocusedPathSource {
  fileprivate var modelContextDescription: String {
    switch self {
    case .readFile:
      return "previous read_file"
    case .writeFile:
      return "previous write_file"
    case .editFile:
      return "previous edit_file"
    case .attachment:
      return "attachment"
    }
  }
}
