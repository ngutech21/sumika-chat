import Foundation

private enum ReadFileLimits {
  static let maximumLinesPerPage = 500
  static let renderedContentBytesPerPage = 16 * 1024
}

package enum ReadFileTrackedResult: Equatable, Sendable {
  case success
  case unchanged
  case repeatedReadWarning(count: Int)
}

internal actor ReadFileReadTracker {
  private struct ReadStamp: Sendable {
    var page: ReadFilePage
    var consecutiveReadCount: Int
  }

  private var stamps: [ReadKey: ReadStamp] = [:]
  private var lastReadKey: ReadKey?

  package init() {}

  package func record(readKey: ReadKey, page: ReadFilePage) -> ReadFileTrackedResult {
    defer {
      lastReadKey = readKey
    }

    guard var stamp = stamps[readKey], stamp.page == page else {
      stamps[readKey] = ReadStamp(page: page, consecutiveReadCount: 1)
      return .success
    }

    guard lastReadKey == readKey else {
      stamps[readKey] = ReadStamp(page: page, consecutiveReadCount: 1)
      return .success
    }

    stamp.consecutiveReadCount += 1
    stamps[readKey] = stamp

    if stamp.consecutiveReadCount >= 4 {
      return .repeatedReadWarning(count: stamp.consecutiveReadCount)
    }

    return .unchanged
  }
}

package struct ReadFileInput: Codable, Equatable, Sendable {
  package let path: String
  package let offset: Int?
  package let limit: Int?

  private enum CodingKeys: String, CodingKey {
    case path
    case offset
    case limit
  }

  package init(path: String, offset: Int? = nil, limit: Int? = nil) {
    self.path = path
    self.offset = offset
    self.limit = limit
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    offset = try Self.decodeOptionalInt(from: container, forKey: .offset)
    limit = try Self.decodeOptionalInt(from: container, forKey: .limit)

    if let offset, offset < 1 {
      throw ReadFileInputValidationError.invalidOffset
    }

    if let limit, limit < 1 {
      throw ReadFileInputValidationError.invalidLimit
    }
  }

  private static func decodeOptionalInt(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Int? {
    guard container.contains(key) else {
      return nil
    }

    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
      return value
    }

    if let stringValue = try? container.decodeIfPresent(String.self, forKey: key),
      let value = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return value
    }

    switch key {
    case .offset:
      throw ReadFileInputValidationError.invalidOffset
    case .limit:
      throw ReadFileInputValidationError.invalidLimit
    case .path:
      return nil
    }
  }
}

package enum ReadFileTruncationReason: String, Codable, Equatable, Sendable {
  case byteLimit = "byte_limit"
  case lineLimit = "line_limit"
}

package enum ReadFileContinuation: Codable, Equatable, Sendable {
  case endOfFile
  case next(offset: Int, reason: ReadFileTruncationReason)
  case blocked(line: Int, byteCount: Int)

  private enum CodingKeys: String, CodingKey {
    case kind
    case offset
    case reason
    case line
    case byteCount = "byte_count"
  }

  private enum Kind: String, Codable {
    case endOfFile = "end_of_file"
    case next
    case blocked
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .endOfFile:
      self = .endOfFile
    case .next:
      self = .next(
        offset: try container.decode(Int.self, forKey: .offset),
        reason: try container.decode(ReadFileTruncationReason.self, forKey: .reason)
      )
    case .blocked:
      self = .blocked(
        line: try container.decode(Int.self, forKey: .line),
        byteCount: try container.decode(Int.self, forKey: .byteCount)
      )
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .endOfFile:
      try container.encode(Kind.endOfFile, forKey: .kind)
    case .next(let offset, let reason):
      try container.encode(Kind.next, forKey: .kind)
      try container.encode(offset, forKey: .offset)
      try container.encode(reason, forKey: .reason)
    case .blocked(let line, let byteCount):
      try container.encode(Kind.blocked, forKey: .kind)
      try container.encode(line, forKey: .line)
      try container.encode(byteCount, forKey: .byteCount)
    }
  }
}

