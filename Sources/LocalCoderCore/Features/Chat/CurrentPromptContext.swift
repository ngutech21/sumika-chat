import Crypto
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
  case attachedFile(AttachedFilePromptContext)
  case focusedFile(FocusedFilePromptContext)
  case ambiguousRecentFiles(AmbiguousRecentFilesPromptContext)
}

public struct AttachedFilePromptContext: Equatable, Sendable {
  public let path: WorkspaceRelativePath
  public let displayName: String
  public let contentHash: String
  public let excerpt: PromptContextExcerpt?
  public let isEmpty: Bool

  private init(
    path: WorkspaceRelativePath,
    displayName: String,
    contentHash: String,
    excerpt: PromptContextExcerpt?,
    isEmpty: Bool
  ) {
    self.path = path
    self.displayName = displayName
    self.contentHash = contentHash
    self.excerpt = excerpt
    self.isEmpty = isEmpty
  }

  fileprivate static func make(
    path: WorkspaceRelativePath,
    displayName: String,
    contentHash: String,
    excerpt: PromptContextExcerpt?,
    isEmpty: Bool
  ) -> AttachedFilePromptContext {
    AttachedFilePromptContext(
      path: path,
      displayName: displayName,
      contentHash: contentHash,
      excerpt: excerpt,
      isEmpty: isEmpty
    )
  }
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

extension NonEmptyWorkspaceRelativePaths: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let values = try container.decode([WorkspaceRelativePath].self)
    guard let paths = Self.make(values) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "NonEmptyWorkspaceRelativePaths requires at least one path."
      )
    }
    self = paths
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storage)
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

  fileprivate static func unsafe(maxCharacters: Int) -> ContextBudget {
    ContextBudget(maxCharacters: maxCharacters)
  }
}

public enum PromptContextTruncation: String, Codable, Equatable, Sendable {
  case none
  case byCharacterBudget
}

public struct RenderedCurrentPromptContext: Equatable, Sendable {
  public let renderedBlocks: [String]
  public let consumedContext: ConsumedCurrentPromptContext

  fileprivate init(
    renderedBlocks: [String],
    consumedContext: ConsumedCurrentPromptContext
  ) {
    self.renderedBlocks = renderedBlocks
    self.consumedContext = consumedContext
  }
}

public enum ConsumedCurrentPromptContext: Codable, Equatable, Sendable {
  case empty(ConsumedContextBudget)
  case selected(ConsumedCurrentPromptContextSelection)

  fileprivate static func snapshot(from context: CurrentPromptContext)
    -> ConsumedCurrentPromptContext
  {
    switch context {
    case .empty(let budget):
      return .empty(.make(from: budget))
    case .selected(let selection):
      return .selected(.snapshot(from: selection))
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case empty
    case selected
  }

  private enum Kind: String, Codable {
    case empty
    case selected
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .empty:
      self = .empty(try container.decode(ConsumedContextBudget.self, forKey: .empty))
    case .selected:
      self = .selected(
        try container.decode(ConsumedCurrentPromptContextSelection.self, forKey: .selected)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .empty(let budget):
      try container.encode(Kind.empty, forKey: .kind)
      try container.encode(budget, forKey: .empty)
    case .selected(let selection):
      try container.encode(Kind.selected, forKey: .kind)
      try container.encode(selection, forKey: .selected)
    }
  }
}

public struct ConsumedCurrentPromptContextSelection: Codable, Equatable, Sendable {
  public let blocks: NonEmptyConsumedPromptContextBlocks
  public let budget: ConsumedContextBudget
  public let truncation: PromptContextTruncation

  private init(
    blocks: NonEmptyConsumedPromptContextBlocks,
    budget: ConsumedContextBudget,
    truncation: PromptContextTruncation
  ) {
    self.blocks = blocks
    self.budget = budget
    self.truncation = truncation
  }

