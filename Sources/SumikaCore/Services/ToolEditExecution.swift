import Foundation

public struct EditFileInput: Codable, Equatable, Sendable {
  public let path: String
  public let oldText: String
  public let newText: String

  private enum CodingKeys: String, CodingKey {
    case path
    case oldText = "old_text"
    case newText = "new_text"
  }
}

public struct EditFileToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.editFile

  public func evaluatePermission(
    _ input: EditFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Editing files inside the workspace requires approval.",
        riskLevel: .high,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: resolvedPath)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .high
      )
    }
  }

  public func previewApproval(_ input: EditFileInput, context: ToolContext) async
    -> ToolResultPreview?
  {
    var resolvedURL: URL?
    do {
      return try context.workspace.withSecurityScopedAccess {
        resolvedURL = try context.workspace.resolveAllowedPath(input.path)
        let edit = try validatedEdit(input, context: context)
        resolvedURL = edit.resolvedURL
        return ToolResultPreview(
          status: .success,
          text: Self.diffPreview(for: edit),
          affectedPaths: [context.workspace.relativePath(for: edit.resolvedURL).rawValue]
        )
      }
    } catch {
      return failurePreview(for: input, context: context, resolvedURL: resolvedURL, error: error)
    }
  }

  public func run(_ input: EditFileInput, context: ToolContext) async -> ToolResultPayload {
    var resolvedURL: URL?
    do {
      return try context.workspace.withSecurityScopedAccess {
        resolvedURL = try context.workspace.resolveAllowedPath(input.path)
        let edit = try validatedEdit(input, context: context)
        resolvedURL = edit.resolvedURL
        try edit.updatedContent.write(to: edit.resolvedURL, atomically: true, encoding: .utf8)
        return .editFile(
          .success(
            path: context.workspace.relativePath(for: edit.resolvedURL),
            diff: nil,
            matchStrategy: edit.matchStrategy
          )
        )
      }
    } catch EditFileValidationError.oldTextNotFound {
      return context.workspace.withSecurityScopedAccess {
        oldTextNotFoundResult(input, context: context, resolvedURL: resolvedURL)
      }
    } catch EditFileValidationError.ambiguousOldText {
      let path = ToolResultFailureMapper.relativePath(
        for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
      return .editFile(
        .multipleMatches(
          path: path ?? WorkspaceRelativePath(rawValue: input.path),
          matchCount: 2,
          recovery: .retryWithMoreContext(path: path ?? WorkspaceRelativePath(rawValue: input.path))
        )
      )
    } catch EditFileValidationError.identicalReplacement {
      let path = ToolResultFailureMapper.relativePath(
        for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
      return .editFile(.unchanged(path: path ?? WorkspaceRelativePath(rawValue: input.path)))
    } catch {
      return .editFile(
        .failed(
          path: ToolResultFailureMapper.relativePath(
            for: input.path, resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.isFileNotFound(error)
            ? ToolResultFailureMapper.missingFileReason(
              for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
            : ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }

  private func failurePreview(
    for input: EditFileInput,
    context: ToolContext,
    resolvedURL: URL?,
    error: Error
  ) -> ToolResultPreview {
    if case EditFileValidationError.oldTextNotFound = error {
      return oldTextNotFoundResult(input, context: context, resolvedURL: resolvedURL).preview
    }

    guard ToolResultFailureMapper.isFileNotFound(error) else {
      return ToolResultPreview(status: .failed, text: error.localizedDescription)
    }

    return ToolResultPayload.editFile(
      .failed(
        path: ToolResultFailureMapper.relativePath(
          for: input.path, resolvedURL: resolvedURL, workspace: context.workspace),
        reason: ToolResultFailureMapper.missingFileReason(
          for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
      )
    ).preview
  }

  private func oldTextNotFoundResult(
    _ input: EditFileInput,
    context: ToolContext,
    resolvedURL: URL?
  ) -> ToolResultPayload {
    let path =
      ToolResultFailureMapper.relativePath(
        for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
      ?? WorkspaceRelativePath(rawValue: input.path)
    let content = currentContentExcerpt(from: resolvedURL)
    return .editFile(
      .oldTextNotFound(
        path: path,
        currentContent: content,
        recovery: .readFile(path: path)
      )
    )
  }

  private func currentContentExcerpt(from url: URL?) -> ToolTextOutput? {
    guard let url, let data = try? Data(contentsOf: url) else {
      return nil
    }
    let maxBytes = 24 * 1024
    guard data.count <= maxBytes else {
      let excerptData = data.prefix(maxBytes)
      guard let excerpt = String(data: excerptData, encoding: .utf8) else {
        return nil
      }
      return ToolTextOutput(text: excerpt, truncated: true)
    }
    guard let content = String(data: data, encoding: .utf8) else {
      return nil
    }
    return ToolTextOutput(text: content)
  }

  private func validatedEdit(
    _ input: EditFileInput,
    context: ToolContext
  ) throws -> ValidatedEdit {
    guard !input.oldText.isEmpty else {
      throw EditFileValidationError.emptyOldText
    }

    guard input.oldText != input.newText else {
      throw EditFileValidationError.identicalReplacement
    }

    let resolvedURL = try context.workspace.resolveAllowedPath(input.path)
    let data = try Data(contentsOf: resolvedURL)
    guard let content = String(data: data, encoding: .utf8) else {
      throw EditFileValidationError.nonUTF8
    }

    let match = try Self.validatedMatch(
      oldText: input.oldText,
      newText: input.newText,
      content: content
    )

    var updatedContent = content
    updatedContent.replaceSubrange(match.range, with: match.replacementText)
    return ValidatedEdit(
      path: input.path,
      resolvedURL: resolvedURL,
      oldText: String(content[match.range]),
      newText: match.replacementText,
      matchStrategy: match.strategy,
      updatedContent: updatedContent
    )
  }

  private static func validatedMatch(
    oldText: String,
    newText: String,
    content: String
  ) throws -> EditMatch {
    let strategies: [EditMatchStrategy] = [
      .exact,
      .normalizedLineEndings,
      .trimTrailingWhitespace,
      .indentationFlexible,
      .lineTrimmedBlock,
    ]

    // Tokenize old/content once and share it across the line-window strategies.
    // The cache is lazy: the exact and normalized strategies never touch it, so a
    // byte-exact match (the common case) returns without tokenizing the whole file.
    let tokens = TokenizedEdit(oldText: oldText, content: content)

    for strategy in strategies {
      let matches = matches(
        oldText: oldText,
        newText: newText,
        content: content,
        strategy: strategy,
        maxCount: 2,
        tokens: tokens
      )

      if matches.count == 1 {
        let match = matches[0]
        guard String(content[match.range]) != match.replacementText else {
          throw EditFileValidationError.identicalReplacement
        }
        return match
      }

      if matches.count > 1 {
        throw EditFileValidationError.ambiguousOldText
      }
    }

    throw EditFileValidationError.oldTextNotFound
  }

  private static func matches(
    oldText: String,
    newText: String,
    content: String,
    strategy: EditMatchStrategy,
    maxCount: Int,
    tokens: TokenizedEdit
  ) -> [EditMatch] {
    switch strategy {
    case .exact:
      return matchRanges(of: oldText, in: content, maxCount: maxCount).map { range in
        EditMatch(range: range, replacementText: newText, strategy: .exact)
      }
    case .normalizedLineEndings:
      return normalizedLineEndingMatches(
        oldText: oldText,
        newText: newText,
        content: content,
        maxCount: maxCount
      )
    case .trimTrailingWhitespace:
      return lineWindowMatches(
        oldText: oldText,
        newText: newText,
        strategy: .trimTrailingWhitespace,
        maxCount: maxCount,
        tokens: tokens
      ) { candidate, old in
        trimTrailingWhitespace(candidate.body) == trimTrailingWhitespace(old.body)
      }
    case .indentationFlexible:
      return indentationFlexibleMatches(
        oldText: oldText,
        newText: newText,
        maxCount: maxCount,
        tokens: tokens
      )
    case .lineTrimmedBlock:
      return lineWindowMatches(
        oldText: oldText,
        newText: newText,
        strategy: .lineTrimmedBlock,
        maxCount: maxCount,
        tokens: tokens,
        replacementTransform: { candidateLines, oldLines, replacementText in
          reindentByLine(
            replacementText,
            from: oldLines,
            to: candidateLines
          )
        },
        linesMatch: { candidate, old in
          candidate.body.trimmingCharacters(in: .whitespaces)
            == old.body.trimmingCharacters(in: .whitespaces)
        }
      )
    }
  }

  private static func normalizedLineEndingMatches(
    oldText: String,
    newText: String,
    content: String,
    maxCount: Int
  ) -> [EditMatch] {
    let normalizedContent = IndexedNormalizedText(lineEndingNormalizing: content)
    let normalizedOldText = normalizeLineEndings(oldText)
    let ranges = normalizedContent.sourceRanges(matching: normalizedOldText, maxCount: maxCount)

    return ranges.map { range in
      EditMatch(
        range: range,
        replacementText: convertLineEndings(newText, toMatch: String(content[range])),
        strategy: .normalizedLineEndings
      )
    }
  }

  private static func indentationFlexibleMatches(
    oldText: String,
    newText: String,
    maxCount: Int,
    tokens: TokenizedEdit
  ) -> [EditMatch] {
    guard tokens.oldLines.count > 1 else {
      return []
    }

    return lineWindowMatches(
      oldText: oldText,
      newText: newText,
      strategy: .indentationFlexible,
      maxCount: maxCount,
      tokens: tokens,
      replacementTransform: { candidateLines, oldLines, replacementText in
        reindent(
          replacementText,
          from: commonIndent(in: oldLines.map(\.body)),
          to: commonIndent(in: candidateLines.map(\.body)),
          matchingLineEndingsOf: candidateLines
        )
      },
      linesMatch: { _, _ in
        true
      },
      blocksMatch: { candidateLines, oldLines in
        deindent(candidateLines.map(\.body)) == deindent(oldLines.map(\.body))
      }
    )
  }

  private static func lineWindowMatches(
    oldText: String,
    newText: String,
    strategy: EditMatchStrategy,
    maxCount: Int,
    tokens: TokenizedEdit,
    linesMatch: (TextLine, TextLine) -> Bool
  ) -> [EditMatch] {
    lineWindowMatches(
      oldText: oldText,
      newText: newText,
      strategy: strategy,
      maxCount: maxCount,
      tokens: tokens,
      replacementTransform: { candidateLines, _, replacementText in
        convertLineEndings(replacementText, toMatch: candidateLines.map(\.fullText).joined())
      },
      linesMatch: linesMatch,
      blocksMatch: nil
    )
  }

  private static func lineWindowMatches(
    oldText: String,
    newText: String,
    strategy: EditMatchStrategy,
    maxCount: Int,
    tokens: TokenizedEdit,
    replacementTransform: ([TextLine], [TextLine], String) -> String,
    linesMatch: (TextLine, TextLine) -> Bool,
    blocksMatch: (([TextLine], [TextLine]) -> Bool)? = nil
  ) -> [EditMatch] {
    let oldLines = tokens.oldLines
    let contentLines = tokens.contentLines
    guard !oldLines.isEmpty, contentLines.count >= oldLines.count else {
      return []
    }

    var matches: [EditMatch] = []
    for startIndex in 0...(contentLines.count - oldLines.count) {
      let candidateLines = Array(contentLines[startIndex..<(startIndex + oldLines.count)])
      guard lineEndingShapeMatches(candidateLines: candidateLines, oldLines: oldLines) else {
        continue
      }

      let lineMatches = zip(candidateLines, oldLines).allSatisfy(linesMatch)
      let blockMatches = blocksMatch?(candidateLines, oldLines) ?? lineMatches
      guard blockMatches else {
        continue
      }

      let range = replacementRange(
        for: candidateLines, oldTextEndsWithLineEnding: oldText.hasSuffix("\n"))
      matches.append(
        EditMatch(
          range: range,
          replacementText: replacementTransform(candidateLines, oldLines, newText),
          strategy: strategy
        )
      )

      if matches.count >= maxCount {
        break
      }
    }

    return matches
  }

  private static func matchRanges(
    of needle: String,
    in haystack: String,
    maxCount: Int
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchStart = haystack.startIndex

    while ranges.count < maxCount,
      let range = haystack.range(
        of: needle,
        options: [],
        range: searchStart..<haystack.endIndex
      )
    {
      ranges.append(range)
      searchStart = haystack.index(after: range.lowerBound)
    }

    return ranges
  }

  private static func diffPreview(for edit: ValidatedEdit) -> String {
    let removedLines = edit.oldText.split(separator: "\n", omittingEmptySubsequences: false)
    let addedLines = edit.newText.split(separator: "\n", omittingEmptySubsequences: false)
    let removed = removedLines.map { "-\($0)" }.joined(separator: "\n")
    let added = addedLines.map { "+\($0)" }.joined(separator: "\n")

    let strategyText =
      edit.matchStrategy == .exact ? "" : " (\(edit.matchStrategy.rawValue) match)"

    return """
      --- \(edit.path)
      +++ \(edit.path)
      @@\(strategyText)
      \(removed)
      \(added)
      """
  }

  fileprivate static func lineSegments(in text: String) -> [TextLine] {
    var lines: [TextLine] = []
    var lineStart = text.startIndex
    var index = text.startIndex

    while index < text.endIndex {
      let character = String(text[index])
      if character == "\n" || character == "\r\n" || character == "\r" {
        var nextIndex = text.index(after: index)
        if character == "\r", nextIndex < text.endIndex, String(text[nextIndex]) == "\n" {
          nextIndex = text.index(after: nextIndex)
        }

        let bodyEnd: String.Index
        let lineEndingStart: String.Index
        if character == "\n", index > lineStart {
          let previousIndex = text.index(before: index)
          if text[previousIndex] == "\r" {
            bodyEnd = previousIndex
            lineEndingStart = previousIndex
          } else {
            bodyEnd = index
            lineEndingStart = index
          }
        } else {
          bodyEnd = index
          lineEndingStart = index
        }

        lines.append(
          TextLine(
            body: String(text[lineStart..<bodyEnd]),
            lineEnding: String(text[lineEndingStart..<nextIndex]),
            bodyRange: lineStart..<bodyEnd,
            fullRange: lineStart..<nextIndex,
            fullText: String(text[lineStart..<nextIndex])
          )
        )
        lineStart = nextIndex
        index = nextIndex
      } else {
        index = text.index(after: index)
      }
    }

    if lineStart < text.endIndex {
      lines.append(
        TextLine(
          body: String(text[lineStart..<text.endIndex]),
          lineEnding: "",
          bodyRange: lineStart..<text.endIndex,
          fullRange: lineStart..<text.endIndex,
          fullText: String(text[lineStart..<text.endIndex])
        )
      )
    }

    return lines
  }

  private static func lineEndingShapeMatches(
    candidateLines: [TextLine],
    oldLines: [TextLine]
  ) -> Bool {
    zip(candidateLines, oldLines).allSatisfy { candidate, old in
      old.lineEnding.isEmpty || !candidate.lineEnding.isEmpty
    }
  }

  private static func replacementRange(
    for candidateLines: [TextLine],
    oldTextEndsWithLineEnding: Bool
  ) -> Range<String.Index> {
    let first = candidateLines[0]
    let last = candidateLines[candidateLines.count - 1]
    return first.fullRange
      .lowerBound..<(oldTextEndsWithLineEnding
      ? last.fullRange.upperBound : last.bodyRange.upperBound)
  }

  private static func trimTrailingWhitespace(_ text: String) -> String {
    var result = text
    while let last = result.last, last == " " || last == "\t" {
      result.removeLast()
    }
    return result
  }

  private static func deindent(_ lines: [String]) -> [String] {
    let indent = commonIndent(in: lines)
    return lines.map { line in
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
        line.hasPrefix(indent)
      else {
        return line
      }
      return String(line.dropFirst(indent.count))
    }
  }

  private static func commonIndent(in lines: [String]) -> String {
    let indents = lines.compactMap { line -> String? in
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
        return nil
      }
      return String(line.prefix { $0 == " " || $0 == "\t" })
    }

    guard var common = indents.first else {
      return ""
    }

    for indent in indents.dropFirst() {
      while !indent.hasPrefix(common), !common.isEmpty {
        common.removeLast()
      }
    }

    return common
  }

  private static func reindent(
    _ text: String,
    from oldIndent: String,
    to newIndent: String,
    matchingLineEndingsOf candidateLines: [TextLine]
  ) -> String {
    let lineEndingText = candidateLines.map(\.fullText).joined()
    let normalizedText = normalizeLineEndings(text)
    let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let reindented = lines.map { line in
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
        return line
      }
      if !oldIndent.isEmpty, line.hasPrefix(oldIndent) {
        return newIndent + line.dropFirst(oldIndent.count)
      }
      return newIndent + line
    }.joined(separator: "\n")
    return convertLineEndings(reindented, toMatch: lineEndingText)
  }

  private static func reindentByLine(
    _ text: String,
    from oldLines: [TextLine],
    to candidateLines: [TextLine]
  ) -> String {
    let lineEndingText = candidateLines.map(\.fullText).joined()
    let normalizedText = normalizeLineEndings(text)
    let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let reindented = lines.enumerated().map { index, line in
      guard index < oldLines.count, index < candidateLines.count,
        !line.trimmingCharacters(in: .whitespaces).isEmpty
      else {
        return line
      }

      let oldIndent = leadingWhitespace(in: oldLines[index].body)
      let candidateIndent = leadingWhitespace(in: candidateLines[index].body)
      if !oldIndent.isEmpty, line.hasPrefix(oldIndent) {
        return candidateIndent + line.dropFirst(oldIndent.count)
      }
      return candidateIndent + line.drop { $0 == " " || $0 == "\t" }
    }.joined(separator: "\n")
    return convertLineEndings(reindented, toMatch: lineEndingText)
  }

  private static func leadingWhitespace(in text: String) -> String {
    String(text.prefix { $0 == " " || $0 == "\t" })
  }

  private static func normalizeLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  private static func convertLineEndings(_ text: String, toMatch referenceText: String) -> String {
    let lineEnding = referenceText.contains("\r\n") ? "\r\n" : "\n"
    let normalizedText = normalizeLineEndings(text)
    guard lineEnding == "\r\n" else {
      return normalizedText
    }
    return normalizedText.replacingOccurrences(of: "\n", with: "\r\n")
  }
}

nonisolated private struct ValidatedEdit {
  public let path: String
  public let resolvedURL: URL
  public let oldText: String
  public let newText: String
  public let matchStrategy: EditMatchStrategy
  public let updatedContent: String
}

nonisolated private struct EditMatch {
  public let range: Range<String.Index>
  public let replacementText: String
  public let strategy: EditMatchStrategy
}

nonisolated private struct TextLine {
  public let body: String
  public let lineEnding: String
  public let bodyRange: Range<String.Index>
  public let fullRange: Range<String.Index>
  public let fullText: String
}

/// Tokenizes the edit's `oldText` and `content` into lines exactly once and shares the
/// result across every fuzzy match strategy. Previously each line-window strategy called
/// `lineSegments(in: content)`, re-tokenizing the whole file up to three times per edit.
/// The properties are lazy, so the exact/normalized strategies — and thus the common
/// byte-exact match — never pay to tokenize. Confined to a single synchronous
/// `validatedMatch` call, so the mutable cache is never shared across threads.
nonisolated private final class TokenizedEdit {
  private let oldText: String
  private let content: String
  private var cachedOldLines: [TextLine]?
  private var cachedContentLines: [TextLine]?

  init(oldText: String, content: String) {
    self.oldText = oldText
    self.content = content
  }

  var oldLines: [TextLine] {
    if let cachedOldLines { return cachedOldLines }
    let lines = EditFileToolExecutor.lineSegments(in: oldText)
    cachedOldLines = lines
    return lines
  }

  var contentLines: [TextLine] {
    if let cachedContentLines { return cachedContentLines }
    let lines = EditFileToolExecutor.lineSegments(in: content)
    cachedContentLines = lines
    return lines
  }
}

nonisolated private struct IndexedNormalizedText {
  public let text: String
  private let lowerBounds: [String.Index]
  private let upperBounds: [String.Index]

  public init(lineEndingNormalizing source: String) {
    var text = ""
    var lowerBounds: [String.Index] = []
    var upperBounds: [String.Index] = []
    var index = source.startIndex

    while index < source.endIndex {
      let nextIndex = source.index(after: index)
      let character = String(source[index])
      if character == "\r\n" {
        text.append("\n")
        lowerBounds.append(index)
        upperBounds.append(nextIndex)
        index = nextIndex
      } else if character == "\r", nextIndex < source.endIndex, source[nextIndex] == "\n" {
        let afterLineEnding = source.index(after: nextIndex)
        text.append("\n")
        lowerBounds.append(index)
        upperBounds.append(afterLineEnding)
        index = afterLineEnding
      } else if source[index] == "\r" {
        text.append("\n")
        lowerBounds.append(index)
        upperBounds.append(nextIndex)
        index = nextIndex
      } else {
        text.append(source[index])
        lowerBounds.append(index)
        upperBounds.append(nextIndex)
        index = nextIndex
      }
    }

    self.text = text
    self.lowerBounds = lowerBounds
    self.upperBounds = upperBounds
  }

  /// Finds up to `maxCount` occurrences of `needle` in the normalized text and maps each
  /// back to a range in the original source. Character offsets are accumulated as the scan
  /// advances, so each match costs O(1) to map and the whole search is O(n) — the previous
  /// `sourceRange(for:)` recomputed `String.distance(from: startIndex,…)` per lookup, which
  /// is O(n) every time on a `String`'s bidirectional index.
  public func sourceRanges(matching needle: String, maxCount: Int) -> [Range<String.Index>] {
    var results: [Range<String.Index>] = []
    var searchStart = text.startIndex
    var searchStartOffset = 0

    while results.count < maxCount,
      let matchRange = text.range(of: needle, range: searchStart..<text.endIndex)
    {
      let lowerOffset =
        searchStartOffset + text.distance(from: searchStart, to: matchRange.lowerBound)
      let upperOffset =
        lowerOffset + text.distance(from: matchRange.lowerBound, to: matchRange.upperBound)

      if lowerOffset >= 0, upperOffset > lowerOffset,
        lowerOffset < lowerBounds.count,
        upperOffset - 1 < upperBounds.count
      {
        results.append(lowerBounds[lowerOffset]..<upperBounds[upperOffset - 1])
      }

      searchStart = text.index(after: matchRange.lowerBound)
      searchStartOffset = lowerOffset + 1
    }

    return results
  }
}

public enum EditFileValidationError: LocalizedError {
  case emptyOldText
  case identicalReplacement
  case nonUTF8
  case oldTextNotFound
  case ambiguousOldText

  public var errorDescription: String? {
    switch self {
    case .emptyOldText:
      "edit_file old_text must not be empty."
    case .identicalReplacement:
      "edit_file new_text must be different from old_text."
    case .nonUTF8:
      "File is not valid UTF-8 text."
    case .oldTextNotFound:
      "edit_file old_text was not found."
    case .ambiguousOldText:
      "edit_file old_text matched more than once."
    }
  }
}