internal enum ReadFilePageValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalidStartLine(Int)
  case invalidEmptyPage
  case endLineBeforeStart(startLine: Int, endLine: Int)
  case contentLineCountMismatch(expected: Int, actual: Int)
  case continuationLineMismatch(expected: Int, actual: Int)
  case invalidBlockedLineByteCount(Int)

  var errorDescription: String? {
    switch self {
    case .invalidStartLine(let startLine):
      return "ReadFilePage.startLine must be greater than zero; received \(startLine)."
    case .invalidEmptyPage:
      return
        "An empty ReadFilePage must start at line 1, contain no content, and end at EOF."
    case .endLineBeforeStart(let startLine, let endLine):
      return
        "ReadFilePage.endLine \(endLine) must not precede startLine \(startLine)."
    case .contentLineCountMismatch(let expected, let actual):
      return
        "ReadFilePage content must contain \(expected) lines; received \(actual)."
    case .continuationLineMismatch(let expected, let actual):
      return
        "ReadFilePage continuation must point to line \(expected); received \(actual)."
    case .invalidBlockedLineByteCount(let byteCount):
      return
        "ReadFilePage blocked-line byte count must be greater than zero; received \(byteCount)."
    }
  }
}

package struct ReadFilePage: Codable, Equatable, Sendable {
  package let path: WorkspaceRelativePath
  package let startLine: Int
  package let endLine: Int?
  package let content: String
  package let continuation: ReadFileContinuation

  private enum CodingKeys: String, CodingKey {
    case path
    case startLine
    case endLine
    case content
    case continuation
  }

  init(
    path: WorkspaceRelativePath,
    startLine: Int,
    endLine: Int?,
    content: String,
    continuation: ReadFileContinuation
  ) throws {
    try Self.validate(
      startLine: startLine,
      endLine: endLine,
      content: content,
      continuation: continuation
    )
    self.path = path
    self.startLine = startLine
    self.endLine = endLine
    self.content = content
    self.continuation = continuation
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        path: container.decode(WorkspaceRelativePath.self, forKey: .path),
        startLine: container.decode(Int.self, forKey: .startLine),
        endLine: container.decodeIfPresent(Int.self, forKey: .endLine),
        content: container.decode(String.self, forKey: .content),
        continuation: container.decode(ReadFileContinuation.self, forKey: .continuation)
      )
    } catch let error as ReadFilePageValidationError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: error.localizedDescription
        )
      )
    }
  }

  private static func validate(
    startLine: Int,
    endLine: Int?,
    content: String,
    continuation: ReadFileContinuation
  ) throws {
    guard startLine > 0 else {
      throw ReadFilePageValidationError.invalidStartLine(startLine)
    }

    guard let endLine else {
      guard startLine == 1, content.isEmpty, continuation == .endOfFile else {
        throw ReadFilePageValidationError.invalidEmptyPage
      }
      return
    }

    guard endLine >= startLine else {
      throw ReadFilePageValidationError.endLineBeforeStart(
        startLine: startLine,
        endLine: endLine
      )
    }

    let expectedLineCount = endLine - startLine + 1
    let actualLineCount = content.components(separatedBy: "\n").count
    guard actualLineCount == expectedLineCount else {
      throw ReadFilePageValidationError.contentLineCountMismatch(
        expected: expectedLineCount,
        actual: actualLineCount
      )
    }

    switch continuation {
    case .endOfFile:
      return
    case .next(let offset, _):
      try validateContinuationLine(offset, after: endLine)
    case .blocked(let line, let byteCount):
      try validateContinuationLine(line, after: endLine)
      guard byteCount > 0 else {
        throw ReadFilePageValidationError.invalidBlockedLineByteCount(byteCount)
      }
    }
  }

  private static func validateContinuationLine(_ line: Int, after endLine: Int) throws {
    let (expectedLine, overflow) = endLine.addingReportingOverflow(1)
    guard !overflow, line == expectedLine else {
      throw ReadFilePageValidationError.continuationLineMismatch(
        expected: overflow ? endLine : expectedLine,
        actual: line
      )
    }
  }
}

