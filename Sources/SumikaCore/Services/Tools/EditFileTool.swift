import Foundation

package struct EditFileInput: Codable, Equatable, Sendable {
  package let path: String
  package let oldText: String
  package let newText: String

  private enum CodingKeys: String, CodingKey {
    case path
    case oldText = "old_text"
    case newText = "new_text"
  }
}

package struct AppliedEditLineRange: Codable, Equatable, Sendable {
  package let startLine: Int
  package let lineCount: Int

  package init(startLine: Int, lineCount: Int) {
    self.startLine = startLine
    self.lineCount = lineCount
  }
}

package struct AppliedEditReceipt: Codable, Equatable, Sendable {
  package let path: WorkspaceRelativePath
  package let matchStrategy: EditMatchStrategy
  package let oldRange: AppliedEditLineRange
  package let newRange: AppliedEditLineRange
  package let diff: ToolTextOutput

  package init(
    path: WorkspaceRelativePath,
    matchStrategy: EditMatchStrategy,
    oldRange: AppliedEditLineRange,
    newRange: AppliedEditLineRange,
    diff: ToolTextOutput
  ) {
    self.path = path
    self.matchStrategy = matchStrategy
    self.oldRange = oldRange
    self.newRange = newRange
    self.diff = diff
  }

  package var additions: Int {
    newRange.lineCount
  }

  package var deletions: Int {
    oldRange.lineCount
  }
}

package enum EditFileResult: Codable, Equatable, Sendable {
  case success(receipt: AppliedEditReceipt)
  case legacySuccess(
    path: WorkspaceRelativePath,
    diff: String?,
    matchStrategy: EditMatchStrategy
  )
  case oldTextNotFound(
    path: WorkspaceRelativePath,
    currentContent: ToolTextOutput?,
    recovery: RecoveryHint
  )
  case multipleMatches(path: WorkspaceRelativePath, matchCount: Int, recovery: RecoveryHint)
  case unchanged(path: WorkspaceRelativePath)
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)

  private enum EnvelopeKey: String, CodingKey {
    case success
  }

  private enum SuccessKey: String, CodingKey {
    case receipt
  }

  private enum LegacyRepresentation: Codable {
    case success(path: WorkspaceRelativePath, diff: String?, matchStrategy: EditMatchStrategy)
    case oldTextNotFound(
      path: WorkspaceRelativePath,
      currentContent: ToolTextOutput?,
      recovery: RecoveryHint
    )
    case multipleMatches(path: WorkspaceRelativePath, matchCount: Int, recovery: RecoveryHint)
    case unchanged(path: WorkspaceRelativePath)
    case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)
  }

  package init(from decoder: Decoder) throws {
    let envelope = try decoder.container(keyedBy: EnvelopeKey.self)
    if envelope.contains(.success) {
      let success = try envelope.nestedContainer(keyedBy: SuccessKey.self, forKey: .success)
      if success.contains(.receipt) {
        self = .success(
          receipt: try success.decode(AppliedEditReceipt.self, forKey: .receipt)
        )
        return
      }
    }

    switch try LegacyRepresentation(from: decoder) {
    case .success(let path, let diff, let matchStrategy):
      self = .legacySuccess(path: path, diff: diff, matchStrategy: matchStrategy)
    case .oldTextNotFound(let path, let currentContent, let recovery):
      self = .oldTextNotFound(
        path: path,
        currentContent: currentContent,
        recovery: recovery
      )
    case .multipleMatches(let path, let matchCount, let recovery):
      self = .multipleMatches(path: path, matchCount: matchCount, recovery: recovery)
    case .unchanged(let path):
      self = .unchanged(path: path)
    case .failed(let path, let reason):
      self = .failed(path: path, reason: reason)
    }
  }

  package func encode(to encoder: Encoder) throws {
    switch self {
    case .success(let receipt):
      var envelope = encoder.container(keyedBy: EnvelopeKey.self)
      var success = envelope.nestedContainer(keyedBy: SuccessKey.self, forKey: .success)
      try success.encode(receipt, forKey: .receipt)
    case .legacySuccess(let path, let diff, let matchStrategy):
      try LegacyRepresentation.success(
        path: path,
        diff: diff,
        matchStrategy: matchStrategy
      ).encode(to: encoder)
    case .oldTextNotFound(let path, let currentContent, let recovery):
      try LegacyRepresentation.oldTextNotFound(
        path: path,
        currentContent: currentContent,
        recovery: recovery
      ).encode(to: encoder)
    case .multipleMatches(let path, let matchCount, let recovery):
      try LegacyRepresentation.multipleMatches(
        path: path,
        matchCount: matchCount,
        recovery: recovery
      ).encode(to: encoder)
    case .unchanged(let path):
      try LegacyRepresentation.unchanged(path: path).encode(to: encoder)
    case .failed(let path, let reason):
      try LegacyRepresentation.failed(path: path, reason: reason).encode(to: encoder)
    }
  }
}

