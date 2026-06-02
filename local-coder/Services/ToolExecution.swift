import Foundation

nonisolated struct ToolContext: Sendable {
  let workspace: Workspace
}

nonisolated protocol TypedToolExecutor: Sendable {
  associatedtype Input: Decodable & Sendable

  static var definition: ToolDefinition { get }

  func evaluatePermission(_ input: Input, context: ToolContext) -> ToolPermissionEvaluation
  func run(_ input: Input, context: ToolContext) async -> ToolResultPreview
}

nonisolated struct AnyToolExecutor: Sendable {
  let definition: ToolDefinition
  private let runHandler: @Sendable (ToolCallRequest, ToolContext) async -> ToolCallRecord
  private let approvedRunHandler: @Sendable (ToolCallRequest, ToolContext) async -> ToolCallRecord

  init<T: TypedToolExecutor>(_ tool: T) {
    definition = T.definition
    runHandler = { request, context in
      await Self.runTool(tool, request: request, context: context)
    }

    approvedRunHandler = { request, context in
      await Self.runApprovedTool(tool, request: request, context: context)
    }
  }

  func run(_ request: ToolCallRequest, context: ToolContext) async -> ToolCallRecord {
    await runHandler(request, context)
  }

  func runApproved(_ request: ToolCallRequest, context: ToolContext) async -> ToolCallRecord {
    await approvedRunHandler(request, context)
  }

  private static func runTool<T: TypedToolExecutor>(
    _ tool: T,
    request: ToolCallRequest,
    context: ToolContext
  ) async -> ToolCallRecord {
    await evaluateAndRun(tool, request: request, context: context, isApproved: false)
  }

  private static func runApprovedTool<T: TypedToolExecutor>(
    _ tool: T,
    request: ToolCallRequest,
    context: ToolContext
  ) async -> ToolCallRecord {
    await evaluateAndRun(tool, request: request, context: context, isApproved: true)
  }

  private static func evaluateAndRun<T: TypedToolExecutor>(
    _ tool: T,
    request: ToolCallRequest,
    context: ToolContext,
    isApproved: Bool
  ) async -> ToolCallRecord {
    var record = makePendingRecord(request: request)

    do {
      try validateKnownArguments(request.arguments, definition: T.definition)
      let input = try ToolInputDecoder.decode(T.Input.self, from: request.arguments)
      let evaluation = tool.evaluatePermission(input, context: context)
      record.evaluation = evaluation

      guard shouldRun(evaluation: evaluation, isApproved: isApproved, record: &record) else {
        return record
      }

      return await runEvaluatedTool(
        tool, input: input, request: request, record: record, context: context)
    } catch {
      return failedRecord(request: request, definition: T.definition, error: error)
    }
  }

  private static func shouldRun(
    evaluation: ToolPermissionEvaluation,
    isApproved: Bool,
    record: inout ToolCallRecord
  ) -> Bool {
    switch evaluation.decision {
    case .allowed:
      return true
    case .requiresApproval where isApproved:
      record.status = .approved
      record.events.append(
        ToolCallEvent(actor: .user, kind: .approved, message: "Approved by user."))
      return true
    case .requiresApproval:
      record.status = .awaitingApproval
      record.events.append(
        ToolCallEvent(actor: .system, kind: .awaitingApproval, message: evaluation.reason))
      return false
    case .denied:
      let preview = ToolResultPreview(
        status: .denied,
        text: evaluation.reason,
        affectedPaths: evaluation.normalizedPaths
      )
      record.status = .denied
      record.resultPreview = preview
      record.events.append(ToolCallEvent(actor: .system, kind: .denied, message: evaluation.reason))
      return false
    }
  }

  private static func runEvaluatedTool<T: TypedToolExecutor>(
    _ tool: T,
    input: T.Input,
    request: ToolCallRequest,
    record: ToolCallRecord,
    context: ToolContext
  ) async -> ToolCallRecord {
    var record = record
    record.status = .running
    record.events.append(
      ToolCallEvent(actor: .tool, kind: .started, message: "Started \(request.toolName.rawValue)."))

    let preview = await tool.run(input, context: context)
    record.resultPreview = preview

    switch preview.status {
    case .success:
      record.status = .completed
      record.events.append(
        ToolCallEvent(
          actor: .tool,
          kind: .completed,
          message: "Completed \(request.toolName.rawValue)."
        ))
    case .failed:
      record.status = .failed
      record.events.append(ToolCallEvent(actor: .tool, kind: .failed, message: preview.text))
    case .denied:
      record.status = .denied
      record.events.append(ToolCallEvent(actor: .tool, kind: .denied, message: preview.text))
    }

    return record
  }

  private static func failedRecord(
    request: ToolCallRequest,
    definition: ToolDefinition,
    error: Error
  ) -> ToolCallRecord {
    let message = "Invalid arguments for \(definition.name.rawValue): \(error.localizedDescription)"
    var record = makePendingRecord(request: request)
    record.status = .failed
    record.evaluation = ToolPermissionEvaluation(
      decision: .denied,
      reason: message,
      riskLevel: definition.riskLevel
    )
    record.resultPreview = ToolResultPreview(status: .failed, text: message)
    record.events.append(ToolCallEvent(actor: .system, kind: .failed, message: message))
    return record
  }

  private static func makePendingRecord(request: ToolCallRequest) -> ToolCallRecord {
    ToolCallRecord(
      request: request,
      status: .pending,
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: "Tool call has not been evaluated.",
        riskLevel: .low
      ),
      events: [
        ToolCallEvent(
          actor: .assistant,
          kind: .requested,
          message: "Requested \(request.toolName.rawValue)."
        )
      ]
    )
  }

  private static func validateKnownArguments(
    _ arguments: ToolCallArguments,
    definition: ToolDefinition
  ) throws {
    let knownArguments = Set(definition.parameters.map(\.name))
    let unknownArguments = Set(arguments.keys).subtracting(knownArguments)
    guard unknownArguments.isEmpty else {
      throw ToolInputDecodingError.unknownArguments(unknownArguments.sorted())
    }
  }
}

