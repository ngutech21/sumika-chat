import Foundation

public struct ToolContext: Sendable {
  public let workspace: Workspace
  public let sessionID: ChatSession.ID?
  public let readTracker: ReadFileReadTracker?
  public let latestCommandResultStore: LatestCommandResultStore?
  public let webAccessSettings: WebAccessSettings
  public let webSearcher: any WebSearching
  public let webFetcher: any WebFetching

  public init(
    workspace: Workspace,
    sessionID: ChatSession.ID? = nil,
    readTracker: ReadFileReadTracker? = nil,
    latestCommandResultStore: LatestCommandResultStore? = nil,
    webAccessSettings: WebAccessSettings = .disabled,
    webSearcher: any WebSearching = DefaultWebSearchService(),
    webFetcher: any WebFetching = DefaultWebFetchService()
  ) {
    self.workspace = workspace
    self.sessionID = sessionID
    self.readTracker = readTracker
    self.latestCommandResultStore = latestCommandResultStore
    self.webAccessSettings = webAccessSettings
    self.webSearcher = webSearcher
    self.webFetcher = webFetcher
  }
}

public enum ReadFileTrackedResult: Equatable, Sendable {
  case success
  case unchanged
  case repeatedReadWarning(count: Int)
}

public actor ReadFileReadTracker {
  private struct ReadSignature: Equatable, Sendable {
    var text: String
    var truncated: Bool
    var redacted: Bool
  }

  private struct ReadStamp: Sendable {
    var signature: ReadSignature
    var consecutiveReadCount: Int
  }

  private var stamps: [ReadKey: ReadStamp] = [:]
  private var lastReadKey: ReadKey?

  public init() {}

  public func record(readKey: ReadKey, content: ToolTextOutput) -> ReadFileTrackedResult {
    let signature = ReadSignature(
      text: content.text,
      truncated: content.truncated,
      redacted: content.redacted
    )

    defer {
      lastReadKey = readKey
    }

    guard var stamp = stamps[readKey], stamp.signature == signature else {
      stamps[readKey] = ReadStamp(signature: signature, consecutiveReadCount: 1)
      return .success
    }

    guard lastReadKey == readKey else {
      stamps[readKey] = ReadStamp(signature: signature, consecutiveReadCount: 1)
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

enum ToolResultFailureMapper {
  static func isFileNotFound(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == NSCocoaErrorDomain else {
      return false
    }
    return nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
  }

  static func missingFileReason(
    for inputPath: String,
    resolvedURL: URL?,
    workspace: Workspace
  ) -> ToolFailureReason {
    let path = relativePath(for: inputPath, resolvedURL: resolvedURL, workspace: workspace)
    let suggestions = workspace.withSecurityScopedAccess {
      WorkspacePathSuggestionResolver()
        .suggestions(forMissingPath: inputPath, workspace: workspace)
    }
    return .fileNotFound(
      path: path,
      suggestions: suggestions
    )
  }

  static func reason(from error: Error) -> ToolFailureReason {
    if let pathError = error as? WorkspacePathResolutionError {
      switch pathError {
      case .emptyPath:
        return .emptyPath
      case .unsupportedURLScheme(let scheme):
        return .unsupportedURLScheme(scheme)
      case .pathOutsideWorkspace:
        return .pathOutsideWorkspace
      }
    }

    if let editError = error as? EditFileValidationError {
      switch editError {
      case .emptyOldText:
        return .invalidArguments(.emptyOldText)
      case .identicalReplacement:
        return .invalidArguments(.parserError(editError.localizedDescription))
      case .nonUTF8:
        return .unsupportedFileType("non-UTF-8 text")
      case .oldTextNotFound:
        return .executionError(editError.localizedDescription)
      case .ambiguousOldText:
        return .executionError(editError.localizedDescription)
      }
    }

    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
      switch nsError.code {
      case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
        return .fileNotFound(path: nil, suggestions: [])
      case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
        return .permissionDenied
      default:
        break
      }
    }

    if let localizedError = error as? LocalizedError,
      let description = localizedError.errorDescription
    {
      return .executionError(description)
    }

    return .executionError(error.localizedDescription)
  }

  static func relativePath(
    for inputPath: String?,
    resolvedURL: URL?,
    workspace: Workspace
  ) -> WorkspaceRelativePath? {
    if let resolvedURL {
      return workspace.relativePath(for: resolvedURL)
    }
    guard let inputPath, !inputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return WorkspaceRelativePath(rawValue: inputPath)
  }
}

public protocol TypedToolExecutor: Sendable {
  associatedtype Input: Decodable & Sendable

  static var definition: ToolDefinition { get }

  func evaluatePermission(_ input: Input, context: ToolContext) -> ToolPermissionEvaluation
  func previewApproval(_ input: Input, context: ToolContext) async -> ToolResultPreview?
  func run(_ input: Input, context: ToolContext) async -> ToolResultPayload
}

extension TypedToolExecutor {
  public func previewApproval(_ input: Input, context: ToolContext) async -> ToolResultPreview? {
    nil
  }
}

public struct AnyToolExecutor: Sendable {
  public let definition: ToolDefinition
  private let runHandler: @Sendable (ToolCallRequest, ToolContext) async -> ToolCallRecord
  private let approvedRunHandler: @Sendable (ToolCallRequest, ToolContext) async -> ToolCallRecord

  public init<T: TypedToolExecutor>(_ tool: T) {
    definition = T.definition
    runHandler = { request, context in
      await Self.runTool(tool, request: request, context: context)
    }

    approvedRunHandler = { request, context in
      await Self.runApprovedTool(tool, request: request, context: context)
    }
  }

  public func run(_ request: ToolCallRequest, context: ToolContext) async -> ToolCallRecord {
    await runHandler(request, context)
  }

  public func runApproved(_ request: ToolCallRequest, context: ToolContext) async -> ToolCallRecord
  {
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
      let input = try typedInput(T.Input.self, from: request.payload, definition: T.definition)
      let evaluation = tool.evaluatePermission(input, context: context)
      record.evaluation = evaluation

      if T.definition.name == .askUser && !isApproved {
        guard shouldRun(evaluation: evaluation, isApproved: isApproved, record: &record) else {
          return record
        }
        record.state = .awaitingUserAnswer
        record.events.append(
          ToolCallEvent(
            actor: .system,
            kind: .awaitingUserAnswer,
            message: "Waiting for the user to answer."
          ))
        return record
      }

      if evaluation.decision == .requiresApproval && !isApproved {
        guard
          await prepareApprovalPreview(
            tool,
            input: input,
            evaluation: evaluation,
            record: &record,
            context: context
          )
        else {
          return record
        }
      }

      guard shouldRun(evaluation: evaluation, isApproved: isApproved, record: &record) else {
        return record
      }

      return await runEvaluatedTool(
        tool, input: input, request: request, record: record, context: context)
    } catch {
      return failedRecord(request: request, definition: T.definition, error: error)
    }
  }

  private static func prepareApprovalPreview<T: TypedToolExecutor>(
    _ tool: T,
    input: T.Input,
    evaluation: ToolPermissionEvaluation,
    record: inout ToolCallRecord,
    context: ToolContext
  ) async -> Bool {
    guard let preview = await tool.previewApproval(input, context: context) else {
      return true
    }

    record.state = .awaitingApproval(preview: preview)

    switch preview.status {
    case .success:
      return true
    case .failed:
      record.state = .failed(
        ToolResultPayload.failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: firstPath(in: preview),
            reason: .executionError(preview.text)
          )))
      record.events.append(ToolCallEvent(actor: .tool, kind: .failed, message: preview.text))
      return false
    case .denied:
      record.state = .denied(
        ToolResultPayload.failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: firstPath(in: preview),
            reason: .permissionDenied,
            recovery: .askUser(message: preview.text)
          )))
      record.evaluation = ToolPermissionEvaluation(
        decision: .denied,
        reason: preview.text,
        riskLevel: evaluation.riskLevel,
        normalizedPaths: evaluation.normalizedPaths,
        workspaceRelativePaths: evaluation.workspaceRelativePaths
      )
      record.events.append(ToolCallEvent(actor: .tool, kind: .denied, message: preview.text))
      return false
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
      record.state = .approved
      record.events.append(
        ToolCallEvent(actor: .user, kind: .approved, message: "Approved by user."))
      return true
    case .requiresApproval:
      let preview = record.approvalPreview
      record.state = .awaitingApproval(preview: preview)
      record.events.append(
        ToolCallEvent(actor: .system, kind: .awaitingApproval, message: evaluation.reason))
      return false
    case .denied:
      record.state = .denied(
        .failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: evaluation.firstModelFacingPath,
            reason: .permissionDenied,
            recovery: .askUser(message: evaluation.reason)
          )))
      record.events.append(ToolCallEvent(actor: .system, kind: .denied, message: evaluation.reason))
      return false
    }
  }

  private static func firstPath(in preview: ToolResultPreview) -> WorkspaceRelativePath? {
    preview.affectedPaths.first.map { WorkspaceRelativePath(rawValue: $0) }
  }

  private static func runEvaluatedTool<T: TypedToolExecutor>(
    _ tool: T,
    input: T.Input,
    request: ToolCallRequest,
    record: ToolCallRecord,
    context: ToolContext
  ) async -> ToolCallRecord {
    var record = record
    record.state = .running
    record.events.append(
      ToolCallEvent(actor: .tool, kind: .started, message: "Started \(request.toolName.rawValue)."))

    let payload = await tool.run(input, context: context)
    let preview = payload.preview

    switch preview.status {
    case .success:
      record.state = .completed(payload)
      record.events.append(
        ToolCallEvent(
          actor: .tool,
          kind: .completed,
          message: "Completed \(request.toolName.rawValue)."
        ))
    case .failed:
      record.state = .failed(payload)
      record.events.append(ToolCallEvent(actor: .tool, kind: .failed, message: preview.text))
    case .denied:
      record.state = .denied(payload)
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
    record.state = .failed(
      .failure(
        ToolFailure(
          toolName: definition.name,
          path: nil,
          reason: .invalidArguments(.parserError(error.localizedDescription))
        )
      ))
    record.evaluation = ToolPermissionEvaluation(
      decision: .denied,
      reason: message,
      riskLevel: definition.riskLevel
    )
    record.events.append(ToolCallEvent(actor: .system, kind: .failed, message: message))
    return record
  }

  private static func makePendingRecord(request: ToolCallRequest) -> ToolCallRecord {
    ToolCallRecord(
      request: request,
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
      ],
      state: .pending
    )
  }

  private static func typedInput<Input>(
    _ inputType: Input.Type,
    from payload: ToolCallPayload,
    definition: ToolDefinition
  ) throws -> Input {
    switch payload {
    case .readFile(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .readFile)
    case .showFile(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .showFile)
    case .listFiles(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .listFiles)
    case .globFiles(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .globFiles)
    case .searchFiles(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .searchFiles)
    case .workspaceDiff(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .workspaceDiff)
    case .workspaceDiagnostics(let input):
      return try cast(
        input, as: inputType, definition: definition, actualToolName: .workspaceDiagnostics)
    case .writeFile(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .writeFile)
    case .editFile(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .editFile)
    case .runCommand(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .runCommand)
    case .todoWrite(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .todoWrite)
    case .askUser(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .askUser)
    case .webSearch(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .webSearch)
    case .webFetch(let input):
      return try cast(input, as: inputType, definition: definition, actualToolName: .webFetch)
    case .invalid:
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: ToolName.invalid.rawValue
      )
    }
  }

  private static func cast<Input, PayloadInput>(
    _ input: PayloadInput,
    as inputType: Input.Type,
    definition: ToolDefinition,
    actualToolName: ToolName
  ) throws -> Input {
    guard let typedInput = input as? Input, definition.name == actualToolName else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: actualToolName.rawValue
      )
    }
    return typedInput
  }
}

