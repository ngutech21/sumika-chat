import Foundation

protocol ToolOrchestrating: Sendable {
  var toolRegistry: ToolRegistry { get }

  func execute(request: RawToolCallRequest, workspace: Workspace) async -> ToolCallRecord
}

extension ToolOrchestrator: ToolOrchestrating {}

enum ToolExecutionProfile: Equatable, Sendable {
  case disabled
  case chatWeb
  case agent

  var allowsToolLoop: Bool {
    self != .disabled
  }
}

struct ToolLoopRequest: Sendable {
  let workspace: Workspace
  let sessionID: ChatSession.ID
  let turnID: ChatTurn.ID
  let assistantMessageID: UUID
  let items: [ChatTurnItem]
  let focusedFileState: FocusedFileState
  let interactionMode: WorkspaceInteractionMode
  let followUpPromptMode: ToolPromptMode
  let toolLoopIteration: Int?
  let toolCallingPolicy: ToolCallingPolicy
  let nativeToolCalls: [ChatRuntimeToolCall]
  let approvalPolicyProvider: @Sendable () async -> ToolApprovalPolicy

  init(
    workspace: Workspace,
    sessionID: ChatSession.ID,
    turnID: ChatTurn.ID,
    assistantMessageID: UUID,
    items: [ChatTurnItem],
    focusedFileState: FocusedFileState = .empty,
    interactionMode: WorkspaceInteractionMode = .agent,
    followUpPromptMode: ToolPromptMode = .afterToolResultCanContinue,
    toolLoopIteration: Int? = nil,
    toolCallingPolicy: ToolCallingPolicy = .nativeMLX,
    nativeToolCalls: [ChatRuntimeToolCall] = [],
    approvalPolicyProvider: @escaping @Sendable () async -> ToolApprovalPolicy = { .manual }
  ) {
    self.workspace = workspace
    self.sessionID = sessionID
    self.turnID = turnID
    self.assistantMessageID = assistantMessageID
    self.items = items
    self.focusedFileState = focusedFileState
    self.interactionMode = interactionMode
    self.followUpPromptMode = followUpPromptMode
    self.toolLoopIteration = toolLoopIteration
    self.toolCallingPolicy = toolCallingPolicy
    self.nativeToolCalls = nativeToolCalls
    self.approvalPolicyProvider = approvalPolicyProvider
  }
}

struct ToolLoopCoordinator: Sendable {
  private let focusedFileReducer: FocusedFileStateReducer
  private let turnTracer: any TurnTracing

  init(
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.focusedFileReducer = focusedFileReducer
    self.turnTracer = turnTracer
  }

  func run(
    _ request: ToolLoopRequest,
    using toolOrchestrator: any ToolOrchestrating
  ) async throws -> ChatWorkflowStep? {
    try Task.checkCancellation()
    let toolRegistry = toolOrchestrator.toolRegistry
    guard !toolRegistry.tools.isEmpty
    else {
      return nil
    }

    let parseStartedAt = Date()
    let parsedAction =
      if request.nativeToolCalls.isEmpty {
        ToolLoopParsedAction.none
      } else {
        ToolLoopNativeToolParser.parse(
          request.nativeToolCalls,
          policy: request.toolCallingPolicy,
          registry: toolRegistry,
          workspaceID: request.workspace.id,
          sessionID: request.sessionID,
          reservedIDs: Set(
            request.items.compactMap { item in
              guard case .tool(let record) = item else {
                return nil
              }
              return record.id
            })
        )
      }
    await traceToolPhase(
      .toolParse,
      startedAt: parseStartedAt,
      request: request,
      toolName: parsedAction.toolName
    )

    switch parsedAction {
    case .none:
      return nil
    case .toolCalls(let outputs):
      return await executeToolCalls(
        outputs,
        request: request,
        registry: toolRegistry,
        toolOrchestrator: toolOrchestrator
      )
    }
  }