package enum EditMatchStrategy: String, Codable, Equatable, Sendable {
  case exact
  case normalizedLineEndings
  case trimTrailingWhitespace
  case indentationFlexible
  case lineTrimmedBlock
}

nonisolated extension EditFileResult {
  var preview: ToolResultPreview {
    switch self {
    case .success(let receipt):
      return ToolResultPreview(
        text: "Edited \(receipt.path.rawValue).",
        affectedPaths: [receipt.path.rawValue]
      )
    case .legacySuccess(let path, let diff, let matchStrategy):
      let strategyText =
        matchStrategy == .exact ? "" : " using \(matchStrategy.rawValue) match strategy"
      return ToolResultPreview(
        text: diff ?? "Edited \(path.rawValue)\(strategyText).",
        affectedPaths: [path.rawValue]
      )
    case .oldTextNotFound(let path, let currentContent, let recovery):
      let contentText =
        currentContent.map { output in
          "\n\nCurrent file excerpt:\n\(output.text)"
        } ?? ""
      return ToolResultPreview(
        status: .failed,
        text:
          "edit_file failed: old_text was not found in \(path.rawValue).\(contentText)\n\n\(recovery.message)",
        truncated: currentContent?.truncated ?? false,
        redacted: currentContent?.redacted ?? false,
        affectedPaths: [path.rawValue],
        resultPayload: .editFile(self)
      )
    case .multipleMatches(let path, let matchCount, let recovery):
      return ToolResultPreview(
        status: .failed,
        text:
          "edit_file failed: old_text matched more than once in \(path.rawValue) (\(matchCount) matches). \(recovery.message)",
        affectedPaths: [path.rawValue]
      )
    case .unchanged(let path):
      return ToolResultPreview(
        text: "No changes were needed for \(path.rawValue).",
        affectedPaths: [path.rawValue]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus,
        text: reason.message,
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension ToolDefinition {
  package static let editFile = ToolDefinition(
    name: .editFile,
    description:
      "Replace one unique text span in an existing file. Read first unless the current content is already in context. Multiple edit_file calls may target non-overlapping spans of one current file snapshot; they are approved and applied atomically per file. Do not combine them with write_file for that file.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative path to the existing file.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "old_text",
        description: "Exact current text to replace; it must occur exactly once.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
      ToolParameterDefinition(
        name: "new_text",
        description: "Replacement text. Use an empty string to delete the matched span.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
    ],
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )
}

nonisolated struct AppliedEditReceiptPolicy: Equatable, Sendable {
  let maxChangedLines: Int
  let maxBytes: Int

  init(maxChangedLines: Int = 120, maxBytes: Int = 6 * 1024) {
    precondition(maxChangedLines > 0)
    precondition(maxBytes > 0)
    self.maxChangedLines = maxChangedLines
    self.maxBytes = maxBytes
  }

  static let production = AppliedEditReceiptPolicy()
  static let unbounded = AppliedEditReceiptPolicy(maxChangedLines: .max, maxBytes: .max)
}

enum EditFileGroupPreparation {
  case ready(ToolResultPreview)
  case failed([ToolResultPreview])
}

enum EditFileGroupExecution {
  case completed([ToolResultPayload])
  case failed([ToolResultPayload])
  case cancelled
}

struct EditFileToolExecutor: TypedToolExecutor {
  private let receiptPolicy: AppliedEditReceiptPolicy

  init(receiptPolicy: AppliedEditReceiptPolicy = .production) {
    self.receiptPolicy = receiptPolicy
  }

  static let codec = ToolCodec<EditFileInput>(
    definition: ToolDefinition.editFile,
    makePayload: ToolCallPayload.editFile,
    extractInput: { payload in
      guard case .editFile(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.editFile.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.requireNonEmptyPath(input.path)
      guard !input.oldText.isEmpty else {
        throw InvalidToolCallReason.emptyOldText
      }
    }
  )

  func evaluatePermission(
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

  func previewApproval(_ input: EditFileInput, context: ToolContext) async
    -> ToolResultPreview?
  {
    switch prepareApprovalGroup([input], context: context) {
    case .ready(let preview):
      return preview
    case .failed(let previews):
      return previews.first
    }
  }

  func run(_ input: EditFileInput, context: ToolContext) async -> ToolResultPayload {
    switch runGroup([input], context: context) {
    case .completed(let payloads), .failed(let payloads):
      return payloads[0]
    case .cancelled:
      return .editFile(
        .failed(
          path: WorkspaceRelativePath(rawValue: input.path),
          reason: .executionError("edit_file was cancelled before writing.")
        ))
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

  fileprivate static func validatedMatch(
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

extension EditFileToolExecutor {
  func prepareApprovalGroup(
    _ inputs: [EditFileInput],
    context: ToolContext
  ) -> EditFileGroupPreparation {
    precondition(!inputs.isEmpty)
    do {
      let preview = try EditFileTransaction(receiptPolicy: receiptPolicy).preview(
        inputs,
        context: context
      )
      return .ready(preview)
    } catch let failure as EditFileTransactionFailure {
      return .failed(failurePreviews(for: inputs, context: context, failure: failure))
    } catch {
      let failure = EditFileTransactionFailure(inputIndex: 0, resolvedURL: nil, cause: error)
      return .failed(failurePreviews(for: inputs, context: context, failure: failure))
    }
  }

  func runGroup(
    _ inputs: [EditFileInput],
    context: ToolContext
  ) -> EditFileGroupExecution {
    precondition(!inputs.isEmpty)
    do {
      let receipts = try EditFileTransaction(receiptPolicy: receiptPolicy).commit(
        inputs,
        context: context
      )
      return .completed(receipts.map { .editFile(.success(receipt: $0)) })
    } catch is CancellationError {
      return .cancelled
    } catch let failure as EditFileTransactionFailure {
      return .failed(failurePayloads(for: inputs, context: context, failure: failure))
    } catch {
      let failure = EditFileTransactionFailure(inputIndex: 0, resolvedURL: nil, cause: error)
      return .failed(failurePayloads(for: inputs, context: context, failure: failure))
    }
  }

  private func failurePreviews(
    for inputs: [EditFileInput],
    context: ToolContext,
    failure: EditFileTransactionFailure
  ) -> [ToolResultPreview] {
    inputs.enumerated().map { index, input in
      if index == failure.inputIndex {
        return failurePreview(
          for: input,
          context: context,
          resolvedURL: failure.resolvedURL,
          error: failure.cause
        )
      }
      let path =
        ToolResultFailureMapper.relativePath(
          for: input.path,
          resolvedURL: failure.resolvedURL,
          workspace: context.workspace
        ) ?? WorkspaceRelativePath(rawValue: input.path)
      return ToolResultPreview(
        status: .failed,
        text: atomicGroupFailureMessage(cause: failure.cause),
        affectedPaths: [path.rawValue]
      )
    }
  }

  private func failurePayloads(
    for inputs: [EditFileInput],
    context: ToolContext,
    failure: EditFileTransactionFailure
  ) -> [ToolResultPayload] {
    inputs.enumerated().map { index, input in
      guard index == failure.inputIndex else {
        let path =
          ToolResultFailureMapper.relativePath(
            for: input.path,
            resolvedURL: failure.resolvedURL,
            workspace: context.workspace
          ) ?? WorkspaceRelativePath(rawValue: input.path)
        return .editFile(
          .failed(
            path: path,
            reason: .executionError(atomicGroupFailureMessage(cause: failure.cause))
          ))
      }
      return failurePayload(
        for: input,
        context: context,
        resolvedURL: failure.resolvedURL,
        error: failure.cause
      )
    }
  }

  private func failurePayload(
    for input: EditFileInput,
    context: ToolContext,
    resolvedURL: URL?,
    error: Error
  ) -> ToolResultPayload {
    if case EditFileValidationError.oldTextNotFound = error {
      return context.workspace.withSecurityScopedAccess {
        oldTextNotFoundResult(input, context: context, resolvedURL: resolvedURL)
      }
    }
    if case EditFileValidationError.ambiguousOldText = error {
      let path =
        ToolResultFailureMapper.relativePath(
          for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
        ?? WorkspaceRelativePath(rawValue: input.path)
      return .editFile(
        .multipleMatches(
          path: path,
          matchCount: 2,
          recovery: .retryWithMoreContext(path: path)
        ))
    }
    if case EditFileValidationError.identicalReplacement = error {
      let path =
        ToolResultFailureMapper.relativePath(
          for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
        ?? WorkspaceRelativePath(rawValue: input.path)
      return .editFile(.unchanged(path: path))
    }

    return .editFile(
      .failed(
        path: ToolResultFailureMapper.relativePath(
          for: input.path, resolvedURL: resolvedURL, workspace: context.workspace),
        reason: ToolResultFailureMapper.isFileNotFound(error)
          ? ToolResultFailureMapper.missingFileReason(
            for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
          : ToolResultFailureMapper.reason(from: error)
      ))
  }

  private func atomicGroupFailureMessage(cause: Error) -> String {
    "Atomic edit_file group was not applied: \(cause.localizedDescription)"
  }
}

nonisolated struct AppliedEditReceiptBuilder {
  let policy: AppliedEditReceiptPolicy

  func build(
    path: WorkspaceRelativePath,
    originalContent: String,
    matchedRange: Range<String.Index>,
    replacementText: String,
    matchStrategy: EditMatchStrategy,
    newStartLineOffset: Int = 0
  ) -> AppliedEditReceipt {
    let oldStart = lineStart(in: originalContent, at: matchedRange.lowerBound)
    var oldEnd = nextLineBoundary(in: originalContent, atOrAfter: matchedRange.upperBound)
    let updatedContent =
      String(originalContent[..<matchedRange.lowerBound])
      + replacementText
      + String(originalContent[matchedRange.upperBound...])

    var newStart = index(
      in: updatedContent,
      utf8Offset: originalContent[..<oldStart].utf8.count
    )
    var newEnd = mappedNewEnd(
      in: updatedContent,
      originalContent: originalContent,
      matchedRange: matchedRange,
      replacementText: replacementText,
      oldEnd: oldEnd
    )

    if !isLineBoundary(in: updatedContent, at: newEnd), oldEnd < originalContent.endIndex {
      oldEnd = nextLineBoundary(
        in: originalContent,
        atOrAfter: originalContent.index(after: oldEnd)
      )
      newEnd = mappedNewEnd(
        in: updatedContent,
        originalContent: originalContent,
        matchedRange: matchedRange,
        replacementText: replacementText,
        oldEnd: oldEnd
      )
    }

    if newStart > newEnd {
      newStart = newEnd
    }

    let oldBlock = String(originalContent[oldStart..<oldEnd])
    let newBlock = String(updatedContent[newStart..<newEnd])
    let oldLines = EditFileToolExecutor.lineSegments(in: oldBlock)
    let newLines = EditFileToolExecutor.lineSegments(in: newBlock)
    let startLine =
      EditFileToolExecutor.lineSegments(
        in: String(originalContent[..<oldStart])
      ).count + 1
    let oldRange = AppliedEditLineRange(startLine: startLine, lineCount: oldLines.count)
    let newRange = AppliedEditLineRange(
      startLine: newLines.isEmpty
        ? max(0, startLine - 1 + newStartLineOffset)
        : max(0, startLine + newStartLineOffset),
      lineCount: newLines.count
    )
    let diff = renderDiff(
      path: path,
      oldRange: oldRange,
      newRange: newRange,
      oldLines: oldLines,
      newLines: newLines
    )

    return AppliedEditReceipt(
      path: path,
      matchStrategy: matchStrategy,
      oldRange: oldRange,
      newRange: newRange,
      diff: diff
    )
  }

  private func renderDiff(
    path: WorkspaceRelativePath,
    oldRange: AppliedEditLineRange,
    newRange: AppliedEditLineRange,
    oldLines: [TextLine],
    newLines: [TextLine]
  ) -> ToolTextOutput {
    let headers = [
      "--- \(diffPath(path, prefix: "a/"))",
      "+++ \(diffPath(path, prefix: "b/"))",
      "@@ -\(oldRange.startLine),\(oldRange.lineCount) +\(newRange.startLine),\(newRange.lineCount) @@",
    ]
    let changedLines =
      oldLines.map { renderedChangedLine(prefix: "-", line: $0) }
      + newLines.map { renderedChangedLine(prefix: "+", line: $0) }
    let fullText = render(headers: headers, changedLines: changedLines, omittedCount: 0)

    guard
      changedLines.count > policy.maxChangedLines
        || fullText.utf8.count > policy.maxBytes
    else {
      return ToolTextOutput(text: fullText)
    }

    var visibleCount = min(changedLines.count, policy.maxChangedLines)
    if visibleCount == changedLines.count {
      visibleCount -= 1
    }

    while visibleCount >= 0 {
      let visible = headTail(changedLines, count: visibleCount)
      let candidate = render(
        headers: headers,
        changedLines: visible,
        omittedCount: changedLines.count - visibleCount
      )
      if candidate.utf8.count <= policy.maxBytes {
        return ToolTextOutput(text: candidate, truncated: true)
      }
      visibleCount -= 1
    }

    let markerOnly = render(
      headers: headers,
      changedLines: [],
      omittedCount: changedLines.count
    )
    return ToolTextOutput(
      text: utf8Prefix(markerOnly, maxBytes: policy.maxBytes),
      truncated: true
    )
  }

  private func renderedChangedLine(prefix: String, line: TextLine) -> [String] {
    var rendered = ["\(prefix)\(line.body)"]
    if line.lineEnding.isEmpty {
      rendered.append("\\ No newline at end of file")
    }
    return rendered
  }

  private func render(
    headers: [String],
    changedLines: [[String]],
    omittedCount: Int
  ) -> String {
    var lines = headers
    if omittedCount == 0 {
      lines.append(contentsOf: changedLines.flatMap(\.self))
    } else {
      let headCount = (changedLines.count + 1) / 2
      lines.append(contentsOf: changedLines.prefix(headCount).flatMap(\.self))
      lines.append("[\(omittedCount) changed lines omitted]")
      lines.append(contentsOf: changedLines.dropFirst(headCount).flatMap(\.self))
    }
    return lines.joined(separator: "\n")
  }

  private func headTail<T>(_ values: [T], count: Int) -> [T] {
    guard count > 0 else {
      return []
    }
    let headCount = (count + 1) / 2
    let tailCount = count / 2
    return Array(values.prefix(headCount)) + Array(values.suffix(tailCount))
  }

  private func diffPath(_ path: WorkspaceRelativePath, prefix: String) -> String {
    let fullPath = prefix + path.rawValue
    guard
      fullPath.contains(where: {
        $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\\" || $0 == "\""
          || $0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
      })
    else {
      return fullPath
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard
      let data = try? encoder.encode(fullPath),
      let encoded = String(data: data, encoding: .utf8)
    else {
      return "\"\(fullPath)\""
    }
    return encoded
  }

  private func lineStart(in text: String, at index: String.Index) -> String.Index {
    var current = index
    while current > text.startIndex {
      let previous = text.index(before: current)
      if isLineEnding(text[previous]) {
        break
      }
      current = previous
    }
    return current
  }

  private func nextLineBoundary(
    in text: String,
    atOrAfter index: String.Index
  ) -> String.Index {
    if isLineBoundary(in: text, at: index) {
      return index
    }

    var current = index
    while current < text.endIndex {
      if isLineEnding(text[current]) {
        return text.index(after: current)
      }
      current = text.index(after: current)
    }
    return text.endIndex
  }

  private func isLineBoundary(in text: String, at index: String.Index) -> Bool {
    guard index > text.startIndex, index < text.endIndex else {
      return true
    }
    return isLineEnding(text[text.index(before: index)])
  }

  private func isLineEnding(_ character: Character) -> Bool {
    character == "\n" || character == "\r" || String(character) == "\r\n"
  }

  private func mappedNewEnd(
    in updatedContent: String,
    originalContent: String,
    matchedRange: Range<String.Index>,
    replacementText: String,
    oldEnd: String.Index
  ) -> String.Index {
    let offset =
      originalContent[..<matchedRange.lowerBound].utf8.count
      + replacementText.utf8.count
      + originalContent[matchedRange.upperBound..<oldEnd].utf8.count
    return index(in: updatedContent, utf8Offset: offset)
  }

  private func index(in text: String, utf8Offset: Int) -> String.Index {
    let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Offset)
    return String.Index(utf8Index, within: text) ?? text.endIndex
  }

  private func utf8Prefix(_ text: String, maxBytes: Int) -> String {
    var byteCount = 0
    var result = ""
    for character in text {
      let characterBytes = String(character).utf8.count
      guard byteCount + characterBytes <= maxBytes else {
        break
      }
      result.append(character)
      byteCount += characterBytes
    }
    return result
  }
}

nonisolated private struct EditFileTransaction {
  let receiptPolicy: AppliedEditReceiptPolicy

  func preview(
    _ inputs: [EditFileInput],
    context: ToolContext
  ) throws -> ToolResultPreview {
    try context.workspace.withSecurityScopedAccess {
      let group = try validatedGroup(inputs, context: context)
      return ToolResultPreview(
        text: combinedPreviewDiff(for: group),
        affectedPaths: [group.path.rawValue]
      )
    }
  }

  func commit(
    _ inputs: [EditFileInput],
    context: ToolContext
  ) throws -> [AppliedEditReceipt] {
    try context.workspace.withSecurityScopedAccess {
      let group = try validatedGroup(inputs, context: context)
      let receiptBuilder = AppliedEditReceiptBuilder(policy: receiptPolicy)
      var cumulativeLineOffset = 0
      var indexedReceipts: [(inputIndex: Int, receipt: AppliedEditReceipt)] = []
      for edit in group.edits.sorted(by: { $0.lowerUTF8Offset < $1.lowerUTF8Offset }) {
        let receipt = receiptBuilder.build(
          path: group.path,
          originalContent: group.originalContent,
          matchedRange: edit.range,
          replacementText: edit.replacementText,
          matchStrategy: edit.matchStrategy,
          newStartLineOffset: cumulativeLineOffset
        )
        indexedReceipts.append((edit.inputIndex, receipt))
        cumulativeLineOffset += receipt.newRange.lineCount - receipt.oldRange.lineCount
      }
      let receipts = indexedReceipts.sorted { $0.inputIndex < $1.inputIndex }.map(\.receipt)
      try Task.checkCancellation()
      try group.updatedContent.write(
        to: group.resolvedURL,
        atomically: true,
        encoding: .utf8
      )
      return receipts
    }
  }

  private func validatedGroup(
    _ inputs: [EditFileInput],
    context: ToolContext
  ) throws -> ValidatedEditGroup {
    precondition(!inputs.isEmpty)
    var resolvedURLs: [URL] = []
    for (index, input) in inputs.enumerated() {
      do {
        resolvedURLs.append(try context.workspace.resolveAllowedPath(input.path))
      } catch {
        throw EditFileTransactionFailure(
          inputIndex: index,
          resolvedURL: nil,
          cause: error
        )
      }
    }

    let resolvedURL = resolvedURLs[0]
    let normalizedPath = Workspace.normalizedPath(for: resolvedURL)
    for (index, candidateURL) in resolvedURLs.enumerated()
    where Workspace.normalizedPath(for: candidateURL) != normalizedPath {
      throw EditFileTransactionFailure(
        inputIndex: index,
        resolvedURL: candidateURL,
        cause: EditFileValidationError.mixedPaths
      )
    }

    let content: String
    do {
      let data = try Data(contentsOf: resolvedURL)
      guard let decoded = String(data: data, encoding: .utf8) else {
        throw EditFileValidationError.nonUTF8
      }
      content = decoded
    } catch {
      throw EditFileTransactionFailure(inputIndex: 0, resolvedURL: resolvedURL, cause: error)
    }

    var edits: [ValidatedTransactionEdit] = []
    for (index, input) in inputs.enumerated() {
      do {
        guard !input.oldText.isEmpty else {
          throw EditFileValidationError.emptyOldText
        }
        guard input.oldText != input.newText else {
          throw EditFileValidationError.identicalReplacement
        }
        let match = try EditFileToolExecutor.validatedMatch(
          oldText: input.oldText,
          newText: input.newText,
          content: content
        )
        edits.append(
          ValidatedTransactionEdit(
            inputIndex: index,
            range: match.range,
            lowerUTF8Offset: content[..<match.range.lowerBound].utf8.count,
            upperUTF8Offset: content[..<match.range.upperBound].utf8.count,
            replacementText: match.replacementText,
            matchStrategy: match.strategy
          ))
      } catch {
        throw EditFileTransactionFailure(
          inputIndex: index,
          resolvedURL: resolvedURL,
          cause: error
        )
      }
    }

    let orderedEdits = edits.sorted { lhs, rhs in
      lhs.lowerUTF8Offset < rhs.lowerUTF8Offset
    }
    for pairIndex in orderedEdits.indices.dropFirst() {
      let previous = orderedEdits[orderedEdits.index(before: pairIndex)]
      let current = orderedEdits[pairIndex]
      guard previous.upperUTF8Offset <= current.lowerUTF8Offset else {
        throw EditFileTransactionFailure(
          inputIndex: current.inputIndex,
          resolvedURL: resolvedURL,
          cause: EditFileValidationError.overlappingEdits
        )
      }
    }

    return ValidatedEditGroup(
      path: context.workspace.relativePath(for: resolvedURL),
      resolvedURL: resolvedURL,
      originalContent: content,
      edits: edits,
      updatedContent: applying(edits, to: content)
    )
  }

  private func applying(
    _ edits: [ValidatedTransactionEdit],
    to content: String,
    baseUTF8Offset: Int = 0
  ) -> String {
    var updatedContent = content
    for edit in edits.sorted(by: { $0.lowerUTF8Offset > $1.lowerUTF8Offset }) {
      let lowerOffset = edit.lowerUTF8Offset - baseUTF8Offset
      let upperOffset = edit.upperUTF8Offset - baseUTF8Offset
      let lowerUTF8Index = updatedContent.utf8.index(
        updatedContent.utf8.startIndex,
        offsetBy: lowerOffset
      )
      let upperUTF8Index = updatedContent.utf8.index(
        updatedContent.utf8.startIndex,
        offsetBy: upperOffset
      )
      guard
        let lowerIndex = String.Index(lowerUTF8Index, within: updatedContent),
        let upperIndex = String.Index(upperUTF8Index, within: updatedContent)
      else {
        preconditionFailure("Validated edit offsets must remain UTF-8 boundaries.")
      }
      updatedContent.replaceSubrange(lowerIndex..<upperIndex, with: edit.replacementText)
    }
    return updatedContent
  }

  private func combinedPreviewDiff(for group: ValidatedEditGroup) -> String {
    let unboundedBuilder = AppliedEditReceiptBuilder(policy: .unbounded)
    let editsWithRanges = group.edits.sorted { lhs, rhs in
      lhs.lowerUTF8Offset < rhs.lowerUTF8Offset
    }.map { edit in
      let receipt = unboundedBuilder.build(
        path: group.path,
        originalContent: group.originalContent,
        matchedRange: edit.range,
        replacementText: edit.replacementText,
        matchStrategy: edit.matchStrategy
      )
      return (edit, receipt.oldRange)
    }

    var clusters: [[ValidatedTransactionEdit]] = []
    var clusterLineEnd = 0
    for (edit, oldRange) in editsWithRanges {
      let lineEnd = oldRange.startLine + oldRange.lineCount
      if let lastIndex = clusters.indices.last, oldRange.startLine < clusterLineEnd {
        clusters[lastIndex].append(edit)
        clusterLineEnd = max(clusterLineEnd, lineEnd)
      } else {
        clusters.append([edit])
        clusterLineEnd = lineEnd
      }
    }

    var cumulativeLineOffset = 0
    var hunkDiffs: [String] = []
    for cluster in clusters {
      guard
        let lowerOffset = cluster.map(\.lowerUTF8Offset).min(),
        let upperOffset = cluster.map(\.upperUTF8Offset).max()
      else {
        continue
      }
      let lowerIndex = index(in: group.originalContent, utf8Offset: lowerOffset)
      let upperIndex = index(in: group.originalContent, utf8Offset: upperOffset)
      let originalBlock = String(group.originalContent[lowerIndex..<upperIndex])
      let replacementBlock = applying(
        cluster,
        to: originalBlock,
        baseUTF8Offset: lowerOffset
      )
      let receipt = unboundedBuilder.build(
        path: group.path,
        originalContent: group.originalContent,
        matchedRange: lowerIndex..<upperIndex,
        replacementText: replacementBlock,
        matchStrategy: .exact,
        newStartLineOffset: cumulativeLineOffset
      )
      cumulativeLineOffset += receipt.newRange.lineCount - receipt.oldRange.lineCount
      hunkDiffs.append(receipt.diff.text)
    }

    return hunkDiffs.enumerated().map { index, diff in
      guard index > 0 else {
        return diff
      }
      return diff.split(separator: "\n", omittingEmptySubsequences: false)
        .dropFirst(2)
        .joined(separator: "\n")
    }.joined(separator: "\n")
  }

  private func index(in text: String, utf8Offset: Int) -> String.Index {
    let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Offset)
    guard let index = String.Index(utf8Index, within: text) else {
      preconditionFailure("Validated edit offset must be a UTF-8 boundary.")
    }
    return index
  }
}

nonisolated private struct ValidatedEditGroup {
  let path: WorkspaceRelativePath
  let resolvedURL: URL
  let originalContent: String
  let edits: [ValidatedTransactionEdit]
  let updatedContent: String
}

nonisolated private struct ValidatedTransactionEdit {
  let inputIndex: Int
  let range: Range<String.Index>
  let lowerUTF8Offset: Int
  let upperUTF8Offset: Int
  let replacementText: String
  let matchStrategy: EditMatchStrategy
}

nonisolated private struct EditFileTransactionFailure: Error {
  let inputIndex: Int
  let resolvedURL: URL?
  let cause: Error
}

nonisolated private struct EditMatch {
  package let range: Range<String.Index>
  package let replacementText: String
  package let strategy: EditMatchStrategy
}

nonisolated private struct TextLine {
  package let body: String
  package let lineEnding: String
  package let bodyRange: Range<String.Index>
  package let fullRange: Range<String.Index>
  package let fullText: String
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
  package let text: String
  private let lowerBounds: [String.Index]
  private let upperBounds: [String.Index]

  package init(lineEndingNormalizing source: String) {
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
  package func sourceRanges(matching needle: String, maxCount: Int) -> [Range<String.Index>] {
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

internal enum EditFileValidationError: LocalizedError {
  case emptyOldText
  case identicalReplacement
  case nonUTF8
  case oldTextNotFound
  case ambiguousOldText
  case mixedPaths
  case overlappingEdits

  package var errorDescription: String? {
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
    case .mixedPaths:
      "Atomic edit_file groups must target one normalized workspace path."
    case .overlappingEdits:
      "Atomic edit_file group contains overlapping replacements."
    }
  }
}