public struct ToolExecutorRegistry: Sendable {
  public static let readOnly = ToolExecutorRegistry([
    AnyToolExecutor(ReadFileToolExecutor()),
    AnyToolExecutor(ShowFileToolExecutor()),
    AnyToolExecutor(ListFilesToolExecutor()),
    AnyToolExecutor(GlobFilesToolExecutor()),
    AnyToolExecutor(SearchFilesToolExecutor()),
    AnyToolExecutor(WorkspaceDiffToolExecutor()),
    AnyToolExecutor(WorkspaceDiagnosticsToolExecutor()),
  ])

  public static let codingAgent = ToolExecutorRegistry([
    AnyToolExecutor(ReadFileToolExecutor()),
    AnyToolExecutor(ShowFileToolExecutor()),
    AnyToolExecutor(ListFilesToolExecutor()),
    AnyToolExecutor(GlobFilesToolExecutor()),
    AnyToolExecutor(SearchFilesToolExecutor()),
    AnyToolExecutor(WorkspaceDiffToolExecutor()),
    AnyToolExecutor(WorkspaceDiagnosticsToolExecutor()),
    AnyToolExecutor(EditFileToolExecutor()),
    AnyToolExecutor(WriteFileToolExecutor()),
    AnyToolExecutor(RunCommandToolExecutor()),
    AnyToolExecutor(TodoWriteToolExecutor()),
    AnyToolExecutor(AskUserToolExecutor()),
    AnyToolExecutor(WebSearchToolExecutor()),
    AnyToolExecutor(WebFetchToolExecutor()),
  ])

