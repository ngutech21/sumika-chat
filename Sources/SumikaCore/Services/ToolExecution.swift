import Foundation

public struct ToolContext: Sendable {
  public let workspace: Workspace
  public let sessionID: ChatSession.ID?
  public let readTracker: ReadFileReadTracker?
  public let latestCommandResultStore: LatestCommandResultStore?
  public let webAccessSettings: WebAccessSettings
  public let webSearcher: any WebSearching
  public let webFetcher: any WebFetching
  public let browserToolService: any BrowserToolServing

  public init(
    workspace: Workspace,
    sessionID: ChatSession.ID? = nil,
    readTracker: ReadFileReadTracker? = nil,
    latestCommandResultStore: LatestCommandResultStore? = nil,
    webAccessSettings: WebAccessSettings = .disabled,
    webSearcher: any WebSearching = DefaultWebSearchService(),
    webFetcher: any WebFetching = DefaultWebFetchService(),
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService()
  ) {
    self.workspace = workspace
    self.sessionID = sessionID
    self.readTracker = readTracker
    self.latestCommandResultStore = latestCommandResultStore
    self.webAccessSettings = webAccessSettings
    self.webSearcher = webSearcher
    self.webFetcher = webFetcher
    self.browserToolService = browserToolService
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
  static func input(from payload: ToolCallPayload) throws -> Input

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
      guard request.payload.toolName == T.definition.name else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: T.definition.name.rawValue,
          actual: request.payload.toolName.rawValue
        )
      }
      let input = try T.input(from: request.payload)
      let evaluation = tool.evaluatePermission(input, context: context)
      record.evaluation = evaluation

      if T.definition.name == .askUser && !isApproved {
        guard shouldRun(evaluation: evaluation, isApproved: isApproved, record: &record) else {
          return record
        }
        record.state = .awaitingUserAnswer
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
        tool, input: input, record: record, context: context)
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
      let payload =
        preview.resultPayload
        ?? ToolResultPayload.failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: firstPath(in: preview),
            reason: .executionError(preview.text)
          ))
      record.state = .failed(payload)
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
      return true
    case .requiresApproval:
      let preview = record.approvalPreview
      record.state = .awaitingApproval(preview: preview)
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
      return false
    }
  }

  private static func firstPath(in preview: ToolResultPreview) -> WorkspaceRelativePath? {
    preview.affectedPaths.first.map { WorkspaceRelativePath(rawValue: $0) }
  }

  private static func runEvaluatedTool<T: TypedToolExecutor>(
    _ tool: T,
    input: T.Input,
    record: ToolCallRecord,
    context: ToolContext
  ) async -> ToolCallRecord {
    var record = record
    record.state = .running

    let payload = await tool.run(input, context: context)
    let preview = payload.preview

    if case .runCommand = payload {
      record.state = .completed(payload)
      return record
    }

    switch preview.status {
    case .success:
      record.state = .completed(payload)
    case .failed:
      record.state = .failed(payload)
    case .denied:
      record.state = .denied(payload)
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
    return record
  }

  private static func makePendingRecord(request: ToolCallRequest) -> ToolCallRecord {
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: "Tool call has not been evaluated.",
        riskLevel: .low
      ),
      state: .pending
    )
  }
}

public struct ToolExecutorRegistry: Sendable {
  private static let chatWebExecutors = [
    AnyToolExecutor(WebSearchToolExecutor()),
    AnyToolExecutor(WebFetchToolExecutor()),
  ]

  private static let readOnlyExecutors = [
    AnyToolExecutor(ReadFileToolExecutor()),
    AnyToolExecutor(ShowFileToolExecutor()),
    AnyToolExecutor(ListFilesToolExecutor()),
    AnyToolExecutor(GlobFilesToolExecutor()),
    AnyToolExecutor(SearchFilesToolExecutor()),
    AnyToolExecutor(WorkspaceDiffToolExecutor()),
    AnyToolExecutor(WorkspaceDiagnosticsToolExecutor()),
  ]

