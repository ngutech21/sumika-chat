import Foundation

public protocol ToolOrchestrating: Sendable {
  var toolRegistry: ToolRegistry { get }

  func execute(request: RawToolCallRequest, workspace: Workspace) async -> ToolCallRecord
}

extension ToolOrchestrator: ToolOrchestrating {}

public enum ToolExecutionProfile: Equatable, Sendable {
  case disabled
  case chatWeb
  case agent

  public var allowsToolLoop: Bool {
    self != .disabled
  }
}

public struct ToolLoopRequest: Sendable {
  public let workspace: Workspace
  public let sessionID: ChatSession.ID
  public let turnID: ChatTurn.ID
  public let assistantMessageID: UUID
  public let items: [ChatTurnItem]
  public let focusedFileState: FocusedFileState
  public let interactionMode: WorkspaceInteractionMode
  public let toolProfile: ToolExecutionProfile
  public let followUpPromptMode: ToolPromptMode
  public let toolLoopIteration: Int?
  public let toolCallingPolicy: ToolCallingPolicy
  public let nativeToolCalls: [ChatRuntimeToolCall]

  public init(
    workspace: Workspace,
    sessionID: ChatSession.ID,
    turnID: ChatTurn.ID,
    assistantMessageID: UUID,
    items: [ChatTurnItem],
    focusedFileState: FocusedFileState = .empty,
    interactionMode: WorkspaceInteractionMode = .agent,
    toolProfile: ToolExecutionProfile = .agent,
    followUpPromptMode: ToolPromptMode = .afterToolResultCanContinue,
    toolLoopIteration: Int? = nil,
    toolCallingPolicy: ToolCallingPolicy = .nativeGemma4,
    nativeToolCalls: [ChatRuntimeToolCall] = []
  ) {
    self.workspace = workspace
    self.sessionID = sessionID
    self.turnID = turnID
    self.assistantMessageID = assistantMessageID
    self.items = items
    self.focusedFileState = focusedFileState
    self.interactionMode = interactionMode
    self.toolProfile = toolProfile
    self.followUpPromptMode = followUpPromptMode
    self.toolLoopIteration = toolLoopIteration
    self.toolCallingPolicy = toolCallingPolicy
    self.nativeToolCalls = nativeToolCalls
  }
}

private struct DuplicateToolCallDecision: Sendable {
  let record: ToolCallRecord?
  let finalizesTurn: Bool
}

public struct ToolLoopCoordinator: Sendable {
  private let chatWebToolOrchestrator: any ToolOrchestrating
  private let agentToolOrchestrator: any ToolOrchestrating
  private let focusedFileReducer: FocusedFileStateReducer
  private let turnTracer: any TurnTracing

  public init(
    chatWebToolOrchestrator: any ToolOrchestrating = ToolOrchestrator(
      executorRegistry: .chatWeb),
    agentToolOrchestrator: any ToolOrchestrating = ToolOrchestrator(
      executorRegistry: .codingAgent),
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.chatWebToolOrchestrator = chatWebToolOrchestrator
    self.agentToolOrchestrator = agentToolOrchestrator
    self.focusedFileReducer = focusedFileReducer
    self.turnTracer = turnTracer
  }

  public var toolRegistry: ToolRegistry {
    agentToolOrchestrator.toolRegistry
  }

  public func toolRegistry(for profile: ToolExecutionProfile) -> ToolRegistry {
    guard let orchestrator = toolOrchestrator(for: profile) else {
      return ToolRegistry(tools: [])
    }
    return orchestrator.toolRegistry
  }