  private func traceToolPhase(
    _ phase: TurnTracePhase,
    startedAt: Date,
    request: ToolLoopRequest,
    toolName: String?
  ) async {
    await turnTracer.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: request.turnID,
        generationID: nil,
        phase: phase,
        durationMs: Date().timeIntervalSince(startedAt) * 1000,
        messageCount: request.items.count,
        toolLoopIteration: request.toolLoopIteration,
        toolName: toolName,
        interactionMode: request.interactionMode
      )
    )
  }

  private func executeToolCalls(
    _ outputs: [ToolCallParseOutput],
    request: ToolLoopRequest,
    registry: ToolRegistry,
    toolOrchestrator: any ToolOrchestrating
  ) async -> ChatWorkflowStep {
    guard !outputs.isEmpty else {
      return ChatWorkflowStep(events: [], continuation: .none)
    }

    if let invalidReason = invalidBatchReason(
      outputs,
      request: request,
      registry: registry
    ) {
      return await invalidBatchStep(
        outputs,
        request: request,
        message: invalidReason
      )
    }

    let nextAssistantMessageID = UUID()
    var events: [ChatWorkflowEvent] = []
    var focusedFileState = request.focusedFileState
    var nextFollowUpPromptMode = request.followUpPromptMode
    var seenItems = request.items
    var isAwaitingApproval = false
    var isAwaitingUserAnswer = false
    var batchAnchorID: ToolCallRecord.ID?

    for output in outputs {
      let record: ToolCallRecord
      if let duplicateRecord = duplicateToolCallRecord(
        for: output,
        registry: registry,
        workspace: request.workspace,
        items: seenItems
      ) {
        record = duplicateRecord
      } else {
        let executeStartedAt = Date()
        record = await toolOrchestrator.execute(
          request: output.request,
          workspace: request.workspace
        )
        await traceToolExecution(
          startedAt: executeStartedAt,
          loopRequest: request,
          rawRequest: output.request,
          record: record
        )
      }
      seenItems.append(.tool(record))
      if batchAnchorID == nil {
        batchAnchorID = record.id
      }

      events.append(
        .assistantAnnotatedAsNativeToolCall(
          assistantMessageID: request.assistantMessageID,
          toolCall: output.modelMessage
        ))
      events.append(.toolCallAppended(record, turnID: request.turnID))

      if record.status == .awaitingApproval {
        isAwaitingApproval = true
        continue
      }

      if record.status == .awaitingUserAnswer {
        isAwaitingUserAnswer = true
        continue
      }

      if let todoState = todoState(from: record) {
        events.append(.todoStateChanged(todoState))
      }

      let toolResult = toolResultMessage(output: output, record: record)
      events.append(.toolResultAppended(toolResult, turnID: request.turnID))

      let updatedFocusedFileState = focusedFileReducer.applyingToolResult(
        record.resultPayload,
        request: record.request,
        to: focusedFileState
      )
      if updatedFocusedFileState != focusedFileState {
        events.append(.focusedFileStateChanged(updatedFocusedFileState))
        focusedFileState = updatedFocusedFileState
      }

      nextFollowUpPromptMode = ToolFollowUpPromptPolicy.promptMode(
        default: nextFollowUpPromptMode,
        finalReason: finalReason(after: record)
      )

      if outputs.count == 1,
        let directResponse = ToolLoopDirectResponseRenderer.directResponse(
          after: record, toolResult: toolResult, request: request)
      {
        events.append(
          .assistantMessageAppended(
            content: directResponse.content,
            modelProjectionPolicy: directResponse.modelProjectionPolicy,
            messageID: nextAssistantMessageID,
            turnID: request.turnID
          ))
        return ChatWorkflowStep(events: events, continuation: .stopTurn)
      }
    }

    if isAwaitingUserAnswer {
      events.append(
        .turnStatusChanged(
          turnID: request.turnID,
          status: .awaitingUserAnswer,
          modelContextPolicy: nil
        ))
      return ChatWorkflowStep(events: events, continuation: .awaitingUserAnswer)
    }

    if isAwaitingApproval {
      events.append(
        .turnStatusChanged(
          turnID: request.turnID,
          status: .awaitingApproval,
          modelContextPolicy: nil
        ))
      let continuation: ChatWorkflowContinuation =
        if await request.approvalPolicyProvider() == .automatic,
          let batchAnchorID
        {
          .resumeAutomaticApproval(batchAnchorID: batchAnchorID)
        } else {
          .awaitingApproval
        }
      return ChatWorkflowStep(events: events, continuation: continuation)
    }

    events.append(
      .assistantPlaceholderAppended(messageID: nextAssistantMessageID, turnID: request.turnID))
    return ChatWorkflowStep(
      events: events,
      continuation: .resumeGeneration(
        assistantMessageID: nextAssistantMessageID,
        promptMode: nextFollowUpPromptMode
      )
    )
  }
}