nonisolated struct ToolExecutorRegistry: Sendable {
  static let readOnly = ToolExecutorRegistry([
    AnyToolExecutor(ReadFileToolExecutor()),
    AnyToolExecutor(ListFilesToolExecutor()),
    AnyToolExecutor(GlobFilesToolExecutor()),
    AnyToolExecutor(SearchFilesToolExecutor()),
  ])

  static let codingAgent = ToolExecutorRegistry([
    AnyToolExecutor(ReadFileToolExecutor()),
    AnyToolExecutor(ListFilesToolExecutor()),
    AnyToolExecutor(GlobFilesToolExecutor()),
    AnyToolExecutor(SearchFilesToolExecutor()),
    AnyToolExecutor(WriteFileToolExecutor()),
  ])

  private let orderedExecutors: [AnyToolExecutor]
  private let executorsByName: [ToolName: AnyToolExecutor]

  init(_ executors: [AnyToolExecutor] = []) {
    orderedExecutors = executors
    executorsByName = Dictionary(
      uniqueKeysWithValues: executors.map { executor in
        (executor.definition.name, executor)
      })
  }

  init(executors: [ToolName: AnyToolExecutor]) {
    self.init(
      executors.sorted { lhs, rhs in
        lhs.key.rawValue.localizedStandardCompare(rhs.key.rawValue) == .orderedAscending
      }.map(\.value))
  }

  var toolRegistry: ToolRegistry {
    ToolRegistry(tools: orderedExecutors.map(\.definition))
  }

  var definitions: [ToolDefinition] {
    orderedExecutors.map(\.definition)
  }

  func executor(for toolName: ToolName) -> AnyToolExecutor? {
    executorsByName[toolName]
  }
}