  public func run(_ request: ToolLoopRequest) async throws -> ChatWorkflowStep? {
    try Task.checkCancellation()
    guard let toolOrchestrator = toolOrchestrator(for: request.toolProfile),
      !toolOrchestrator.toolRegistry.tools.isEmpty
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
          registry: toolOrchestrator.toolRegistry,
          workspaceID: request.workspace.id,
          sessionID: request.sessionID
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
        request: request
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

  private func toolOrchestrator(for profile: ToolExecutionProfile) -> (any ToolOrchestrating)? {
    switch profile {
    case .disabled:
      return nil
    case .chatWeb:
      return chatWebToolOrchestrator
    case .agent:
      return agentToolOrchestrator
    }
  }

  private func executeToolCalls(
    _ outputs: [ToolCallParseOutput],
    request: ToolLoopRequest
  ) async -> ChatWorkflowStep {
    guard !outputs.isEmpty else {
      return ChatWorkflowStep(events: [], continuation: .none)
    }

    let nextAssistantMessageID = UUID()
    var events = nativeAssistantBoundaryEvents(for: request, outputs: outputs)
    var focusedFileState = request.focusedFileState
    var nextFollowUpPromptMode = request.followUpPromptMode
    var seenItems = request.items

    for output in outputs {
      guard let toolOrchestrator = toolOrchestrator(for: request.toolProfile) else {
        return ChatWorkflowStep(events: events, continuation: .none)
      }
      let record: ToolCallRecord
      if let duplicateDecision = duplicateToolCallDecision(
        for: output,
        request: request,
        registry: toolOrchestrator.toolRegistry,
        items: seenItems
      ) {
        if duplicateDecision.finalizesTurn {
          nextFollowUpPromptMode = .afterToolResultFinal
        }
        guard let duplicateRecord = duplicateDecision.record else {
          continue
        }
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

      events.append(
        .assistantAnnotatedAsNativeToolCall(
          assistantMessageID: request.assistantMessageID,
          toolCall: output.modelMessage
        ))
      events.append(.toolCallAppended(record, turnID: request.turnID))

      guard record.status != .awaitingApproval else {
        events.append(
          .turnStatusChanged(
            turnID: request.turnID,
            status: .awaitingApproval,
            modelContextPolicy: nil
          ))
        return ChatWorkflowStep(events: events, continuation: .awaitingApproval)
      }

      guard record.status != .awaitingUserAnswer else {
        events.append(
          .turnStatusChanged(
            turnID: request.turnID,
            status: .awaitingUserAnswer,
            modelContextPolicy: nil
          ))
        return ChatWorkflowStep(events: events, continuation: .awaitingUserAnswer)
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

      nextFollowUpPromptMode = followUpPromptMode(
        after: record,
        defaultMode: nextFollowUpPromptMode
      )

      if let directResponse = ToolLoopDirectResponseRenderer.directResponse(
        after: record, toolResult: toolResult, request: request)
      {
        events.append(
          .assistantMessageAppended(
            content: directResponse.content,
            modelContextContent: directResponse.modelContextContent,
            messageID: nextAssistantMessageID,
            turnID: request.turnID
          ))
        return ChatWorkflowStep(events: events, continuation: .stopTurn)
      }
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

  private func duplicateToolCallDecision(
    for output: ToolCallParseOutput,
    request: ToolLoopRequest,
    registry: ToolRegistry,
    items: [ChatTurnItem]
  ) -> DuplicateToolCallDecision? {
    if let duplicateReadRecord = duplicateReadFileRecord(
      for: output,
      request: request,
      items: items
    ) {
      _ = duplicateReadRecord
      return DuplicateToolCallDecision(record: nil, finalizesTurn: true)
    }

    guard suppressesIdenticalCompletedCall(output.request.toolName) else {
      return nil
    }

    let validatedRequest = ToolCallRequestValidator().validate(
      output.request,
      registry: registry
    )
    if case .invalid = validatedRequest.payload {
      return nil
    }

    let currentItems = currentTurnItems(in: items)
    for index in currentItems.indices.reversed() {
      guard case .tool(let previousRecord) = currentItems[index],
        previousRecord.status == .completed,
        previousRecord.request.toolName == output.request.toolName,
        previousRecord.request.payload == validatedRequest.payload
      else {
        continue
      }

      guard !hasCompletedWorkspaceMutation(after: index, in: currentItems) else {
        return nil
      }

      return DuplicateToolCallDecision(record: nil, finalizesTurn: true)
    }

    return nil
  }

  private func duplicateReadFileRecord(
    for output: ToolCallParseOutput,
    request: ToolLoopRequest,
    items: [ChatTurnItem]
  ) -> ToolCallRecord? {
    guard output.request.toolName == .readFile,
      let input = try? ReadFileInput.decodeToolArguments(output.request.arguments)
    else {
      return nil
    }

    let currentItems = currentTurnItems(in: items)
    for index in currentItems.indices.reversed() {
      guard case .tool(let previousRecord) = currentItems[index],
        previousRecord.status == .completed,
        case .readFile(let previousInput) = previousRecord.request.payload,
        previousInput == input,
        let previousPath = successfulReadPath(from: previousRecord.resultPayload)
      else {
        continue
      }

      guard !hasCompletedWrite(to: previousPath, after: index, in: currentItems) else {
        return nil
      }

      let validatedRequest = ToolCallRequest.validated(
        raw: output.request,
        payload: .readFile(input)
      )
      return ToolCallRecord(
        request: validatedRequest,
        evaluation: ToolPermissionEvaluation(
          decision: .allowed,
          reason: "Identical read_file already completed in this turn.",
          riskLevel: .low,
          workspaceRelativePaths: [previousPath]
        ),
        state: .completed(
          .readFile(
            .unchanged(
              path: previousPath,
              readKey: ReadKey(path: previousPath, range: readRangeKey(for: input))
            )))
      )
    }

    return nil
  }

  private func suppressesIdenticalCompletedCall(_ toolName: ToolName) -> Bool {
    switch toolName {
    case .listFiles, .globFiles, .searchFiles, .workspaceDiff, .workspaceDiagnostics,
      .webSearch, .webFetch:
      return true
    default:
      return false
    }
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

  private func hasCompletedWrite(
    to path: WorkspaceRelativePath,
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

      switch record.request.payload {
      case .writeFile(let input):
        return input.path == path.rawValue
      case .editFile(let input):
        return input.path == path.rawValue
      default:
        return false
      }
    }
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

  private func readRangeKey(for input: ReadFileInput) -> String? {
    let offset = input.offset ?? 1
    guard offset != 1 || input.limit != nil else {
      return nil
    }

    if let limit = input.limit {
      return "offset=\(offset),limit=\(limit)"
    }

    return "offset=\(offset)"
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

  private func nativeAssistantBoundaryEvents(
    for request: ToolLoopRequest,
    outputs: [ToolCallParseOutput]
  ) -> [ChatWorkflowEvent] {
    _ = (request, outputs)
    return []
  }

  private func followUpPromptMode(
    after record: ToolCallRecord,
    defaultMode: ToolPromptMode
  ) -> ToolPromptMode {
    guard record.status == .completed,
      record.resultPayload?.status == .success
    else {
      return defaultMode
    }
    switch record.request.toolName {
    case .writeFile, .editFile:
      return .afterToolResultFinal
    default:
      return defaultMode
    }
  }

}