  fileprivate static func snapshot(
    from selection: CurrentPromptContextSelection
  ) -> ConsumedCurrentPromptContextSelection {
    ConsumedCurrentPromptContextSelection(
      blocks: .snapshot(from: selection.blocks),
      budget: .make(from: selection.budget),
      truncation: selection.truncation
    )
  }
}

public struct NonEmptyConsumedPromptContextBlocks: Codable, Equatable, Sendable {
  private let storage: [ConsumedPromptContextBlock]

  public var values: [ConsumedPromptContextBlock] {
    storage
  }

  private init(_ storage: [ConsumedPromptContextBlock]) {
    self.storage = storage
  }

  fileprivate static func make(
    _ values: [ConsumedPromptContextBlock]
  ) -> NonEmptyConsumedPromptContextBlocks? {
    guard !values.isEmpty else {
      return nil
    }
    return NonEmptyConsumedPromptContextBlocks(values)
  }

  fileprivate static func snapshot(
    from blocks: NonEmptyPromptContextBlocks
  ) -> NonEmptyConsumedPromptContextBlocks {
    NonEmptyConsumedPromptContextBlocks(blocks.values.map(ConsumedPromptContextBlock.snapshot))
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let values = try container.decode([ConsumedPromptContextBlock].self)
    guard let blocks = Self.make(values) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "NonEmptyConsumedPromptContextBlocks requires at least one block."
      )
    }
    self = blocks
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storage)
  }
}

public enum ConsumedPromptContextBlock: Codable, Equatable, Sendable {
  case attachedFile(ConsumedAttachedFilePromptContext)
  case focusedFile(ConsumedFocusedFilePromptContext)
  case ambiguousRecentFiles(ConsumedAmbiguousFilesPromptContext)

  fileprivate static func snapshot(from block: PromptContextBlock) -> ConsumedPromptContextBlock {
    switch block {
    case .attachedFile(let context):
      return .attachedFile(.snapshot(from: context))
    case .focusedFile(let context):
      return .focusedFile(.snapshot(from: context))
    case .ambiguousRecentFiles(let context):
      return .ambiguousRecentFiles(.snapshot(from: context))
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case attachedFile
    case focusedFile
    case ambiguousRecentFiles
  }

  private enum Kind: String, Codable {
    case attachedFile
    case focusedFile
    case ambiguousRecentFiles
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .attachedFile:
      self = .attachedFile(
        try container.decode(ConsumedAttachedFilePromptContext.self, forKey: .attachedFile)
      )
    case .focusedFile:
      self = .focusedFile(
        try container.decode(ConsumedFocusedFilePromptContext.self, forKey: .focusedFile)
      )
    case .ambiguousRecentFiles:
      self = .ambiguousRecentFiles(
        try container.decode(
          ConsumedAmbiguousFilesPromptContext.self,
          forKey: .ambiguousRecentFiles
        )
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .attachedFile(let context):
      try container.encode(Kind.attachedFile, forKey: .kind)
      try container.encode(context, forKey: .attachedFile)
    case .focusedFile(let context):
      try container.encode(Kind.focusedFile, forKey: .kind)
      try container.encode(context, forKey: .focusedFile)
    case .ambiguousRecentFiles(let context):
      try container.encode(Kind.ambiguousRecentFiles, forKey: .kind)
      try container.encode(context, forKey: .ambiguousRecentFiles)
    }
  }
}

public struct ConsumedAttachedFilePromptContext: Codable, Equatable, Sendable {
  public let path: WorkspaceRelativePath
  public let displayName: String
  public let contentHash: String
  public let excerpt: ConsumedPromptContextExcerpt?
  public let isEmpty: Bool

  private init(
    path: WorkspaceRelativePath,
    displayName: String,
    contentHash: String,
    excerpt: ConsumedPromptContextExcerpt?,
    isEmpty: Bool
  ) {
    self.path = path
    self.displayName = displayName
    self.contentHash = contentHash
    self.excerpt = excerpt
    self.isEmpty = isEmpty
  }

