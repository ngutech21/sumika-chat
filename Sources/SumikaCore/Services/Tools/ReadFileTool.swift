import Foundation

public enum ReadFileTrackedResult: Equatable, Sendable {
  case success
  case unchanged
  case repeatedReadWarning(count: Int)
}

public actor ReadFileReadTracker {
  private struct ReadStamp: Sendable {
    var content: ToolTextOutput
    var consecutiveReadCount: Int
  }

  private var stamps: [ReadKey: ReadStamp] = [:]
  private var lastReadKey: ReadKey?

  public init() {}

  public func record(readKey: ReadKey, content: ToolTextOutput) -> ReadFileTrackedResult {
    defer {
      lastReadKey = readKey
    }

    guard var stamp = stamps[readKey], stamp.content == content else {
      stamps[readKey] = ReadStamp(content: content, consecutiveReadCount: 1)
      return .success
    }

    guard lastReadKey == readKey else {
      stamps[readKey] = ReadStamp(content: content, consecutiveReadCount: 1)
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

public struct ReadFileInput: Codable, Equatable, Sendable {
  public let path: String
  public let offset: Int?
  public let limit: Int?

  private enum CodingKeys: String, CodingKey {
    case path
    case offset
    case limit
  }

  public init(path: String, offset: Int? = nil, limit: Int? = nil) {
    self.path = path
    self.offset = offset
    self.limit = limit
  }

  public init(from decoder: Decoder) throws {
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

nonisolated extension ToolDefinition {
  public static let readFile = ToolDefinition(
    name: .readFile,
    description:
      "Read a workspace text file into your context to inspect, explain, summarize, reason about, or edit it. Use this before editing an existing file unless the exact current content is already visible.",
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
        description: "Maximum lines to return.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
    ],
    exampleArguments: [
      "path": .string("Sources/AppState.swift"),
      "offset": .number(1),
      "limit": .number(200),
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

public struct ReadFileToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<ReadFileInput>(
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

  public init(maxBytes: Int = 40 * 1024) {
    self.maxBytes = maxBytes
  }

  public func evaluatePermission(
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

  public func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    var resolvedURL: URL?
    var relativePath: WorkspaceRelativePath?
    var output: ToolTextOutput?

    do {
      let failure: ToolResultPayload? = try context.workspace.withSecurityScopedAccess {
        let resolvedPathURL = try context.workspace.resolveAllowedPath(input.path)
        resolvedURL = resolvedPathURL
        let path = context.workspace.relativePath(for: resolvedPathURL)
        relativePath = path
        let preview = try Self.readPreview(
          from: resolvedPathURL,
          startLine: input.offset ?? 1,
          maxLines: input.limit,
          maxBytes: maxBytes
        )
        guard let content = preview.content else {
          return .readFile(
            .failed(path: path, reason: .unsupportedFileType("non-UTF-8 text"))
          )
        }

        output = ToolTextOutput(text: content, truncated: preview.truncated)
        return nil
      }

      if let failure {
        return failure
      }

      guard let relativePath, let output else {
        return .readFile(
          .failed(path: relativePath, reason: .executionError("read_file result unavailable."))
        )
      }

      let readKey = ReadKey(path: relativePath, range: Self.rangeKey(for: input))
      guard let readTracker = context.readTracker else {
        return .readFile(.success(path: relativePath, content: output))
      }

      switch await readTracker.record(readKey: readKey, content: output) {
      case .success:
        return .readFile(.success(path: relativePath, content: output))
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
            ? ToolResultFailureMapper.missingFileReason(
              for: input.path, resolvedURL: resolvedURL, workspace: context.workspace)
            : ToolResultFailureMapper.reason(from: error)
        )
      )
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

  private static func readPreview(
    from url: URL,
    startLine: Int,
    maxLines: Int?,
    maxBytes: Int
  ) throws -> (content: String?, truncated: Bool) {
    let previewByteLimit = max(maxBytes, 0)
    guard previewByteLimit > 0 else {
      return ("", true)
    }

    let fileHandle = try FileHandle(forReadingFrom: url)
    defer {
      try? fileHandle.close()
    }

    var accumulator = ReadFilePreviewAccumulator(
      startLine: startLine,
      maxLines: maxLines,
      previewByteLimit: previewByteLimit
    )
    var lineNumber = 1

    while !accumulator.shouldStop {
      let chunk = try fileHandle.read(upToCount: 8 * 1024) ?? Data()
      guard !chunk.isEmpty else {
        break
      }

      for byte in chunk {
        if byte == 0x0A {
          guard accumulator.processBufferedLine(lineNumber: lineNumber) else {
            return (nil, false)
          }
          lineNumber += 1
        } else {
          guard accumulator.append(byte, lineNumber: lineNumber) else {
            return (nil, false)
          }
        }

        if accumulator.shouldStop {
          break
        }
      }
    }

    if !accumulator.shouldStop && accumulator.hasBufferedLine {
      guard accumulator.processBufferedLine(lineNumber: lineNumber) else {
        return (nil, false)
      }
    }

    return accumulator.result
  }
}

nonisolated private struct ReadFilePreviewAccumulator {
  public let startLine: Int
  public let maxLines: Int?
  public let previewByteLimit: Int

  private var lineBuffer = Data()
  private var outputLines: [String] = []
  private var outputByteCount = 0
  private var truncated = false
  private(set) var shouldStop = false

  public init(startLine: Int, maxLines: Int?, previewByteLimit: Int) {
    self.startLine = startLine
    self.maxLines = maxLines
    self.previewByteLimit = previewByteLimit
  }

  public var hasBufferedLine: Bool {
    !lineBuffer.isEmpty
  }

  public var result: (content: String?, truncated: Bool) {
    (outputLines.joined(separator: "\n"), truncated)
  }

  mutating func append(_ byte: UInt8, lineNumber: Int) -> Bool {
    guard lineNumber >= startLine else {
      return true
    }

    guard outputLines.count < (maxLines ?? Int.max) else {
      truncated = true
      shouldStop = true
      return true
    }

    guard lineBuffer.count < availableBytesForCurrentLine(lineNumber: lineNumber) else {
      truncated = true
      shouldStop = true
      return processBufferedLine(lineNumber: lineNumber)
    }

    lineBuffer.append(byte)
    return true
  }

  mutating func processBufferedLine(lineNumber: Int) -> Bool {
    defer {
      lineBuffer.removeAll(keepingCapacity: true)
    }

    if lineBuffer.last == 0x0D {
      lineBuffer.removeLast()
    }

    guard lineNumber >= startLine else {
      return true
    }

    if let maxLines, outputLines.count >= maxLines {
      truncated = true
      shouldStop = true
      return true
    }

    let linePrefix = "\(lineNumber): "
    let availableByteCount = availableBytesForCurrentLine(lineNumber: lineNumber)

    guard availableByteCount >= 0 else {
      truncated = true
      shouldStop = true
      return true
    }

    let line: String
    if lineBuffer.count > availableByteCount {
      let previewData = Data(lineBuffer.prefix(availableByteCount))
      guard let previewLine = utf8StringDroppingPartialSuffix(from: previewData) else {
        return false
      }
      line = previewLine
      truncated = true
      shouldStop = true
    } else {
      if let fullLine = String(data: lineBuffer, encoding: .utf8) {
        line = fullLine
      } else if truncated,
        let previewLine = utf8StringDroppingPartialSuffix(from: lineBuffer)
      {
        line = previewLine
      } else {
        return false
      }
    }

    let numberedLine = linePrefix + line
    let numberedLineByteCount = numberedLine.utf8.count
    let nextByteCount = outputByteCount + separatorByteCount + numberedLineByteCount

    guard nextByteCount <= previewByteLimit else {
      truncated = true
      shouldStop = true

      if outputLines.isEmpty {
        let previewData = Data(numberedLine.utf8.prefix(previewByteLimit))
        outputLines.append(utf8StringDroppingPartialSuffix(from: previewData) ?? "")
      }

      return true
    }

    outputLines.append(numberedLine)
    outputByteCount = nextByteCount
    return true
  }

  private func availableBytesForCurrentLine(lineNumber: Int) -> Int {
    let linePrefix = "\(lineNumber): "
    return previewByteLimit - outputByteCount - separatorByteCount - linePrefix.utf8.count
  }

  private var separatorByteCount: Int {
    outputLines.isEmpty ? 0 : 1
  }

  private func utf8StringDroppingPartialSuffix(from data: Data) -> String? {
    if let string = String(data: data, encoding: .utf8) {
      return string
    }

    guard !data.isEmpty else {
      return ""
    }

    for droppedByteCount in 1...min(3, data.count) {
      let shortenedData = data.dropLast(droppedByteCount)
      if let string = String(data: shortenedData, encoding: .utf8) {
        return string
      }
    }

    return nil
  }
}

public enum ReadFileInputValidationError: LocalizedError {
  case invalidOffset
  case invalidLimit

  public var errorDescription: String? {
    switch self {
    case .invalidOffset:
      "read_file offset must be greater than or equal to 1."
    case .invalidLimit:
      "read_file limit must be greater than or equal to 1."
    }
  }
}