  private let orderedExecutors: [AnyToolExecutor]
  private let executorsByName: [ToolName: AnyToolExecutor]

  public init(_ executors: [AnyToolExecutor] = []) {
    orderedExecutors = executors
    executorsByName = Dictionary(
      uniqueKeysWithValues: executors.map { executor in
        (executor.definition.name, executor)
      })
  }

  public init(executors: [ToolName: AnyToolExecutor]) {
    self.init(
      executors.sorted { lhs, rhs in
        lhs.key.rawValue.localizedStandardCompare(rhs.key.rawValue) == .orderedAscending
      }.map(\.value))
  }

  public var toolRegistry: ToolRegistry {
    ToolRegistry(tools: orderedExecutors.map(\.definition))
  }

  public var definitions: [ToolDefinition] {
    orderedExecutors.map(\.definition)
  }

  public func executor(for toolName: ToolName) -> AnyToolExecutor? {
    executorsByName[toolName]
  }
}

public struct TodoWriteInput: Codable, Equatable, Sendable {
  public let items: [TodoItem]

  private enum CodingKeys: String, CodingKey {
    case items
  }

  public init(items: [TodoItem]) {
    self.items = items
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let items = try? container.decode([TodoItem].self, forKey: .items) {
      self.items = items
      return
    }

    if let rawItems = try? container.decode(String.self, forKey: .items) {
      if let decodedItems = Self.decodeItems(fromJSONString: rawItems) {
        items = decodedItems
        return
      }
      if let rows = Self.decodeStringRows(fromJSONString: rawItems) {
        do {
          items = try Self.parseRows(rows)
          return
        } catch {
          throw DecodingError.dataCorruptedError(
            forKey: .items,
            in: container,
            debugDescription: error.localizedDescription
          )
        }
      }
      do {
        items = try Self.parseRows(Self.plainTextRows(from: rawItems))
        return
      } catch {
        throw DecodingError.dataCorruptedError(
          forKey: .items,
          in: container,
          debugDescription: error.localizedDescription
        )
      }
    }

    if let rows = try? container.decode([String].self, forKey: .items) {
      do {
        items = try Self.parseRows(rows)
        return
      } catch {
        throw DecodingError.dataCorruptedError(
          forKey: .items,
          in: container,
          debugDescription: error.localizedDescription
        )
      }
    }

    throw DecodingError.dataCorruptedError(
      forKey: .items,
      in: container,
      debugDescription:
        "items must be todo rows: content:true|false."
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
  }

  private static func decodeItems(fromJSONString rawItems: String) -> [TodoItem]? {
    let data = Data(rawItems.utf8)
    return try? JSONDecoder().decode([TodoItem].self, from: data)
  }

  private static func decodeStringRows(fromJSONString rawItems: String) -> [String]? {
    let data = Data(rawItems.utf8)
    return try? JSONDecoder().decode([String].self, from: data)
  }

  private static func parseRows(_ rows: [String]) throws -> [TodoItem] {
    try rows.enumerated().map { index, row in
      try parseRow(row, index: index)
    }
  }

  private static func plainTextRows(from rawItems: String) -> [String] {
    normalizedPlainTextRows(from: rawItems)
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func normalizedPlainTextRows(from rawItems: String) -> String {
    rawItems
      .replacingOccurrences(of: #"\\n"#, with: "\n")
      .replacingOccurrences(of: #"\n"#, with: "\n")
  }

  private static func parseRow(_ row: String, index: Int) throws -> TodoItem {
    guard let parsed = parseDoneSuffix(from: row) else {
      throw TodoRowParsingError.malformedRow(row)
    }

    let content = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
    let status: TodoStatus = parsed.done ? .completed : .pending
    return TodoItem(id: String(index + 1), content: content, status: status)
  }

  private static func parseDoneSuffix(from row: String) -> (content: String, done: Bool)? {
    let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
    for suffix in [":true", ":false", ";true", ";false"] {
      guard trimmed.lowercased().hasSuffix(suffix) else {
        continue
      }
      let contentEnd = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
      let done = suffix.hasSuffix("true")
      return (String(trimmed[..<contentEnd]), done)
    }
    return nil
  }
}

private enum TodoRowParsingError: Error, LocalizedError {
  case malformedRow(String)

  var errorDescription: String? {
    switch self {
    case .malformedRow(let row):
      "todo_write row must be content:true|false: \(row)"
    }
  }
}

public struct TodoWriteToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.todoWrite

  public init() {}

  public func evaluatePermission(
    _ input: TodoWriteInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Updating Agent todo state is allowed.",
      riskLevel: .low
    )
  }

  public func run(_ input: TodoWriteInput, context: ToolContext) async -> ToolResultPayload {
    _ = context
    do {
      try TodoStateValidator().validate(input.items)
      return .todoWrite(.success)
    } catch {
      let reason =
        if let validationError = error as? TodoStateValidationError {
          ToolFailureReason.invalidArguments(
            .invalidTodoItems(validationError.localizedDescription))
        } else {
          ToolFailureReason.executionError(error.localizedDescription)
        }
      return .todoWrite(.failed(reason: reason))
    }
  }
}

public struct AskUserToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.askUser

  public init() {}

  public func evaluatePermission(
    _ input: AskUserInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Asking the user a blocking clarification is allowed.",
      riskLevel: .low
    )
  }