nonisolated struct ReadFileInput: Decodable, Sendable {
  let path: String
  let offset: Int?
  let limit: Int?

  private enum CodingKeys: String, CodingKey {
    case path
    case offset
    case limit
  }

  init(path: String, offset: Int? = nil, limit: Int? = nil) {
    self.path = path
    self.offset = offset
    self.limit = limit
  }

  init(from decoder: Decoder) throws {
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

nonisolated struct ReadFileToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.readFile

  private let maxBytes: Int

  init(maxBytes: Int = 40 * 1024) {
    self.maxBytes = maxBytes
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
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPreview {
    do {
      return try context.workspace.withSecurityScopedAccess {
        let resolvedURL = try context.workspace.resolveAllowedPath(input.path)
        let preview = try Self.readPreview(
          from: resolvedURL,
          startLine: input.offset ?? 1,
          maxLines: input.limit,
          maxBytes: maxBytes
        )
        guard let content = preview.content else {
          return ToolResultPreview(
            status: .failed,
            text: "File is not valid UTF-8 text.",
            affectedPaths: [resolvedURL.path(percentEncoded: false)]
          )
        }

        return ToolResultPreview(
          status: .success,
          text: content,
          truncated: preview.truncated,
          affectedPaths: [resolvedURL.path(percentEncoded: false)]
        )
      }
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
      )
    }
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
  let startLine: Int
  let maxLines: Int?
  let previewByteLimit: Int

  private var lineBuffer = Data()
  private var outputLines: [String] = []
  private var outputByteCount = 0
  private var truncated = false
  private(set) var shouldStop = false

  init(startLine: Int, maxLines: Int?, previewByteLimit: Int) {
    self.startLine = startLine
    self.maxLines = maxLines
    self.previewByteLimit = previewByteLimit
  }

  var hasBufferedLine: Bool {
    !lineBuffer.isEmpty
  }

  var result: (content: String?, truncated: Bool) {
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

nonisolated enum ReadFileInputValidationError: LocalizedError {
  case invalidOffset
  case invalidLimit

  var errorDescription: String? {
    switch self {
    case .invalidOffset:
      "read_file offset must be greater than or equal to 1."
    case .invalidLimit:
      "read_file limit must be greater than or equal to 1."
    }
  }
}

nonisolated struct ListFilesInput: Decodable, Sendable {
  let path: String?
}

nonisolated struct ListFilesToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.listFiles

  private let maxDepth: Int
  private let maxEntries: Int
  private let skippedNames: Set<String>

  init(
    maxDepth: Int = 4,
    maxEntries: Int = 300,
    skippedNames: Set<String> = [
      ".git",
      "node_modules",
      ".build",
      "DerivedData",
      ".swiftpm",
      "dist",
      "build",
      ".cache",
      ".DS_Store",
    ]
  ) {
    self.maxDepth = maxDepth
    self.maxEntries = maxEntries
    self.skippedNames = skippedNames
  }

  func evaluatePermission(
    _ input: ListFilesInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path ?? ".")
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Listing files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: ListFilesInput, context: ToolContext) async -> ToolResultPreview {
    let path = input.path ?? "."

    do {
      return try context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(path)
        var entries: [String] = []
        var truncated = false
        try appendEntries(
          at: rootURL,
          displayPrefix: "",
          depth: 0,
          entries: &entries,
          truncated: &truncated
        )

        return ToolResultPreview(
          status: .success,
          text: entries.isEmpty ? "(empty)" : entries.joined(separator: "\n"),
          truncated: truncated,
          affectedPaths: [rootURL.path(percentEncoded: false)]
        )
      }
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
      )
    }
  }

  private func appendEntries(
    at url: URL,
    displayPrefix: String,
    depth: Int,
    entries: inout [String],
    truncated: inout Bool
  ) throws {
    guard entries.count < maxEntries else {
      truncated = true
      return
    }
    guard depth <= maxDepth else {
      truncated = true
      return
    }

    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
    guard resourceValues.isDirectory == true else {
      entries.append(displayPrefix.isEmpty ? url.lastPathComponent : displayPrefix)
      return
    }

    let children = try FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    )
    .filter { !skippedNames.contains($0.lastPathComponent) }
    .sorted { lhs, rhs in
      lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    for child in children {
      guard entries.count < maxEntries else {
        truncated = true
        return
      }

      let childValues = try child.resourceValues(forKeys: [.isDirectoryKey])
      let isDirectory = childValues.isDirectory == true
      let relativePath =
        displayPrefix.isEmpty
        ? child.lastPathComponent
        : displayPrefix + "/" + child.lastPathComponent
      entries.append(isDirectory ? relativePath + "/" : relativePath)

      if isDirectory {
        if depth < maxDepth {
          try appendEntries(
            at: child,
            displayPrefix: relativePath,
            depth: depth + 1,
            entries: &entries,
            truncated: &truncated
          )
        } else {
          truncated = true
        }
      }
    }
  }
}

nonisolated struct WriteFileInput: Decodable, Sendable {
  let path: String
  let content: String
}

