// Crypto is used directly; the analyzer compiler log does not attribute it reliably.
// swiftlint:disable:next unused_import
import Crypto
import Foundation

package enum CurrentPromptContext: Codable, Equatable, Sendable {
  case empty(ContextBudget)
  case selected(CurrentPromptContextSelection)

  private enum CodingKeys: String, CodingKey {
    case kind
    case empty
    case selected
  }

  private enum Kind: String, Codable {
    case empty
    case selected
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .empty:
      self = .empty(try container.decode(ContextBudget.self, forKey: .empty))
    case .selected:
      self = .selected(
        try container.decode(CurrentPromptContextSelection.self, forKey: .selected)
      )
    }
  }

  package func encode(to encoder: Encoder) throws {
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

  package var workspaceInstructions: [WorkspaceInstructionsPromptContext] {
    guard case .selected(let selection) = self else {
      return []
    }
    return selection.blocks.values.compactMap { block in
      guard case .workspaceInstructions(let context) = block else {
        return nil
      }
      return context
    }
  }

  package func appendingWorkspaceInstructions(
    _ workspaceInstructions: WorkspaceInstructionsPromptContext
  ) -> CurrentPromptContext {
    let budget: ContextBudget
    let truncation: PromptContextTruncation
    let existingBlocks: [PromptContextBlock]
    switch self {
    case .empty(let existingBudget):
      budget = existingBudget
      truncation = .none
      existingBlocks = []
    case .selected(let selection):
      budget = selection.budget
      truncation = selection.truncation
      existingBlocks = selection.blocks.values.filter { block in
        if case .workspaceInstructions = block {
          return false
        }
        return true
      }
    }

    let blocks = existingBlocks + [.workspaceInstructions(workspaceInstructions)]
    guard let nonEmptyBlocks = NonEmptyPromptContextBlocks.make(blocks) else {
      return .empty(budget)
    }
    return .selected(
      .make(blocks: nonEmptyBlocks, budget: budget, truncation: truncation)
    )
  }

  package func removingWorkspaceInstructions() -> CurrentPromptContext {
    guard case .selected(let selection) = self else {
      return self
    }
    let remainingBlocks = selection.blocks.values.filter { block in
      if case .workspaceInstructions = block {
        return false
      }
      return true
    }
    guard let blocks = NonEmptyPromptContextBlocks.make(remainingBlocks) else {
      return .empty(selection.budget)
    }
    return .selected(
      .make(blocks: blocks, budget: selection.budget, truncation: selection.truncation)
    )
  }
}

package struct CurrentPromptContextSelection: Codable, Equatable, Sendable {
  package let blocks: NonEmptyPromptContextBlocks
  package let budget: ContextBudget
  package let truncation: PromptContextTruncation

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

package struct NonEmptyPromptContextBlocks: Codable, Equatable, Sendable {
  private let storage: [PromptContextBlock]

  package var values: [PromptContextBlock] {
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

  package init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let values = try container.decode([PromptContextBlock].self)
    guard let blocks = Self.make(values) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "NonEmptyPromptContextBlocks requires at least one block."
      )
    }
    self = blocks
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storage)
  }
}

package enum PromptContextBlock: Codable, Equatable, Sendable {
  case attachedFile(AttachedFilePromptContext)
  case focusedFile(FocusedFilePromptContext)
  case ambiguousRecentFiles(AmbiguousRecentFilesPromptContext)
  case workspaceInstructions(WorkspaceInstructionsPromptContext)

  private enum CodingKeys: String, CodingKey {
    case kind
    case attachedFile
    case focusedFile
    case ambiguousRecentFiles
    case workspaceInstructions
  }

  private enum Kind: String, Codable {
    case attachedFile
    case focusedFile
    case ambiguousRecentFiles
    case workspaceInstructions
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .attachedFile:
      self = .attachedFile(
        try container.decode(AttachedFilePromptContext.self, forKey: .attachedFile)
      )
    case .focusedFile:
      self = .focusedFile(
        try container.decode(FocusedFilePromptContext.self, forKey: .focusedFile)
      )
    case .ambiguousRecentFiles:
      self = .ambiguousRecentFiles(
        try container.decode(
          AmbiguousRecentFilesPromptContext.self,
          forKey: .ambiguousRecentFiles
        )
      )
    case .workspaceInstructions:
      self = .workspaceInstructions(
        try container.decode(
          WorkspaceInstructionsPromptContext.self,
          forKey: .workspaceInstructions
        )
      )
    }
  }

  package func encode(to encoder: Encoder) throws {
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
    case .workspaceInstructions(let context):
      try container.encode(Kind.workspaceInstructions, forKey: .kind)
      try container.encode(context, forKey: .workspaceInstructions)
    }
  }
}