extension ToolLoopCoordinator {
  private func invalidBatchReason(
    _ outputs: [ToolCallParseOutput],
    request: ToolLoopRequest,
    registry: ToolRegistry?
  ) -> String? {
    guard outputs.count > 1 else {
      return nil
    }

    if outputs.contains(where: { $0.request.toolName == .finishTask }) {
      return "finish_task must be the only native tool call in a response."
    }
    if outputs.contains(where: { $0.request.toolName == .askUser }) {
      return "ask_user must be the only native tool call in a response."
    }

    guard let registry else {
      return nil
    }

    var mutationPaths = Set<String>()
    for output in outputs {
      let validatedRequest = ToolCallRequestValidator().validate(
        output.request,
        registry: registry
      )
      let inputPath: String
      switch validatedRequest.payload {
      case .writeFile(let input):
        inputPath = input.path
      case .editFile(let input):
        inputPath = input.path
      default:
        continue
      }

      guard let resolvedPath = try? request.workspace.resolveAllowedPath(inputPath) else {
        continue
      }
      let normalizedPath = Workspace.normalizedPath(for: resolvedPath)
      if !mutationPaths.insert(normalizedPath).inserted {
        let relativePath = request.workspace.relativePath(for: resolvedPath).rawValue
        return
          "Multiple write_file/edit_file calls target the same normalized workspace path: \(relativePath)."
      }
    }

    return nil
  }

  private func invalidBatchStep(
    _ outputs: [ToolCallParseOutput],
    request: ToolLoopRequest,
    message: String
  ) async -> ChatWorkflowStep {
    var events: [ChatWorkflowEvent] = []
    for output in outputs {
      let invalidReason = InvalidToolCallReason.parserError(message)
      let invalidInput = InvalidToolInput(
        originalName: output.request.originalToolName ?? output.request.toolName.rawValue,
        rawArguments: output.request.arguments,
        reason: invalidReason
      )
      let invalidRequest = ToolCallRequest.invalid(
        raw: output.request,
        input: invalidInput
      )
      let record = ToolCallRecord(
        request: invalidRequest,
        evaluation: ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: .high
        ),
        state: .failed(
          .invalidTool(
            InvalidToolResult(
              originalName: invalidInput.originalName,
              reason: invalidReason
            )))
      )
      await traceToolExecution(
        startedAt: Date(),
        loopRequest: request,
        rawRequest: output.request,
        record: record
      )

      events.append(
        .assistantAnnotatedAsNativeToolCall(
          assistantMessageID: request.assistantMessageID,
          toolCall: output.modelMessage
        ))
      events.append(.toolCallAppended(record, turnID: request.turnID))
      events.append(
        .toolResultAppended(
          toolResultMessage(output: output, record: record),
          turnID: request.turnID
        ))
    }