  public func run(_ input: AskUserInput, context: ToolContext) async -> ToolResultPayload {
    _ = input
    _ = context
    return .failure(
      ToolFailure(
        toolName: .askUser,
        path: nil,
        reason: .executionError("ask_user must be answered by the user before it completes.")
      )
    )
  }
}

public struct WebSearchToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.webSearch

  public init() {}

  public func evaluatePermission(
    _ input: WebSearchInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    return webPermissionEvaluation(context.webAccessSettings)
  }

  public func previewApproval(
    _ input: WebSearchInput,
    context: ToolContext
  ) async -> ToolResultPreview? {
    let (query, queryTruncated) = WebAccessLimits.cappedQuery(input.query)
    guard !query.isEmpty else {
      return ToolResultPreview(status: .failed, text: "Search query is empty.")
    }
    let truncatedText = queryTruncated ? "\nQuery was capped before it would be sent." : ""
    return ToolResultPreview(
      text: """
        Web search requires approval.
        Provider: \(context.webAccessSettings.provider.displayName)
        Query: \(query)
        Max results: \(WebAccessLimits.cappedResultCount(input.maxResults))\(truncatedText)
        """
    )
  }

  public func run(_ input: WebSearchInput, context: ToolContext) async -> ToolResultPayload {
    guard context.webAccessSettings.policy != .off else {
      return .webSearch(.failed(query: input.query, reason: .permissionDenied))
    }
    let maxResults = WebAccessLimits.cappedResultCount(input.maxResults)
    let result = await context.webSearcher.search(
      WebSearchRequest(
        query: input.query,
        maxResults: maxResults,
        settings: context.webAccessSettings
      )
    )
    return .webSearch(result)
  }
}

