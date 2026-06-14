import Foundation

public protocol ToolOrchestrating: Sendable {
  var toolRegistry: ToolRegistry { get }

  func execute(request: RawToolCallRequest, workspace: Workspace) async -> ToolCallRecord
}

extension ToolOrchestrator: ToolOrchestrating {}

public struct ToolLoopRequest: Sendable {
  public let workspace: Workspace
  public let sessionID: ChatSession.ID
  public let turnID: ChatTurn.ID
  public let assistantMessageID: UUID
  public let items: [ChatTurnItem]
  public let focusedFileState: FocusedFileState
  public let interactionMode: WorkspaceInteractionMode
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
    self.followUpPromptMode = followUpPromptMode
    self.toolLoopIteration = toolLoopIteration
    self.toolCallingPolicy = toolCallingPolicy
    self.nativeToolCalls = nativeToolCalls
  }
}

public struct ToolLoopCoordinator: Sendable {
  private let agentToolOrchestrator: any ToolOrchestrating
  private let focusedFileReducer: FocusedFileStateReducer
  private let turnTracer: any TurnTracing

  public init(
    agentToolOrchestrator: any ToolOrchestrating = ToolOrchestrator(
      executorRegistry: .codingAgent),
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.agentToolOrchestrator = agentToolOrchestrator
    self.focusedFileReducer = focusedFileReducer
    self.turnTracer = turnTracer
  }

  public var toolRegistry: ToolRegistry {
    agentToolOrchestrator.toolRegistry
  }

  public func run(_ request: ToolLoopRequest) async throws -> ChatWorkflowStep? {
    try Task.checkCancellation()
    guard request.interactionMode != .chat else {
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
          registry: toolOrchestrator(for: request.interactionMode).toolRegistry,
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

  private func toolOrchestrator(for mode: WorkspaceInteractionMode) -> any ToolOrchestrating {
    switch mode {
    case .chat, .agent:
      agentToolOrchestrator
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

    for output in outputs {
      let executeStartedAt = Date()
      let record = await toolOrchestrator(for: request.interactionMode).execute(
        request: output.request,
        workspace: request.workspace
      )
      await traceToolExecution(
        startedAt: executeStartedAt,
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
    guard !outputs.isEmpty else {
      return []
    }
    return [
      .nativeAssistantBoundaryAppended(
        content: NativeToolCallBoundaryRenderer.renderModelContextGemma4(
          outputs.map(\.modelMessage)
        ),
        sourceMessageID: request.assistantMessageID,
        turnID: request.turnID
      )
    ]
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