nonisolated struct WriteFileToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.writeFile

  func evaluatePermission(
    _ input: WriteFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Writing files inside the workspace requires approval.",
        riskLevel: .high,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .high
      )
    }
  }

  func run(_ input: WriteFileInput, context: ToolContext) async -> ToolResultPreview {
    do {
      return try context.workspace.withSecurityScopedAccess {
        let resolvedURL = try context.workspace.resolveAllowedPath(input.path)
        try FileManager.default.createDirectory(
          at: resolvedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try input.content.write(to: resolvedURL, atomically: true, encoding: .utf8)
        return ToolResultPreview(
          status: .success,
          text: "Wrote \(input.content.utf8.count) bytes to \(input.path).",
          affectedPaths: [resolvedURL.path(percentEncoded: false)]
        )
      }
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
      )
    }
  }
}

nonisolated enum ToolInputDecodingError: LocalizedError, Equatable {
  case unknownArguments([String])

  var errorDescription: String? {
    switch self {
    case .unknownArguments(let arguments):
      "Unknown argument(s): \(arguments.joined(separator: ", "))."
    }
  }
}

nonisolated enum ToolInputDecoder {
  static func decode<Input: Decodable>(
    _ inputType: Input.Type,
    from arguments: ToolCallArguments
  ) throws -> Input {
    let data = try JSONEncoder().encode(arguments)
    return try JSONDecoder().decode(inputType, from: data)
  }
}

nonisolated struct ToolOrchestrator: Sendable {
  private let executorRegistry: ToolExecutorRegistry

  init(
    executorRegistry: ToolExecutorRegistry = .readOnly
  ) {
    self.executorRegistry = executorRegistry
  }

  var toolRegistry: ToolRegistry {
    executorRegistry.toolRegistry
  }

  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolCallRecord {
    guard request.workspaceID == workspace.id else {
      let message = "Tool call workspace does not match the active workspace."
      return ToolCallRecord(
        request: request,
        status: .denied,
        evaluation: ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: .high
        ),
        events: [
          ToolCallEvent(
            actor: .assistant,
            kind: .requested,
            message: "Requested \(request.toolName.rawValue)."
          ),
          ToolCallEvent(actor: .system, kind: .denied, message: message),
        ],
        resultPreview: ToolResultPreview(status: .denied, text: message)
      )
    }

    guard let executor = executorRegistry.executor(for: request.toolName) else {
      let message = "Unknown tool: \(request.toolName.rawValue)."
      return ToolCallRecord(
        request: request,
        status: .failed,
        evaluation: ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: .high
        ),
        events: [
          ToolCallEvent(
            actor: .assistant,
            kind: .requested,
            message: "Requested \(request.toolName.rawValue)."
          ),
          ToolCallEvent(actor: .system, kind: .failed, message: message),
        ],
        resultPreview: ToolResultPreview(status: .failed, text: message)
      )
    }

    return await executor.run(
      request,
      context: ToolContext(workspace: workspace)
    )
  }

  func executeApproved(request: ToolCallRequest, workspace: Workspace) async -> ToolCallRecord {
    guard request.workspaceID == workspace.id else {
      let message = "Tool call workspace does not match the active workspace."
      return ToolCallRecord(
        request: request,
        status: .denied,
        evaluation: ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: .high
        ),
        events: [
          ToolCallEvent(
            actor: .assistant,
            kind: .requested,
            message: "Requested \(request.toolName.rawValue)."
          ),
          ToolCallEvent(actor: .system, kind: .denied, message: message),
        ],
        resultPreview: ToolResultPreview(status: .denied, text: message)
      )
    }

    guard let executor = executorRegistry.executor(for: request.toolName) else {
      let message = "Unknown tool: \(request.toolName.rawValue)."
      return ToolCallRecord(
        request: request,
        status: .failed,
        evaluation: ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: .high
        ),
        events: [
          ToolCallEvent(
            actor: .assistant,
            kind: .requested,
            message: "Requested \(request.toolName.rawValue)."
          ),
          ToolCallEvent(actor: .system, kind: .failed, message: message),
        ],
        resultPreview: ToolResultPreview(status: .failed, text: message)
      )
    }

    return await executor.runApproved(
      request,
      context: ToolContext(workspace: workspace)
    )
  }
}