nonisolated extension ReadFilePage {
  static let lineFormat = ToolLineRendering.lineFormat

  static func lineNumberPrefix(for lineNumber: Int) -> String {
    ToolLineRendering.prefix(for: lineNumber)
  }

  var returnedLineCount: Int {
    guard let endLine else {
      return 0
    }
    return endLine - startLine + 1
  }

  var hasMore: Bool {
    continuation != .endOfFile
  }

  var numberedContent: String {
    guard let endLine else {
      return ""
    }
    let lines = content.components(separatedBy: "\n")
    return zip(startLine...endLine, lines)
      .map { lineNumber, line in "\(Self.lineNumberPrefix(for: lineNumber))\(line)" }
      .joined(separator: "\n")
  }

  var textOutput: ToolTextOutput {
    ToolTextOutput(text: numberedContent, truncated: hasMore)
  }
}

package enum ReadFileResult: Codable, Equatable, Sendable {
  case page(ReadFilePage)
  case legacySuccess(path: WorkspaceRelativePath, content: ToolTextOutput)
  case unchanged(path: WorkspaceRelativePath, readKey: ReadKey)
  case repeatedReadWarning(path: WorkspaceRelativePath, count: Int)
  case lineTooLong(path: WorkspaceRelativePath, line: Int, byteCount: Int)
  case offsetOutOfRange(
    path: WorkspaceRelativePath,
    requestedOffset: Int,
    lineCount: Int
  )
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)

  private enum CodingKeys: String, CodingKey {
    case page
    case success
    case unchanged
    case repeatedReadWarning
    case lineTooLong
    case offsetOutOfRange
    case failed
  }

  private struct LegacySuccessPayload: Codable {
    let path: WorkspaceRelativePath
    let content: ToolTextOutput
  }

  private struct UnchangedPayload: Codable {
    let path: WorkspaceRelativePath
    let readKey: ReadKey
  }

  private struct RepeatedReadWarningPayload: Codable {
    let path: WorkspaceRelativePath
    let count: Int
  }

  private struct LineTooLongPayload: Codable {
    let path: WorkspaceRelativePath
    let line: Int
    let byteCount: Int
  }

  private struct OffsetOutOfRangePayload: Codable {
    let path: WorkspaceRelativePath
    let requestedOffset: Int
    let lineCount: Int
  }

  private struct FailedPayload: Codable {
    let path: WorkspaceRelativePath?
    let reason: ToolFailureReason
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.page) {
      self = .page(try container.decode(ReadFilePage.self, forKey: .page))
    } else if container.contains(.success) {
      let payload = try container.decode(LegacySuccessPayload.self, forKey: .success)
      self = .legacySuccess(path: payload.path, content: payload.content)
    } else if container.contains(.unchanged) {
      let payload = try container.decode(UnchangedPayload.self, forKey: .unchanged)
      self = .unchanged(path: payload.path, readKey: payload.readKey)
    } else if container.contains(.repeatedReadWarning) {
      let payload = try container.decode(
        RepeatedReadWarningPayload.self,
        forKey: .repeatedReadWarning
      )
      self = .repeatedReadWarning(path: payload.path, count: payload.count)
    } else if container.contains(.lineTooLong) {
      let payload = try container.decode(LineTooLongPayload.self, forKey: .lineTooLong)
      self = .lineTooLong(path: payload.path, line: payload.line, byteCount: payload.byteCount)
    } else if container.contains(.offsetOutOfRange) {
      let payload = try container.decode(
        OffsetOutOfRangePayload.self,
        forKey: .offsetOutOfRange
      )
      self = .offsetOutOfRange(
        path: payload.path,
        requestedOffset: payload.requestedOffset,
        lineCount: payload.lineCount
      )
    } else {
      let payload = try container.decode(FailedPayload.self, forKey: .failed)
      self = .failed(path: payload.path, reason: payload.reason)
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .page(let page):
      try container.encode(page, forKey: .page)
    case .legacySuccess(let path, let content):
      try container.encode(
        LegacySuccessPayload(path: path, content: content),
        forKey: .success
      )
    case .unchanged(let path, let readKey):
      try container.encode(
        UnchangedPayload(path: path, readKey: readKey),
        forKey: .unchanged
      )
    case .repeatedReadWarning(let path, let count):
      try container.encode(
        RepeatedReadWarningPayload(path: path, count: count),
        forKey: .repeatedReadWarning
      )
    case .lineTooLong(let path, let line, let byteCount):
      try container.encode(
        LineTooLongPayload(path: path, line: line, byteCount: byteCount),
        forKey: .lineTooLong
      )
    case .offsetOutOfRange(let path, let requestedOffset, let lineCount):
      try container.encode(
        OffsetOutOfRangePayload(
          path: path,
          requestedOffset: requestedOffset,
          lineCount: lineCount
        ),
        forKey: .offsetOutOfRange
      )
    case .failed(let path, let reason):
      try container.encode(FailedPayload(path: path, reason: reason), forKey: .failed)
    }
  }
}