  fileprivate static func snapshot(
    from context: AttachedFilePromptContext
  ) -> ConsumedAttachedFilePromptContext {
    ConsumedAttachedFilePromptContext(
      path: context.path,
      displayName: context.displayName,
      contentHash: context.contentHash,
      excerpt: context.excerpt.map(ConsumedPromptContextExcerpt.snapshot),
      isEmpty: context.isEmpty
    )
  }
}

public struct ConsumedFocusedFilePromptContext: Codable, Equatable, Sendable {
  public let path: WorkspaceRelativePath
  public let source: FocusedPathSource?
  public let contentHash: String?
  public let excerpt: ConsumedPromptContextExcerpt?

  private init(
    path: WorkspaceRelativePath,
    source: FocusedPathSource?,
    contentHash: String?,
    excerpt: ConsumedPromptContextExcerpt?
  ) {
    self.path = path
    self.source = source
    self.contentHash = contentHash
    self.excerpt = excerpt
  }

  fileprivate static func snapshot(
    from context: FocusedFilePromptContext
  ) -> ConsumedFocusedFilePromptContext {
    ConsumedFocusedFilePromptContext(
      path: context.path,
      source: context.source,
      contentHash: context.contentHash,
      excerpt: context.excerpt.map(ConsumedPromptContextExcerpt.snapshot)
    )
  }
}

public struct ConsumedAmbiguousFilesPromptContext: Codable, Equatable, Sendable {
  public let paths: NonEmptyWorkspaceRelativePaths

  private init(paths: NonEmptyWorkspaceRelativePaths) {
    self.paths = paths
  }

  fileprivate static func snapshot(
    from context: AmbiguousRecentFilesPromptContext
  ) -> ConsumedAmbiguousFilesPromptContext {
    ConsumedAmbiguousFilesPromptContext(paths: context.paths)
  }
}

public struct ConsumedPromptContextExcerpt: Codable, Equatable, Sendable {
  public let text: String
  public let truncated: Bool

  private init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }

  fileprivate static func snapshot(from excerpt: PromptContextExcerpt)
    -> ConsumedPromptContextExcerpt
  {
    ConsumedPromptContextExcerpt(text: excerpt.text, truncated: excerpt.truncated)
  }
}

public struct ConsumedContextBudget: Codable, Equatable, Sendable {
  public let maxCharacters: Int

  private init(maxCharacters: Int) {
    self.maxCharacters = maxCharacters
  }

  fileprivate static func make(from budget: ContextBudget) -> ConsumedContextBudget {
    ConsumedContextBudget(maxCharacters: budget.maxCharacters)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let maxCharacters = try container.decode(Int.self)
    guard maxCharacters > 0 else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "ConsumedContextBudget.maxCharacters must be greater than zero."
      )
    }
    self.init(maxCharacters: maxCharacters)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(maxCharacters)
  }
}

public protocol CurrentPromptContextSelecting: Sendable {
  func selectContext(
    userInput: String,
    mode: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    attachments: [ChatAttachment],
    workspace: Workspace?,
    budget: ContextBudget
  ) -> CurrentPromptContext
}

extension CurrentPromptContextSelecting {
  public func selectContext(
    userInput: String,
    mode: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    budget: ContextBudget
  ) -> CurrentPromptContext {
    selectContext(
      userInput: userInput,
      mode: mode,
      focusedFileState: focusedFileState,
      attachments: [],
      workspace: nil,
      budget: budget
    )
  }
}

public struct CurrentPromptContextSelector: CurrentPromptContextSelecting {
  public init() {}

