import Foundation

struct ToolContext: Sendable {
  let workspace: Workspace
  let sessionID: ChatSession.ID?
  let readTracker: ReadFileReadTracker?
  let latestCommandResultStore: LatestCommandResultStore?
  let webAccessSettings: WebAccessSettings
  let webSearcher: any WebSearching
  let webFetcher: any WebFetching
  let browserToolService: any BrowserToolServing

  init(
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

protocol TypedToolExecutor: Sendable {
  associatedtype Input: Decodable & Sendable

  static var codec: ToolCodec<Input> { get }

  func evaluatePermission(_ input: Input, context: ToolContext) -> ToolPermissionEvaluation
  func previewApproval(_ input: Input, context: ToolContext) async -> ToolResultPreview?
  func run(_ input: Input, context: ToolContext) async -> ToolResultPayload
}

extension TypedToolExecutor {
  func previewApproval(_ input: Input, context: ToolContext) async -> ToolResultPreview? {
    nil
  }
}

/// Executor whose codec (and thus definition) is instance state instead of a
/// static requirement. Dynamic tools such as MCP server tools are only known
/// at runtime, so their definitions cannot be compile-time constants. They run
/// through the same permission/approval/result state machine as typed tools.
protocol DynamicToolExecutor: Sendable {
  associatedtype Input: Decodable & Sendable

  var codec: ToolCodec<Input> { get }

  func evaluatePermission(_ input: Input, context: ToolContext) -> ToolPermissionEvaluation
  func previewApproval(_ input: Input, context: ToolContext) async -> ToolResultPreview?
  func run(_ input: Input, context: ToolContext) async -> ToolResultPayload
}

extension DynamicToolExecutor {
  func previewApproval(_ input: Input, context: ToolContext) async -> ToolResultPreview? {
    nil
  }
}

/// Bridges the static-codec `TypedToolExecutor` shape onto the instance-codec
/// execution path so both executor kinds share one state machine.
private struct TypedExecutorAdapter<T: TypedToolExecutor>: DynamicToolExecutor {
  let tool: T

  var codec: ToolCodec<T.Input> { T.codec }

  func evaluatePermission(_ input: T.Input, context: ToolContext) -> ToolPermissionEvaluation {
    tool.evaluatePermission(input, context: context)
  }

  func previewApproval(_ input: T.Input, context: ToolContext) async -> ToolResultPreview? {
    await tool.previewApproval(input, context: context)
  }

  func run(_ input: T.Input, context: ToolContext) async -> ToolResultPayload {
    await tool.run(input, context: context)
  }
}

struct AnyToolExecutor: Sendable {
  let definition: ToolDefinition
  /// Present only for dynamic executors: lets the request validator decode
  /// raw arguments for tools without a built-in codec catalog entry.
  let dynamicCodec: AnyToolCodec?
  private let runHandler: @Sendable (ToolCallRequest, ToolContext) async -> ToolCallRecord
  private let approvedRunHandler:
    @Sendable (ToolCallRequest, ToolPermissionEvaluation?, ToolContext) async -> ToolCallRecord

  init<T: TypedToolExecutor>(_ tool: T) {
    self.init(executor: TypedExecutorAdapter(tool: tool), dynamicCodec: nil)
  }

  init<T: DynamicToolExecutor>(dynamic tool: T) {
    self.init(executor: tool, dynamicCodec: AnyToolCodec(tool.codec))
  }

  private init<T: DynamicToolExecutor>(executor tool: T, dynamicCodec: AnyToolCodec?) {
    definition = tool.codec.definition
    self.dynamicCodec = dynamicCodec
    runHandler = { request, context in
      await Self.evaluateAndRun(tool, request: request, context: context, isApproved: false)
    }

    approvedRunHandler = { request, approvedEvaluation, context in
      await Self.evaluateAndRun(
        tool,
        request: request,
        context: context,
        isApproved: true,
        approvedEvaluation: approvedEvaluation
      )
    }
  }

  func run(_ request: ToolCallRequest, context: ToolContext) async -> ToolCallRecord {
    await runHandler(request, context)
  }

  func runApproved(
    _ request: ToolCallRequest,
    approvedEvaluation: ToolPermissionEvaluation? = nil,
    context: ToolContext
  ) async -> ToolCallRecord {
    await approvedRunHandler(request, approvedEvaluation, context)
  }

  private static func evaluateAndRun<T: DynamicToolExecutor>(
    _ tool: T,
    request: ToolCallRequest,
    context: ToolContext,
    isApproved: Bool,
    approvedEvaluation: ToolPermissionEvaluation? = nil
  ) async -> ToolCallRecord {
    var record = makePendingRecord(request: request)
    let definition = tool.codec.definition

    do {
      guard request.payload.toolName == definition.name else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: definition.name.rawValue,
          actual: request.payload.toolName.rawValue
        )
      }
      let input = try tool.codec.input(from: request.payload)
      let evaluation = tool.evaluatePermission(input, context: context)
      record.evaluation = evaluation

      if isApproved,
        let approvedEvaluation,
        evaluation.decision != .denied,
        approvalScopeChanged(from: approvedEvaluation, to: evaluation)
      {
        let previewIsValid = await prepareApprovalPreview(
          tool,
          input: input,
          evaluation: evaluation,
          record: &record,
          context: context
        )
        if previewIsValid, record.status == .pending {
          record.state = .awaitingApproval(preview: nil)
        }
        return record
      }

      if definition.name == .askUser && !isApproved {
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
      return failedRecord(request: request, definition: definition, error: error)
    }
  }

  private static func approvalScopeChanged(
    from approved: ToolPermissionEvaluation,
    to current: ToolPermissionEvaluation
  ) -> Bool {
    let approvedNormalizedPaths = Set(approved.normalizedPaths)
    let currentNormalizedPaths = Set(current.normalizedPaths)
    let approvedRelativePaths = Set(approved.workspaceRelativePaths.map(\.rawValue))
    let currentRelativePaths = Set(current.workspaceRelativePaths.map(\.rawValue))
    return approvedNormalizedPaths != currentNormalizedPaths
      || approvedRelativePaths != currentRelativePaths
      || approved.riskLevel != current.riskLevel
  }

  private static func prepareApprovalPreview<T: DynamicToolExecutor>(
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

  private static func runEvaluatedTool<T: DynamicToolExecutor>(
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

struct ToolExecutorRegistry: Sendable {
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

  static let chatWeb = ToolExecutorRegistry(chatWebExecutors)

  static let readOnly = ToolExecutorRegistry(readOnlyExecutors)

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

  /// Codecs of dynamic executors in this registry, keyed by tool name. The
  /// request validator uses these to decode tools that have no entry in the
  /// built-in codec catalog.
  var dynamicCodecs: [ToolName: AnyToolCodec] {
    var codecs: [ToolName: AnyToolCodec] = [:]
    for executor in orderedExecutors {
      if let codec = executor.dynamicCodec {
        codecs[executor.definition.name] = codec
      }
    }
    return codecs
  }

  /// Returns a registry with `additional` executors appended. Existing tool
  /// names win over additions, and duplicate names within `additional` keep
  /// their first occurrence, so composed registries never crash the
  /// unique-name index.
  func merging(_ additional: [AnyToolExecutor]) -> ToolExecutorRegistry {
    var executors = orderedExecutors
    var seenNames = Set(executors.map(\.definition.name))
    for executor in additional where !seenNames.contains(executor.definition.name) {
      executors.append(executor)
      seenNames.insert(executor.definition.name)
    }
    return ToolExecutorRegistry(executors)
  }
}

enum ToolInputDecodingError: LocalizedError, Equatable {
  case unknownArguments([String])
  case payloadMismatch(expected: String, actual: String)
  case inputExtractionFailed(toolName: String)

  var errorDescription: String? {
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

enum ToolInputDecoder {
  static func decode<Input: Decodable>(
    _ inputType: Input.Type,
    from arguments: ToolCallArguments
  ) throws -> Input {
    let data = try JSONEncoder().encode(arguments)
    return try JSONDecoder().decode(inputType, from: data)
  }
}

package struct ToolOrchestrator: Sendable {
  let executorRegistry: ToolExecutorRegistry
  private let validator: ToolCallRequestValidator
  private let readTracker: ReadFileReadTracker
  private let latestCommandResultStore: LatestCommandResultStore
  private let webSearcher: any WebSearching
  private let webFetcher: any WebFetching
  private let browserToolService: any BrowserToolServing
  private let webAccessSettingsProvider: @Sendable () async -> WebAccessSettings

  package init(
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) {
    self.init(
      executorRegistry: .readOnly,
      validator: ToolCallRequestValidator(),
      readTracker: ReadFileReadTracker(),
      latestCommandResultStore: LatestCommandResultStore(),
      webSearcher: DefaultWebSearchService(),
      webFetcher: DefaultWebFetchService(),
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
  }

  init(
    executorRegistry: ToolExecutorRegistry,
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) {
    self.init(
      executorRegistry: executorRegistry,
      validator: ToolCallRequestValidator(),
      readTracker: ReadFileReadTracker(),
      latestCommandResultStore: LatestCommandResultStore(),
      webSearcher: DefaultWebSearchService(),
      webFetcher: DefaultWebFetchService(),
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
  }

  init(
    executorRegistry: ToolExecutorRegistry = .readOnly,
    webSearcher: any WebSearching,
    webFetcher: any WebFetching = DefaultWebFetchService(),
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) {
    self.init(
      executorRegistry: executorRegistry,
      validator: ToolCallRequestValidator(),
      readTracker: ReadFileReadTracker(),
      latestCommandResultStore: LatestCommandResultStore(),
      webSearcher: webSearcher,
      webFetcher: webFetcher,
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
  }

  init(
    executorRegistry: ToolExecutorRegistry = .readOnly,
    webFetcher: any WebFetching,
    webSearcher: any WebSearching = DefaultWebSearchService(),
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) {
    self.init(
      executorRegistry: executorRegistry,
      validator: ToolCallRequestValidator(),
      readTracker: ReadFileReadTracker(),
      latestCommandResultStore: LatestCommandResultStore(),
      webSearcher: webSearcher,
      webFetcher: webFetcher,
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
  }

  init(
    executorRegistry: ToolExecutorRegistry = .readOnly,
    latestCommandResultStore: LatestCommandResultStore,
    webSearcher: any WebSearching = DefaultWebSearchService(),
    webFetcher: any WebFetching = DefaultWebFetchService(),
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) {
    self.init(
      executorRegistry: executorRegistry,
      validator: ToolCallRequestValidator(),
      readTracker: ReadFileReadTracker(),
      latestCommandResultStore: latestCommandResultStore,
      webSearcher: webSearcher,
      webFetcher: webFetcher,
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
  }

  private init(
    executorRegistry: ToolExecutorRegistry,
    validator: ToolCallRequestValidator,
    readTracker: ReadFileReadTracker,
    latestCommandResultStore: LatestCommandResultStore,
    webSearcher: any WebSearching,
    webFetcher: any WebFetching,
    browserToolService: any BrowserToolServing,
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings
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

  var toolRegistry: ToolRegistry {
    executorRegistry.toolRegistry
  }

  func replacingExecutorRegistry(_ executorRegistry: ToolExecutorRegistry)
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

  func execute(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    let request = validator.validate(
      rawRequest,
      registry: executorRegistry.toolRegistry,
      dynamicCodecs: executorRegistry.dynamicCodecs
    )
    return await executeValidated(request: request, workspace: workspace, isApproved: false)
  }

  func executeApproved(request: ToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    let request = validator.validate(
      request.raw,
      registry: executorRegistry.toolRegistry,
      dynamicCodecs: executorRegistry.dynamicCodecs
    )
    return await executeValidated(
      request: request,
      workspace: workspace,
      isApproved: true,
      approvedEvaluation: nil
    )
  }

  func executeApproved(
    request: ToolCallRequest,
    approvedEvaluation: ToolPermissionEvaluation,
    workspace: Workspace
  ) async -> ToolCallRecord {
    let request = validator.validate(
      request.raw,
      registry: executorRegistry.toolRegistry,
      dynamicCodecs: executorRegistry.dynamicCodecs
    )
    return await executeValidated(
      request: request,
      workspace: workspace,
      isApproved: true,
      approvedEvaluation: approvedEvaluation
    )
  }

  func executeApproved(request rawRequest: RawToolCallRequest, workspace: Workspace) async
    -> ToolCallRecord
  {
    let request = validator.validate(
      rawRequest,
      registry: executorRegistry.toolRegistry,
      dynamicCodecs: executorRegistry.dynamicCodecs
    )
    return await executeValidated(
      request: request,
      workspace: workspace,
      isApproved: true,
      approvedEvaluation: nil
    )
  }

  private func executeValidated(
    request: ToolCallRequest,
    workspace: Workspace,
    isApproved: Bool,
    approvedEvaluation: ToolPermissionEvaluation? = nil
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
        approvedEvaluation: approvedEvaluation,
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