public struct WebFetchToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.webFetch
  private let urlValidator = WebURLValidator()

  public init() {}

  public func evaluatePermission(
    _ input: WebFetchInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    guard let url = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: WebAccessError.invalidURL(input.url).localizedDescription,
        riskLevel: .high
      )
    }
    if let error = urlValidator.validatePublicHTTPURL(url) {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .high
      )
    }
    return webPermissionEvaluation(context.webAccessSettings)
  }

  public func previewApproval(
    _ input: WebFetchInput,
    context: ToolContext
  ) async -> ToolResultPreview? {
    ToolResultPreview(
      text: """
        Web fetch requires approval.
        URL: \(input.url)
        Max bytes: \(WebAccessLimits.cappedFetchBytes(input.maxBytes))
        """
    )
  }

  public func run(_ input: WebFetchInput, context: ToolContext) async -> ToolResultPayload {
    guard context.webAccessSettings.policy != .off else {
      return .webFetch(.failed(url: input.url, finalURL: nil, reason: .permissionDenied))
    }
    guard let url = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return .webFetch(
        .failed(
          url: input.url,
          finalURL: nil,
          reason: .invalidArguments(
            .parserError(WebAccessError.invalidURL(input.url).localizedDescription))
        )
      )
    }
    let result = await context.webFetcher.fetch(
      WebFetchRequest(
        url: url,
        maxBytes: WebAccessLimits.cappedFetchBytes(input.maxBytes)
      )
    )
    return .webFetch(result)
  }
}