  public func selectContext(
    userInput _: String,
    mode _: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    attachments: [ChatAttachment] = [],
    workspace: Workspace? = nil,
    budget: ContextBudget
  ) -> CurrentPromptContext {
    if let attachedFileContext = selectedAttachedFilesContext(
      attachments,
      workspace: workspace,
      budget: budget
    ) {
      return attachedFileContext
    }

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

  private func selectedAttachedFilesContext(
    _ attachments: [ChatAttachment],
    workspace: Workspace?,
    budget: ContextBudget
  ) -> CurrentPromptContext? {
    let validAttachments = attachments.compactMap {
      attachmentContextInput($0, workspace: workspace)
    }
    guard !validAttachments.isEmpty else {
      return nil
    }

    let perAttachmentBudget = max(1, budget.maxCharacters / validAttachments.count)
    let blocks = validAttachments.map { input in
      let excerpt =
        input.content.isEmpty
        ? nil
        : truncatedExcerpt(
          input.content,
          budget: ContextBudget.unsafe(maxCharacters: perAttachmentBudget)
        )
      return PromptContextBlock.attachedFile(
        .make(
          path: input.path,
          displayName: input.displayName,
          contentHash: Self.contentHash(for: input.content),
          excerpt: excerpt,
          isEmpty: input.content.isEmpty
        )
      )
    }
    guard let nonEmptyBlocks = NonEmptyPromptContextBlocks.make(blocks) else {
      return nil
    }

    let truncation =
      blocks.contains { block in
        if case .attachedFile(let context) = block {
          return context.excerpt?.truncated == true
        }
        return false
      }
      ? PromptContextTruncation.byCharacterBudget
      : .none
    return .selected(.make(blocks: nonEmptyBlocks, budget: budget, truncation: truncation))
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

  private func attachmentContextInput(
    _ attachment: ChatAttachment,
    workspace: Workspace?
  ) -> AttachmentContextInput? {
    let displayName = attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else {
      return nil
    }

    let path = attachmentPath(for: attachment, workspace: workspace)
    guard !path.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    return AttachmentContextInput(
      path: path,
      displayName: displayName,
      content: attachment.content
    )
  }

  private func attachmentPath(
    for attachment: ChatAttachment,
    workspace: Workspace?
  ) -> WorkspaceRelativePath {
    guard let workspace else {
      return WorkspaceRelativePath(rawValue: attachment.displayName)
    }

    let resolvedURL = attachment.url.standardizedFileURL.resolvingSymlinksInPath()
    let path = workspace.relativePath(for: resolvedURL)
    if path.rawValue.hasPrefix("/") {
      return WorkspaceRelativePath(rawValue: attachment.displayName)
    }
    return path
  }

  private static func contentHash(for content: String) -> String {
    let digest = SHA256.hash(data: Data(content.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private struct AttachmentContextInput {
    let path: WorkspaceRelativePath
    let displayName: String
    let content: String
  }
}

public enum CurrentPromptContextRenderer {
  public static func renderedContext(_ context: CurrentPromptContext)
    -> RenderedCurrentPromptContext
  {
    RenderedCurrentPromptContext(
      renderedBlocks: render(context),
      consumedContext: .snapshot(from: context)
    )
  }

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
    case .attachedFile(let context):
      return renderAttachedFile(context)
    case .focusedFile(let context):
      return renderFocusedFile(context)
    case .ambiguousRecentFiles(let context):
      return renderAmbiguousRecentFiles(context)
    }
  }

  private static func renderAttachedFile(_ context: AttachedFilePromptContext) -> String {
    var lines = [
      "Attached file: \(context.path.rawValue)"
    ]
    if context.displayName != context.path.rawValue {
      lines.append("Display name: \(context.displayName)")
    }
    lines.append("Content hash: \(context.contentHash)")
    if let excerpt = context.excerpt {
      lines.append("Attached content excerpt:")
      lines.append(excerpt.text)
      if excerpt.truncated {
        lines.append("Attached content excerpt was truncated to the current context budget.")
      }
    } else if context.isEmpty {
      lines.append("Attached file is empty.")
    }
    lines.append("Explicit file paths in the user request or tool call take precedence.")
    return lines.joined(separator: "\n")
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