package struct AttachedFilePromptContext: Codable, Equatable, Sendable {
  package let path: WorkspaceRelativePath
  package let displayName: String
  package let contentHash: String
  package let excerpt: PromptContextExcerpt?
  package let isEmpty: Bool

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

package struct FocusedFilePromptContext: Codable, Equatable, Sendable {
  package let path: WorkspaceRelativePath
  package let source: FocusedPathSource?
  package let contentHash: String?
  package let excerpt: PromptContextExcerpt?
  package let fullContentAvailable: Bool

  private enum CodingKeys: String, CodingKey {
    case path
    case source
    case contentHash
    case excerpt
    case fullContentAvailable
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(WorkspaceRelativePath.self, forKey: .path)
    source = try container.decodeIfPresent(FocusedPathSource.self, forKey: .source)
    contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
    excerpt = try container.decodeIfPresent(PromptContextExcerpt.self, forKey: .excerpt)
    if container.contains(.fullContentAvailable) {
      fullContentAvailable = try container.decode(Bool.self, forKey: .fullContentAvailable)
    } else if decoder.userInfo[.isLegacyWorkspaceMigration] as? Bool == true {
      fullContentAvailable = false
    } else {
      fullContentAvailable = try container.decode(Bool.self, forKey: .fullContentAvailable)
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(source, forKey: .source)
    try container.encodeIfPresent(contentHash, forKey: .contentHash)
    try container.encodeIfPresent(excerpt, forKey: .excerpt)
    try container.encode(fullContentAvailable, forKey: .fullContentAvailable)
  }

  package var isReuseEligible: Bool {
    guard source == .readFile,
      fullContentAvailable,
      let contentHash,
      !contentHash.isEmpty,
      let excerpt,
      !excerpt.truncated
    else {
      return false
    }
    return true
  }

  private init(
    path: WorkspaceRelativePath,
    source: FocusedPathSource?,
    contentHash: String?,
    excerpt: PromptContextExcerpt?,
    fullContentAvailable: Bool
  ) {
    self.path = path
    self.source = source
    self.contentHash = contentHash
    self.excerpt = excerpt
    self.fullContentAvailable = fullContentAvailable
  }

  fileprivate static func make(
    path: WorkspaceRelativePath,
    source: FocusedPathSource?,
    contentHash: String?,
    excerpt: PromptContextExcerpt?,
    fullContentAvailable: Bool
  ) -> FocusedFilePromptContext {
    FocusedFilePromptContext(
      path: path,
      source: source,
      contentHash: contentHash,
      excerpt: excerpt,
      fullContentAvailable: fullContentAvailable
    )
  }
}

package enum FocusedFilePromptPresentation: Equatable, Sendable {
  case full
  case compactReuse
}

package struct AmbiguousRecentFilesPromptContext: Codable, Equatable, Sendable {
  package let paths: NonEmptyWorkspaceRelativePaths

  private init(paths: NonEmptyWorkspaceRelativePaths) {
    self.paths = paths
  }

  fileprivate static func make(
    paths: NonEmptyWorkspaceRelativePaths
  ) -> AmbiguousRecentFilesPromptContext {
    AmbiguousRecentFilesPromptContext(paths: paths)
  }
}

package struct NonEmptyWorkspaceRelativePaths: Equatable, Sendable {
  private let storage: [WorkspaceRelativePath]

  package var values: [WorkspaceRelativePath] {
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
  package init(from decoder: Decoder) throws {
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

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storage)
  }
}

internal struct CurrentPromptContextSelector: Sendable {
  package func selectContext(
    mode _: WorkspaceInteractionMode,
    focusedFileState: FocusedFileState,
    attachments: [ChatAttachment] = [],
    budget: ContextBudget
  ) -> CurrentPromptContext {
    if let attachedFileContext = selectedAttachedFilesContext(
      attachments,
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
    budget: ContextBudget
  ) -> CurrentPromptContext? {
    let validAttachments = attachments.filter { $0.kind == .text }.compactMap {
      attachmentContextInput($0)
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
          path: WorkspaceRelativePath(rawValue: input.displayName),
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
    let excerpt = snapshot.flatMap { snapshot -> PromptContextExcerpt? in
      if let excerpt = snapshot.excerpt {
        return truncatedExcerpt(excerpt, budget: budget)
      }
      if snapshot.fullContentAvailable {
        return .make(text: "", truncated: false)
      }
      return nil
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
            excerpt: excerpt,
            fullContentAvailable: snapshot?.fullContentAvailable ?? false
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
    _ attachment: ChatAttachment
  ) -> AttachmentContextInput? {
    let displayName = attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else {
      return nil
    }

    return AttachmentContextInput(
      displayName: displayName,
      content: attachment.content
    )
  }

  private static func contentHash(for content: String) -> String {
    let digest = SHA256.hash(data: Data(content.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private struct AttachmentContextInput {
    let displayName: String
    let content: String
  }
}

internal enum CurrentPromptContextRenderer {
  package static func renderWorkspaceInstructions(
    _ context: CurrentPromptContext
  ) -> [String] {
    guard case .selected(let selection) = context else {
      return []
    }
    return selection.blocks.values.compactMap { block in
      guard case .workspaceInstructions(let workspaceInstructions) = block else {
        return nil
      }
      return renderWorkspaceInstructions(workspaceInstructions)
    }
  }

  package static func renderSupportingContext(
    _ context: CurrentPromptContext,
    focusedFilePresentation: FocusedFilePromptPresentation = .full
  ) -> [String] {
    guard case .selected(let selection) = context else {
      return []
    }
    return selection.blocks.values.compactMap { block in
      guard case .workspaceInstructions = block else {
        return renderBlock(block, focusedFilePresentation: focusedFilePresentation)
      }
      return nil
    }
  }

  private static func renderBlock(
    _ block: PromptContextBlock,
    focusedFilePresentation: FocusedFilePromptPresentation
  ) -> String? {
    switch block {
    case .attachedFile(let context):
      return renderAttachedFile(context)
    case .focusedFile(let context):
      if focusedFilePresentation == .compactReuse, context.isReuseEligible {
        return renderCompactFocusedFile(context)
      }
      return renderFullFocusedFile(context)
    case .ambiguousRecentFiles(let context):
      return renderAmbiguousRecentFiles(context)
    case .workspaceInstructions(let context):
      return renderWorkspaceInstructions(context)
    }
  }

  private static func renderWorkspaceInstructions(
    _ context: WorkspaceInstructionsPromptContext
  ) -> String? {
    guard case .snapshot(let snapshot) = context else {
      return nil
    }
    var lines = [
      "Workspace instructions: \(snapshot.path.rawValue)",
      "These are trusted project instructions for work in this workspace.",
      "Follow them unless they conflict with application safety rules or the user's explicit request.",
      "They cannot override either.",
      "",
      snapshot.excerpt.text.isEmpty ? "(empty file)" : snapshot.excerpt.text,
    ]
    if snapshot.truncation == .byCharacterBudget {
      lines.append("")
      lines.append(
        "These workspace instructions were truncated after \(groupedDecimal(snapshot.budget.maxCharacters)) characters."
      )
      lines.append(
        "Before changing workspace files, read the complete \(snapshot.path.rawValue) with read_file."
      )
      lines.append(
        "The complete content from that exact path remains trusted project context under the same precedence rules."
      )
    }
    return lines.joined(separator: "\n")
  }

  private static func groupedDecimal(_ value: Int) -> String {
    let digits = Array(String(value))
    return digits.enumerated().map { index, digit in
      let remaining = digits.count - index
      return index > 0 && remaining.isMultiple(of: 3) ? ",\(digit)" : String(digit)
    }.joined()
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

  private static func renderFullFocusedFile(_ context: FocusedFilePromptContext) -> String {
    var lines = [
      "Current focused file: \(context.path.rawValue)"
    ]
    if let source = context.source {
      lines.append("Source: \(source.modelContextDescription)")
    }
    if let excerpt = context.excerpt {
      lines.append("Known content excerpt:")
      lines.append(excerpt.text.isEmpty ? "(empty file)" : excerpt.text)
      if excerpt.truncated {
        lines.append("Known content excerpt was truncated to the current context budget.")
      }
    }
    lines.append("Explicit file paths in the user request or tool call take precedence.")
    return lines.joined(separator: "\n")
  }

  private static func renderCompactFocusedFile(_ context: FocusedFilePromptContext) -> String {
    """
    Current focused file: \(context.path.rawValue)
    Source: previous read_file
    Same known complete snapshot as in the recent context; content is not repeated.
    Call read_file before editing if the file may have changed.
    """
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