private func webPermissionEvaluation(
  _ settings: WebAccessSettings
) -> ToolPermissionEvaluation {
  switch settings.policy {
  case .off:
    return ToolPermissionEvaluation(
      decision: .denied,
      reason: "Web access is disabled.",
      riskLevel: .high
    )
  case .askEachTime:
    return ToolPermissionEvaluation(
      decision: .requiresApproval,
      reason: "Web access requires approval.",
      riskLevel: .high
    )
  case .allow:
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Web access is allowed.",
      riskLevel: .high
    )
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

public struct ReadFileToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.readFile

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

public struct ShowFileToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.showFile

  private let readFileExecutor: ReadFileToolExecutor

  public init(maxBytes: Int = 40 * 1024) {
    readFileExecutor = ReadFileToolExecutor(maxBytes: maxBytes)
  }

  public func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    readFileExecutor.evaluatePermission(input, context: context)
  }

  public func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    await readFileExecutor.run(input, context: context)
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

public struct ListFilesInput: Codable, Equatable, Sendable {
  public let path: String?
}

public struct ListFilesToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.listFiles

  private let maxDepth: Int
  private let maxEntries: Int
  private let skippedNames: Set<String>

  public init(
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

  public func evaluatePermission(
    _ input: ListFilesInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path ?? ".")
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Listing files inside the workspace is allowed.",
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

  public func run(_ input: ListFilesInput, context: ToolContext) async -> ToolResultPayload {
    let path = input.path ?? "."
    var resolvedURL: URL?

    do {
      return try context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(path)
        resolvedURL = rootURL
        let rootPath = context.workspace.relativePath(for: rootURL)
        var entries: [String] = []
        var truncated = false
        try appendEntries(
          at: rootURL,
          displayPrefix: "",
          depth: 0,
          entries: &entries,
          truncated: &truncated
        )

        return .listFiles(
          ListFilesResult(
            root: rootPath,
            entries: entries.map { entry in
              let isDirectory = entry.hasSuffix("/")
              let path = isDirectory ? String(entry.dropLast()) : entry
              let workspacePath =
                rootPath.rawValue == "." ? path : rootPath.rawValue + "/" + path
              return WorkspaceFileEntry(
                path: WorkspaceRelativePath(rawValue: workspacePath),
                kind: isDirectory ? .directory : .file
              )
            },
            truncated: truncated
          )
        )
      }
    } catch {
      return .failure(
        ToolFailure(
          toolName: .listFiles,
          path: ToolResultFailureMapper.relativePath(
            for: path, resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.reason(from: error)
        )
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

public struct WriteFileInput: Codable, Equatable, Sendable {
  public let path: String
  public let content: String
}

public struct WriteFileToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.writeFile

  public func evaluatePermission(
    _ input: WriteFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Writing files inside the workspace requires approval.",
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

  public func run(_ input: WriteFileInput, context: ToolContext) async -> ToolResultPayload {
    var resolvedURL: URL?
    do {
      return try context.workspace.withSecurityScopedAccess {
        let resolvedPathURL = try context.workspace.resolveAllowedPath(input.path)
        resolvedURL = resolvedPathURL
        let relativePath = context.workspace.relativePath(for: resolvedPathURL)
        try FileManager.default.createDirectory(
          at: resolvedPathURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try input.content.write(to: resolvedPathURL, atomically: true, encoding: .utf8)
        return .writeFile(
          .success(path: relativePath, bytesWritten: input.content.utf8.count)
        )
      }
    } catch {
      return .writeFile(
        .failed(
          path: ToolResultFailureMapper.relativePath(
            for: input.path, resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }
}

public enum ToolInputDecodingError: LocalizedError, Equatable {
  case unknownArguments([String])
  case payloadMismatch(expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .unknownArguments(let arguments):
      "Unknown argument(s): \(arguments.joined(separator: ", "))."
    case .payloadMismatch(let expected, let actual):
      "Tool payload mismatch. Expected \(expected), got \(actual)."
    }
  }
}

public enum ToolInputDecoder {
  public static func decode<Input: Decodable>(
    _ inputType: Input.Type,
    from arguments: ToolCallArguments
  ) throws -> Input {
    let data = try JSONEncoder().encode(arguments)
    return try JSONDecoder().decode(inputType, from: data)
  }
}

public struct ToolOrchestrator: Sendable {
  private let executorRegistry: ToolExecutorRegistry
  private let validator: ToolCallRequestValidator
  private let readTracker: ReadFileReadTracker
  private let latestCommandResultStore: LatestCommandResultStore
  private let webSearcher: any WebSearching
  private let webFetcher: any WebFetching
  private let webAccessSettingsProvider: @Sendable () async -> WebAccessSettings

  public init(
    executorRegistry: ToolExecutorRegistry = .readOnly,
    validator: ToolCallRequestValidator = ToolCallRequestValidator(),
    readTracker: ReadFileReadTracker = ReadFileReadTracker(),
    latestCommandResultStore: LatestCommandResultStore = LatestCommandResultStore(),
    webSearcher: any WebSearching = DefaultWebSearchService(),
    webFetcher: any WebFetching = DefaultWebFetchService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) {
    self.executorRegistry = executorRegistry
    self.validator = validator
    self.readTracker = readTracker
    self.latestCommandResultStore = latestCommandResultStore
    self.webSearcher = webSearcher
    self.webFetcher = webFetcher
    self.webAccessSettingsProvider = webAccessSettingsProvider
  }

  public var toolRegistry: ToolRegistry {
    executorRegistry.toolRegistry
  }

  public func execute(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    let request = validator.validate(rawRequest, registry: executorRegistry.toolRegistry)
    return await executeValidated(request: request, workspace: workspace, isApproved: false)
  }

  public func executeApproved(request: ToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    let request = validator.validate(request.raw, registry: executorRegistry.toolRegistry)
    return await executeValidated(request: request, workspace: workspace, isApproved: true)
  }

  public func executeApproved(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    let request = validator.validate(rawRequest, registry: executorRegistry.toolRegistry)
    return await executeValidated(request: request, workspace: workspace, isApproved: true)
  }

  private func executeValidated(
    request: ToolCallRequest,
    workspace: Workspace,
    isApproved: Bool
  ) async -> ToolCallRecord {
    guard request.workspaceID == workspace.id else {
      let message = "Tool call workspace does not match the active workspace."
      return deniedRecord(request: request, message: message)
    }

    if case .invalid(let invalidInput) = request.payload {
      return invalidToolCallRecord(request: request, invalidInput: invalidInput)
    }

    guard let executor = executorRegistry.executor(for: request.toolName) else {
      let message = "Unknown tool: \(request.toolName.rawValue)."
      return failedRecord(request: request, message: message, riskLevel: .high)
    }

    let webAccessSettings = await webAccessSettingsProvider()

    if isApproved {
      return await executor.runApproved(
        request,
        context: ToolContext(
          workspace: workspace,
          sessionID: request.sessionID,
          readTracker: readTracker,
          latestCommandResultStore: latestCommandResultStore,
          webAccessSettings: webAccessSettings,
          webSearcher: webSearcher,
          webFetcher: webFetcher
        )
      )
    }

    return await executor.run(
      request,
      context: ToolContext(
        workspace: workspace,
        sessionID: request.sessionID,
        readTracker: readTracker,
        latestCommandResultStore: latestCommandResultStore,
        webAccessSettings: webAccessSettings,
        webSearcher: webSearcher,
        webFetcher: webFetcher
      )
    )
  }

  private func invalidToolCallRecord(
    request: ToolCallRequest,
    invalidInput: InvalidToolInput
  ) -> ToolCallRecord {
    let message = invalidInput.reason.message
    return failedRecord(
      request: request,
      payload: .invalidTool(
        InvalidToolResult(originalName: invalidInput.originalName, reason: invalidInput.reason)
      ),
      message: message,
      riskLevel: .high
    )
  }

  private func deniedRecord(request: ToolCallRequest, message: String) -> ToolCallRecord {
    ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: message,
        riskLevel: .high
      ),
      events: requestedEvents(request: request)
        + [ToolCallEvent(actor: .system, kind: .denied, message: message)],
      state: .denied(
        .failure(
          ToolFailure(
            toolName: request.toolName,
            path: nil,
            reason: .permissionDenied,
            recovery: .askUser(message: message)
          )))
    )
  }

  private func failedRecord(
    request: ToolCallRequest,
    payload: ToolResultPayload? = nil,
    message: String,
    riskLevel: ToolRiskLevel
  ) -> ToolCallRecord {
    let resultPayload =
      payload
      ?? .failure(
        ToolFailure(toolName: request.toolName, path: nil, reason: .executionError(message)))
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: message,
        riskLevel: riskLevel
      ),
      events: requestedEvents(request: request)
        + [ToolCallEvent(actor: .system, kind: .failed, message: message)],
      state: .failed(resultPayload)
    )
  }

  private func requestedEvents(request: ToolCallRequest) -> [ToolCallEvent] {
    [
      ToolCallEvent(
        actor: .assistant,
        kind: .requested,
        message: "Requested \(request.toolName.rawValue)."
      )
    ]
  }
}