nonisolated extension ReadFileResult {
  var preview: ToolResultPreview {
    switch self {
    case .page(let page):
      let content = page.textOutput
      return ToolResultPreview(
        text: content.text,
        truncated: content.truncated,
        redacted: content.redacted,
        affectedPaths: [page.path.rawValue]
      )
    case .legacySuccess(let path, let content):
      return ToolResultPreview(
        text: content.text,
        truncated: content.truncated,
        redacted: content.redacted,
        affectedPaths: [path.rawValue]
      )
    case .unchanged(let path, let readKey):
      let rangeText = readKey.range.map { " for \($0)" } ?? ""
      return ToolResultPreview(
        text:
          "File unchanged since previous read: \(path.rawValue)\(rangeText). Use the existing context instead of reading it again.",
        affectedPaths: [path.rawValue]
      )
    case .repeatedReadWarning(let path, let count):
      return ToolResultPreview(
        text:
          "Repeated read_file loop detected for \(path.rawValue) after \(count) reads. Stop reading this file again unless it changed or you need a different range.",
        affectedPaths: [path.rawValue]
      )
    case .lineTooLong(let path, let line, let byteCount):
      return ToolResultPreview(
        status: .failed,
        text:
          "Line \(line) in \(path.rawValue) is \(byteCount) bytes and cannot fit in one read_file page. Use search_files for a targeted snippet.",
        affectedPaths: [path.rawValue]
      )
    case .offsetOutOfRange(let path, let requestedOffset, let lineCount):
      return ToolResultPreview(
        status: .failed,
        text:
          "read_file offset \(requestedOffset) is past the end of \(path.rawValue), which has \(lineCount) lines.",
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
  package static let readFile = ToolDefinition(
    name: .readFile,
    description:
      "Read a workspace text file into context to inspect, explain, summarize, reason about, or edit it. Cannot read chat attachments; use their supplied content directly. Read before editing unless exact current content is visible.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "offset",
        description: "1-based start line.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
      ToolParameterDefinition(
        name: "limit",
        description: "Maximum lines to return, capped at 500.",
        isRequired: false,
        valueType: .integer,
        defaultValue: .number(Double(ReadFileLimits.maximumLinesPerPage)),
        minimum: 1,
        maximum: Double(ReadFileLimits.maximumLinesPerPage)
      ),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

extension ReadFileInput {
  static func decodeToolArguments(_ arguments: ToolCallArguments) throws -> ReadFileInput {
    do {
      let input = try ToolInputDecoder.decode(ReadFileInput.self, from: arguments)
      try ToolArgumentValidation.requireNonEmptyPath(input.path)
      return input
    } catch let error as ReadFileInputValidationError {
      switch error {
      case .invalidOffset:
        throw InvalidToolCallReason.invalidPagination("offset")
      case .invalidLimit:
        throw InvalidToolCallReason.invalidPagination("limit")
      }
    }
  }
}

struct ReadFileToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<ReadFileInput>(
    definition: ToolDefinition.readFile,
    decodeArguments: ReadFileInput.decodeToolArguments,
    makePayload: ToolCallPayload.readFile,
    extractInput: { payload in
      guard case .readFile(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.readFile.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  private let maxBytes: Int
  private let maxLines: Int?

  init(
    maxBytes: Int = ReadFileLimits.renderedContentBytesPerPage,
    maxLines: Int? = ReadFileLimits.maximumLinesPerPage
  ) {
    self.maxBytes = maxBytes
    self.maxLines = maxLines
  }

  func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: resolvedPath)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    var resolvedURL: URL?
    var relativePath: WorkspaceRelativePath?
    var result: ReadFileResult?

    do {
      let failure: ToolResultPayload? = try context.workspace.withSecurityScopedAccess {
        let resolvedPathURL = try context.workspace.resolveAllowedPath(input.path)
        resolvedURL = resolvedPathURL
        let path = context.workspace.relativePath(for: resolvedPathURL)
        relativePath = path
        let readResult = try Self.readPage(
          from: resolvedPathURL,
          path: path,
          startLine: input.offset ?? 1,
          maxLines: resolvedMaxLines(requestedLimit: input.limit),
          maxBytes: maxBytes
        )
        guard let readResult else {
          return .readFile(
            .failed(path: path, reason: .unsupportedFileType("non-UTF-8 text"))
          )
        }

        result = readResult
        return nil
      }

      if let failure {
        return failure
      }

      guard let relativePath, let result else {
        return .readFile(
          .failed(path: relativePath, reason: .executionError("read_file result unavailable."))
        )
      }

      guard case .page(let page) = result else {
        return .readFile(result)
      }

      let readKey = ReadKey(path: relativePath, range: Self.rangeKey(for: input))
      guard let readTracker = context.readTracker else {
        return .readFile(result)
      }

      switch await readTracker.record(readKey: readKey, page: page) {
      case .success:
        return .readFile(result)
      case .unchanged:
        return .readFile(.unchanged(path: relativePath, readKey: readKey))
      case .repeatedReadWarning(let count):
        return .readFile(.repeatedReadWarning(path: relativePath, count: count))
      }
    } catch {
      return .readFile(
        .failed(
          path: ToolResultFailureMapper.relativePath(
            for: input.path, resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.isFileNotFound(error)
            ? await ToolResultFailureMapper.missingFileReason(
              for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
            : ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }

  private func resolvedMaxLines(requestedLimit: Int?) -> Int? {
    switch (requestedLimit, maxLines) {
    case (.none, .none):
      nil
    case (.some(let requestedLimit), .none):
      requestedLimit
    case (.none, .some(let maxLines)):
      maxLines
    case (.some(let requestedLimit), .some(let maxLines)):
      min(requestedLimit, maxLines)
    }
  }

  private static func rangeKey(for input: ReadFileInput) -> String? {
    let offset = input.offset ?? 1
    guard offset != 1 || input.limit != nil else {
      return nil
    }

    if let limit = input.limit {
      return "offset=\(offset),limit=\(limit)"
    }

    return "offset=\(offset)"
  }

  static func readPage(
    from url: URL,
    path: WorkspaceRelativePath,
    startLine: Int,
    maxLines: Int?,
    maxBytes: Int
  ) throws -> ReadFileResult? {
    let fileHandle = try FileHandle(forReadingFrom: url)
    defer {
      try? fileHandle.close()
    }

    var reader = ReadFileLineReader(fileHandle: fileHandle)
    var lineNumber = 1
    let pageByteLimit = max(maxBytes, 0)

    while lineNumber < startLine {
      guard try reader.nextLine(maxBufferedBytes: 0) != nil else {
        return .offsetOutOfRange(
          path: path,
          requestedOffset: startLine,
          lineCount: lineNumber - 1
        )
      }
      lineNumber += 1
    }

    guard
      var currentLine = try reader.nextLine(
        maxBufferedBytes: availableContentBytes(
          for: lineNumber,
          pageByteLimit: pageByteLimit
        )
      )
    else {
      if startLine == 1 {
        return .page(
          try ReadFilePage(
            path: path,
            startLine: 1,
            endLine: nil,
            content: "",
            continuation: .endOfFile
          )
        )
      }
      return .offsetOutOfRange(
        path: path,
        requestedOffset: startLine,
        lineCount: lineNumber - 1
      )
    }

    var outputLines: [String] = []
    var renderedByteCount = 0

    while true {
      if let maxLines, outputLines.count == maxLines {
        return .page(
          try ReadFilePage(
            path: path,
            startLine: startLine,
            endLine: lineNumber - 1,
            content: outputLines.joined(separator: "\n"),
            continuation: .next(offset: lineNumber, reason: .lineLimit)
          )
        )
      }

      let gutterByteCount = ReadFilePage.lineNumberPrefix(for: lineNumber).utf8.count
      let fullLineRenderedByteCount = gutterByteCount + currentLine.byteCount
      let separatorByteCount = outputLines.isEmpty ? 0 : 1
      let nextRenderedByteCount =
        renderedByteCount + separatorByteCount + fullLineRenderedByteCount

      guard nextRenderedByteCount <= pageByteLimit else {
        if fullLineRenderedByteCount > pageByteLimit {
          if outputLines.isEmpty {
            return .lineTooLong(
              path: path,
              line: lineNumber,
              byteCount: currentLine.byteCount
            )
          }
          return .page(
            try ReadFilePage(
              path: path,
              startLine: startLine,
              endLine: lineNumber - 1,
              content: outputLines.joined(separator: "\n"),
              continuation: .blocked(line: lineNumber, byteCount: currentLine.byteCount)
            )
          )
        }
        return .page(
          try ReadFilePage(
            path: path,
            startLine: startLine,
            endLine: lineNumber - 1,
            content: outputLines.joined(separator: "\n"),
            continuation: .next(offset: lineNumber, reason: .byteLimit)
          )
        )
      }

      guard let lineData = currentLine.content,
        let decodedLine = String(data: lineData, encoding: .utf8)
      else {
        return nil
      }
      outputLines.append(decodedLine)
      renderedByteCount = nextRenderedByteCount
      lineNumber += 1

      guard
        let nextLine = try reader.nextLine(
          maxBufferedBytes: availableContentBytes(
            for: lineNumber,
            pageByteLimit: pageByteLimit
          )
        )
      else {
        return .page(
          try ReadFilePage(
            path: path,
            startLine: startLine,
            endLine: lineNumber - 1,
            content: outputLines.joined(separator: "\n"),
            continuation: .endOfFile
          )
        )
      }
      currentLine = nextLine
    }
  }

  private static func availableContentBytes(
    for lineNumber: Int,
    pageByteLimit: Int
  ) -> Int {
    max(0, pageByteLimit - ReadFilePage.lineNumberPrefix(for: lineNumber).utf8.count)
  }
}

private struct ReadFileLineReader {
  let fileHandle: FileHandle
  private var chunk = Data()
  private var chunkIndex = 0
  private var reachedEndOfFile = false

  init(fileHandle: FileHandle) {
    self.fileHandle = fileHandle
  }

  mutating func nextLine(maxBufferedBytes: Int) throws -> ReadFileScannedLine? {
    var content = Data()
    var byteCount = 0
    var lastByte: UInt8?
    var sawContentByte = false

    while true {
      guard let byte = try nextByte() else {
        guard sawContentByte else {
          return nil
        }
        return normalizedLine(
          content: content,
          byteCount: byteCount,
          lastByte: lastByte
        )
      }

      if byte == 0x0A {
        return normalizedLine(
          content: content,
          byteCount: byteCount,
          lastByte: lastByte
        )
      }

      sawContentByte = true
      byteCount += 1
      lastByte = byte
      if content.count < maxBufferedBytes {
        content.append(byte)
      }
    }
  }

  private mutating func nextByte() throws -> UInt8? {
    while chunkIndex >= chunk.endIndex {
      guard !reachedEndOfFile else {
        return nil
      }
      chunk = try fileHandle.read(upToCount: 8 * 1024) ?? Data()
      chunkIndex = chunk.startIndex
      if chunk.isEmpty {
        reachedEndOfFile = true
      }
    }

    let byte = chunk[chunkIndex]
    chunkIndex += 1
    return byte
  }

  private func normalizedLine(
    content: Data,
    byteCount: Int,
    lastByte: UInt8?
  ) -> ReadFileScannedLine {
    var normalizedContent = content
    let normalizedByteCount = lastByte == 0x0D ? max(0, byteCount - 1) : byteCount
    if normalizedContent.last == 0x0D {
      normalizedContent.removeLast()
    }
    return ReadFileScannedLine(
      content: normalizedContent.count == normalizedByteCount ? normalizedContent : nil,
      byteCount: normalizedByteCount
    )
  }
}

private struct ReadFileScannedLine {
  let content: Data?
  let byteCount: Int
}

internal enum ReadFileInputValidationError: LocalizedError {
  case invalidOffset
  case invalidLimit

  package var errorDescription: String? {
    switch self {
    case .invalidOffset:
      "read_file offset must be greater than or equal to 1."
    case .invalidLimit:
      "read_file limit must be greater than or equal to 1."
    }
  }
}