  private static func codingAgentExecutors(todoWriteEnabled: Bool) -> [AnyToolExecutor] {
    var executors = [
      AnyToolExecutor(ReadFileToolExecutor()),
      AnyToolExecutor(ShowFileToolExecutor()),
      AnyToolExecutor(ListFilesToolExecutor()),
      AnyToolExecutor(GlobFilesToolExecutor()),
      AnyToolExecutor(SearchFilesToolExecutor()),
      AnyToolExecutor(WorkspaceDiffToolExecutor()),
      AnyToolExecutor(WorkspaceDiagnosticsToolExecutor()),
      AnyToolExecutor(BrowserRefreshToolExecutor()),
      AnyToolExecutor(BrowserInspectToolExecutor()),
      AnyToolExecutor(EditFileToolExecutor()),
      AnyToolExecutor(WriteFileToolExecutor()),
      AnyToolExecutor(RunCommandToolExecutor()),
    ]
    if todoWriteEnabled {
      executors.append(AnyToolExecutor(TodoWriteToolExecutor()))
    }
    executors.append(contentsOf: [
      AnyToolExecutor(AskUserToolExecutor()),
      AnyToolExecutor(WebSearchToolExecutor()),
      AnyToolExecutor(WebFetchToolExecutor()),
    ])
    return executors
  }

  public static let chatWeb = ToolExecutorRegistry(chatWebExecutors)

  public static let readOnly = ToolExecutorRegistry(readOnlyExecutors)

  public static let codingAgent = codingAgentRegistry(todoWriteEnabled: true)

  public static func codingAgentRegistry(todoWriteEnabled: Bool) -> ToolExecutorRegistry {
    ToolExecutorRegistry(codingAgentExecutors(todoWriteEnabled: todoWriteEnabled))
  }

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

public enum ToolInputDecodingError: LocalizedError, Equatable {
  case unknownArguments([String])
  case payloadMismatch(expected: String, actual: String)
  case inputExtractionFailed(toolName: String)

  public var errorDescription: String? {
    switch self {
    case .unknownArguments(let arguments):
      "Unknown argument(s): \(arguments.joined(separator: ", "))."
    case .payloadMismatch(let expected, let actual):
      "Tool payload mismatch. Expected \(expected), got \(actual)."
    case .inputExtractionFailed(let toolName):
      "Tool input extraction failed for \(toolName)."
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
  private let browserToolService: any BrowserToolServing
  private let webAccessSettingsProvider: @Sendable () async -> WebAccessSettings

  public init(
    executorRegistry: ToolExecutorRegistry = .readOnly,
    validator: ToolCallRequestValidator = ToolCallRequestValidator(),
    readTracker: ReadFileReadTracker = ReadFileReadTracker(),
    latestCommandResultStore: LatestCommandResultStore = LatestCommandResultStore(),
    webSearcher: any WebSearching = DefaultWebSearchService(),
    webFetcher: any WebFetching = DefaultWebFetchService(),
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
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
    self.browserToolService = browserToolService
    self.webAccessSettingsProvider = webAccessSettingsProvider
  }

  public var toolRegistry: ToolRegistry {
    executorRegistry.toolRegistry
  }

  public func replacingExecutorRegistry(_ executorRegistry: ToolExecutorRegistry)
    -> ToolOrchestrator
  {
    ToolOrchestrator(
      executorRegistry: executorRegistry,
      validator: validator,
      readTracker: readTracker,
      latestCommandResultStore: latestCommandResultStore,
      webSearcher: webSearcher,
      webFetcher: webFetcher,
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
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
          webFetcher: webFetcher,
          browserToolService: browserToolService
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
        webFetcher: webFetcher,
        browserToolService: browserToolService
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
      state: .failed(resultPayload)
    )
  }
}