    let nextAssistantMessageID = UUID()
    events.append(
      .assistantPlaceholderAppended(
        messageID: nextAssistantMessageID,
        turnID: request.turnID
      ))
    return ChatWorkflowStep(
      events: events,
      continuation: .resumeCorrectionGeneration(
        assistantMessageID: nextAssistantMessageID,
        promptMode: request.followUpPromptMode
      )
    )
  }

  private func toolResultMessage(
    output: ToolCallParseOutput,
    record: ToolCallRecord
  ) -> ToolResultModelMessage {
    ToolResultModelMessage(
      callID: output.request.id,
      toolName: output.request.toolName,
      payload: record.resultPayload
        ?? .failure(
          ToolFailure(
            toolName: output.request.toolName,
            path: nil,
            reason: .executionError(
              "Tool result unavailable for \(output.request.toolName.rawValue)."
            )
          ))
    )
  }

  private func duplicateToolCallRecord(
    for output: ToolCallParseOutput,
    registry: ToolRegistry,
    workspace: Workspace,
    items: [ChatTurnItem]
  ) -> ToolCallRecord? {
    let validatedRequest = ToolCallRequestValidator().validate(
      output.request,
      registry: registry
    )
    if case .invalid = validatedRequest.payload {
      return nil
    }
    return duplicateValidatedToolCallRecord(
      for: validatedRequest,
      workspace: workspace,
      items: items
    )
  }

  private func duplicateValidatedToolCallRecord(
    for validatedRequest: ToolCallRequest,
    workspace: Workspace,
    items: [ChatTurnItem]
  ) -> ToolCallRecord? {
    guard let signature = toolCallSignature(for: validatedRequest, workspace: workspace) else {
      return nil
    }

    let currentItems = currentTurnItems(in: items)
    for index in currentItems.indices.reversed() {
      guard case .tool(let previousRecord) = currentItems[index],
        previousRecord.status == .completed,
        toolCallSignature(for: previousRecord.request, workspace: workspace) == signature
      else {
        continue
      }

      guard
        let source = duplicateObservationSource(
          matching: signature,
          candidate: previousRecord,
          candidateIndex: index,
          workspace: workspace,
          items: currentItems
        )
      else {
        return nil
      }

      guard
        canReuseCompletedToolResult(
          source.record,
          after: source.index,
          workspace: workspace,
          in: currentItems
        )
      else {
        return nil
      }

      let affectedPaths = duplicateAffectedPaths(from: source.record)
      // Off-by-one: this new record is the 2nd (or later) consecutive identical
      // duplicate exactly when at least one matching duplicate already trails the turn.
      let blocked =
        priorDuplicateStreak(
          for: signature,
          workspace: workspace,
          in: currentItems
        ) >= 1
      let replayedObservation =
        blocked
        ? nil
        : source.record.resultPayload.map { payload in
          ToolResultProjector.project(payload: payload, request: source.record.request).observation
        }

      return ToolCallRecord(
        request: validatedRequest,
        evaluation: ToolPermissionEvaluation(
          decision: .allowed,
          reason: "Identical \(validatedRequest.toolName.rawValue) already completed in this turn.",
          riskLevel: .low,
          workspaceRelativePaths: affectedPaths
        ),
        state: .completed(
          .duplicateToolCall(
            DuplicateToolCallResult(
              previousCallID: source.record.id,
              message: duplicateMessage(
                for: validatedRequest,
                previousRecord: source.record,
                blocked: blocked
              ),
              affectedPaths: affectedPaths,
              replayedObservation: replayedObservation,
              blocked: blocked
            )))
      )
    }

    return nil
  }

  private func duplicateObservationSource(
    matching signature: ToolCallSignature,
    candidate: ToolCallRecord,
    candidateIndex: ArraySlice<ChatTurnItem>.Index,
    workspace: Workspace,
    items: ArraySlice<ChatTurnItem>
  ) -> (record: ToolCallRecord, index: ArraySlice<ChatTurnItem>.Index)? {
    guard isDuplicateToolCall(candidate.resultPayload) else {
      return (candidate, candidateIndex)
    }

    for index in items[..<candidateIndex].indices.reversed() {
      guard case .tool(let previousRecord) = items[index],
        previousRecord.status == .completed,
        toolCallSignature(for: previousRecord.request, workspace: workspace) == signature,
        !isDuplicateToolCall(previousRecord.resultPayload)
      else {
        continue
      }

      return (previousRecord, index)
    }

    return nil
  }

  private func isDuplicateToolCall(_ payload: ToolResultPayload?) -> Bool {
    guard case .duplicateToolCall = payload else {
      return false
    }
    return true
  }

  private func isBlockedDuplicate(_ record: ToolCallRecord) -> Bool {
    guard case .duplicateToolCall(let result)? = record.resultPayload else {
      return false
    }
    return result.blocked
  }

  private func finalReason(
    after record: ToolCallRecord
  ) -> ToolFollowUpFinalReason? {
    if record.status == .denied {
      return .denial
    }
    if isBlockedDuplicate(record) {
      return .blockedDuplicate
    }
    return nil
  }

  private func canReuseCompletedToolResult(
    _ previousRecord: ToolCallRecord,
    after index: ArraySlice<ChatTurnItem>.Index,
    workspace: Workspace,
    in items: ArraySlice<ChatTurnItem>
  ) -> Bool {
    switch previousRecord.request.toolName {
    case .readFile:
      guard let previousPath = successfulReadPath(from: previousRecord.resultPayload),
        let canonicalPreviousPath = canonicalWorkspacePath(
          previousPath.rawValue,
          workspace: workspace
        )
      else {
        return false
      }
      return !hasCompletedMutation(
        affectingReadAt: canonicalPreviousPath,
        after: index,
        workspace: workspace,
        in: items
      )
    default:
      return !hasCompletedWorkspaceMutation(after: index, in: items)
    }
  }

  private func duplicateAffectedPaths(
    from previousRecord: ToolCallRecord
  ) -> [WorkspaceRelativePath] {
    if let resultPayload = previousRecord.resultPayload {
      let paths = resultPayload.affectedPaths.map(WorkspaceRelativePath.init(rawValue:))
      if !paths.isEmpty {
        return paths
      }
    }
    return previousRecord.evaluation.workspaceRelativePaths
  }

  private func duplicateMessage(
    for request: ToolCallRequest,
    previousRecord: ToolCallRecord,
    blocked: Bool
  ) -> String {
    let prefix =
      "Duplicate of \(RuntimeToolCallID.string(for: previousRecord.id)): identical "
      + "\(request.toolName.rawValue) already completed in this turn; not re-executed. "
    if blocked {
      return prefix
        + "The result is not shown again — use the earlier result above, or provide the final answer."
    }
    return prefix + "Previous result is replayed below."
  }

  /// Number of identical duplicate records already trailing the current turn for this
  /// canonical signature. Non-tool items are skipped; the first
  /// non-matching tool record ends the streak — mirrors `readReplayStreak`.
  private func priorDuplicateStreak(
    for signature: ToolCallSignature,
    workspace: Workspace,
    in items: ArraySlice<ChatTurnItem>
  ) -> Int {
    var count = 0
    for item in items.reversed() {
      guard case .tool(let record) = item else {
        continue
      }
      guard isDuplicateToolCall(record.resultPayload),
        toolCallSignature(for: record.request, workspace: workspace) == signature
      else {
        break
      }
      count += 1
    }
    return count
  }

  private func currentTurnItems(in items: [ChatTurnItem]) -> ArraySlice<ChatTurnItem> {
    guard
      let lastUserIndex = items.lastIndex(where: { item in
        if case .userMessage = item {
          return true
        }
        return false
      })
    else {
      return items[...]
    }
    return items[lastUserIndex...]
  }

  private func successfulReadPath(from payload: ToolResultPayload?) -> WorkspaceRelativePath? {
    guard case .readFile(let result) = payload else {
      return nil
    }

    switch result {
    case .success(let path, _), .unchanged(let path, _), .repeatedReadWarning(let path, _):
      return path
    case .failed:
      return nil
    }
  }

  private func hasCompletedMutation(
    affectingReadAt path: WorkspaceRelativePath,
    after index: ArraySlice<ChatTurnItem>.Index,
    workspace: Workspace,
    in items: ArraySlice<ChatTurnItem>
  ) -> Bool {
    let nextIndex = items.index(after: index)
    guard nextIndex < items.endIndex else {
      return false
    }

    return items[nextIndex...].contains { item in
      guard case .tool(let record) = item,
        record.status == .completed
      else {
        return false
      }

      switch record.request.payload {
      case .writeFile(let input):
        return canonicalWorkspacePath(input.path, workspace: workspace) == path
      case .editFile(let input):
        return canonicalWorkspacePath(input.path, workspace: workspace) == path
      case .runCommand:
        return true
      default:
        return false
      }
    }
  }

  private func toolCallSignature(
    for request: ToolCallRequest,
    workspace: Workspace
  ) -> ToolCallSignature? {
    let arguments: ToolCallSignature.Arguments
    switch request.payload {
    case .readFile(let input):
      guard let path = canonicalWorkspacePath(input.path, workspace: workspace) else {
        return nil
      }
      arguments = .readFile(path: path, offset: input.offset ?? 1, limit: input.limit)
    case .listFiles(let input):
      guard let path = canonicalWorkspacePath(input.path ?? ".", workspace: workspace) else {
        return nil
      }
      arguments = .listFiles(path: path)
    case .globFiles(let input):
      guard let path = canonicalWorkspacePath(input.path ?? ".", workspace: workspace) else {
        return nil
      }
      arguments = .globFiles(pattern: input.pattern, path: path)
    case .searchFiles(let input):
      guard let path = canonicalWorkspacePath(input.path ?? ".", workspace: workspace) else {
        return nil
      }
      arguments = .searchFiles(pattern: input.pattern, path: path, include: input.include)
    case .workspaceDiff(let input):
      guard let path = canonicalWorkspacePath(input.path ?? ".", workspace: workspace) else {
        return nil
      }
      arguments = .workspaceDiff(path: path)
    case .workspaceDiagnostics(let input):
      arguments = .workspaceDiagnostics(outputRef: input.outputRef)
    case .webSearch(let input):
      arguments = .webSearch(query: input.query, maxResults: input.maxResults)
    case .webFetch(let input):
      arguments = .webFetch(url: input.url, maxBytes: input.maxBytes)
    default:
      return nil
    }
    return ToolCallSignature(toolName: request.toolName, arguments: arguments)
  }

  private func canonicalWorkspacePath(
    _ input: String,
    workspace: Workspace
  ) -> WorkspaceRelativePath? {
    guard let resolvedPath = try? workspace.resolveAllowedPath(input) else {
      return nil
    }
    return workspace.relativePath(for: resolvedPath)
  }

  private func hasCompletedWorkspaceMutation(
    after index: ArraySlice<ChatTurnItem>.Index,
    in items: ArraySlice<ChatTurnItem>
  ) -> Bool {
    let nextIndex = items.index(after: index)
    guard nextIndex < items.endIndex else {
      return false
    }

    return items[nextIndex...].contains { item in
      guard case .tool(let record) = item,
        record.status == .completed
      else {
        return false
      }

      switch record.request.toolName {
      case .writeFile, .editFile, .runCommand:
        return true
      default:
        return false
      }
    }
  }

  private func todoState(from record: ToolCallRecord) -> TodoState? {
    guard record.status == .completed,
      case .todoWrite(.success) = record.resultPayload,
      case .todoWrite(let input) = record.request.payload
    else {
      return nil
    }
    return TodoState(items: input.items)
  }

  private func traceToolExecution(
    startedAt: Date,
    loopRequest: ToolLoopRequest,
    rawRequest: RawToolCallRequest,
    record: ToolCallRecord
  ) async {
    let invalidInput: InvalidToolInput?
    if case .invalid(let input) = record.request.payload {
      invalidInput = input
    } else {
      invalidInput = nil
    }

    await turnTracer.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: loopRequest.turnID,
        generationID: nil,
        phase: .toolExecute,
        durationMs: Date().timeIntervalSince(startedAt) * 1000,
        messageCount: loopRequest.items.count,
        toolLoopIteration: loopRequest.toolLoopIteration,
        toolName: rawRequest.toolName.rawValue,
        interactionMode: loopRequest.interactionMode,
        toolCallFormat: "native",
        toolValidationStatus: invalidInput == nil ? "valid" : "invalid",
        toolValidationError: invalidInput?.reason.message,
        toolOriginalName: rawRequest.originalToolName ?? invalidInput?.originalName,
        toolArgumentKeys: rawRequest.arguments.keys.sorted(),
        toolArguments: ToolArgumentTraceBuilder.traces(
          from: rawRequest.arguments,
          toolName: rawRequest.toolName
        )
      )
    )
  }
}

private struct ToolCallSignature: Hashable, Sendable {
  var toolName: ToolName
  var arguments: Arguments

  static func == (lhs: ToolCallSignature, rhs: ToolCallSignature) -> Bool {
    lhs.toolName == rhs.toolName && lhs.arguments == rhs.arguments
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(toolName)
    hasher.combine(arguments)
  }

  enum Arguments: Hashable, Sendable {
    case readFile(path: WorkspaceRelativePath, offset: Int, limit: Int?)
    case listFiles(path: WorkspaceRelativePath)
    case globFiles(pattern: String, path: WorkspaceRelativePath)
    case searchFiles(pattern: String, path: WorkspaceRelativePath, include: String?)
    case workspaceDiff(path: WorkspaceRelativePath)
    case workspaceDiagnostics(outputRef: String)
    case webSearch(query: String, maxResults: Int?)
    case webFetch(url: String, maxBytes: Int?)
  }
}
