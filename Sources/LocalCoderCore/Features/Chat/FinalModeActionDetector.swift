import Foundation

public enum FinalModeActionDetectionReason: Equatable, Sendable {
  case finalMode
  case toolBudgetExceeded(iterationLimit: Int)
}

public struct FinalModeActionDetectionRequest: Sendable {
  public let workspaceID: Workspace.ID?
  public let sessionID: CodingSession.ID
  public let turnID: ChatTurnRecord.ID
  public let assistantMessageID: ChatMessage.ID
  public let messages: [ChatMessage]
  public let interactionMode: WorkspaceInteractionMode
  public let reason: FinalModeActionDetectionReason
  public let toolLoopIteration: Int?

  public init(
    workspaceID: Workspace.ID?,
    sessionID: CodingSession.ID,
    turnID: ChatTurnRecord.ID,
    assistantMessageID: ChatMessage.ID,
    messages: [ChatMessage],
    interactionMode: WorkspaceInteractionMode,
    reason: FinalModeActionDetectionReason,
    toolLoopIteration: Int? = nil
  ) {
    self.workspaceID = workspaceID
    self.sessionID = sessionID
    self.turnID = turnID
    self.assistantMessageID = assistantMessageID
    self.messages = messages
    self.interactionMode = interactionMode
    self.reason = reason
    self.toolLoopIteration = toolLoopIteration
  }
}

nonisolated private enum ForbiddenToolAttempt: Equatable, Sendable {
  case none
  case toolCall(ToolCallParseOutput)
  case invalid(originalToolName: String, error: String)
}

public struct FinalModeActionDetector: Sendable {
  private let toolCallParser: any ToolCallParsing
  private let turnTracer: any TurnTracing

  public init(
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.toolCallParser = toolCallParser
    self.turnTracer = turnTracer
  }

  public func detect(_ request: FinalModeActionDetectionRequest) async throws
    -> ChatWorkflowStep?
  {
    try Task.checkCancellation()
    guard request.interactionMode != .chat, let workspaceID = request.workspaceID else {
      return nil
    }

    let assistantContent = messageContent(for: request.assistantMessageID, in: request.messages)
    let parseStartedAt = Date()
    let attempt: ForbiddenToolAttempt
    do {
      attempt = try parseForbiddenToolAttempt(
        assistantContent,
        workspaceID: workspaceID,
        sessionID: request.sessionID
      )
    } catch {
      await traceToolParse(startedAt: parseStartedAt, request: request, toolName: nil)
      throw error
    }
    await traceToolParse(startedAt: parseStartedAt, request: request, toolName: attempt.toolName)

    switch attempt {
    case .none:
      return nil
    case .invalid(let originalToolName, let error):
      let output = invalidToolCallOutput(
        originalToolName: originalToolName,
        error: error,
        rawText: assistantContent,
        workspaceID: workspaceID,
        sessionID: request.sessionID
      )
      let record = blockedRecord(
        request: output.request,
        requestedTool: ToolName(canonicalizing: originalToolName),
        reason: request.reason
      )
      return blockedStep(request: request, toolCall: output.modelMessage, record: record)
    case .toolCall(let output):
      let record = blockedRecord(
        request: output.request,
        requestedTool: output.request.toolName,
        reason: request.reason
      )
      return blockedStep(request: request, toolCall: output.modelMessage, record: record)
    }
  }

  private func traceToolParse(
    startedAt: Date,
    request: FinalModeActionDetectionRequest,
    toolName: String?
  ) async {
    await turnTracer.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: request.turnID,
        generationID: nil,
        phase: .toolParse,
        durationMs: Date().timeIntervalSince(startedAt) * 1000,
        messageCount: request.messages.count,
        toolLoopIteration: request.toolLoopIteration,
        toolName: toolName,
        interactionMode: request.interactionMode
      )
    )
  }

  private func parseForbiddenToolAttempt(
    _ content: String,
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID
  ) throws -> ForbiddenToolAttempt {
    do {
      let parseResult = try toolCallParser.parse(
        content,
        workspaceID: workspaceID,
        sessionID: sessionID,
        createdAt: Date()
      )
      switch parseResult {
      case .none:
        guard ToolIntentHeuristics.looksLikeNonTaggedToolIntent(content) else {
          return .none
        }
        return .invalid(
          originalToolName: ToolIntentHeuristics.inferredToolName(from: content),
          error:
            "Assistant described a tool call but did not emit the required tagged <action> block. "
            + "Emit one complete <action> block and no explanatory text."
        )
      case .toolCall(let output):
        return .toolCall(output)
      }
    } catch let parseError as TaggedToolCallParseError {
      let initialError = errorDescription(from: parseError)
      guard let actionContent = recoverableToolActionContent(from: content) else {
        return .invalid(
          originalToolName: ToolIntentHeuristics.inferredToolName(from: content),
          error: initialError
        )
      }

      do {
        let parseResult = try toolCallParser.parse(
          actionContent,
          workspaceID: workspaceID,
          sessionID: sessionID,
          createdAt: Date()
        )
        switch parseResult {
        case .none:
          return .invalid(
            originalToolName: ToolIntentHeuristics.inferredToolName(from: content),
            error: initialError
          )
        case .toolCall(let output):
          return .toolCall(output)
        }
      } catch let parseError as TaggedToolCallParseError {
        return .invalid(
          originalToolName: ToolIntentHeuristics.inferredToolName(from: content),
          error: errorDescription(from: parseError)
        )
      }
    }
  }

  private func blockedStep(
    request: FinalModeActionDetectionRequest,
    toolCall: ToolCallModelMessage,
    record: ToolCallRecord
  ) -> ChatWorkflowStep {
    let toolResult = ToolResultModelMessage(
      callID: record.id,
      toolName: record.request.toolName,
      payload: record.resultPayload
        ?? .failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: nil,
            reason: .executionError("Tool attempt blocked.")
          ))
    )
    return ChatWorkflowStep(
      events: [
        .assistantMessageAnnotatedAsToolCall(
          assistantMessageID: request.assistantMessageID,
          toolCall: toolCall
        ),
        .toolCallAppended(record, turnID: request.turnID),
        .toolResultAppended(toolResult, messageID: UUID(), turnID: request.turnID),
      ],
      continuation: .stopTurn
    )
  }

  private func blockedRecord(
    request rawRequest: RawToolCallRequest,
    requestedTool: ToolName?,
    reason: FinalModeActionDetectionReason
  ) -> ToolCallRecord {
    let request = ToolCallRequest.invalid(
      raw: rawRequest,
      input: InvalidToolInput(
        originalName: requestedTool?.rawValue,
        rawArguments: rawRequest.arguments,
        reason: .parserError(blockedParserError(for: requestedTool, reason: reason))
      )
    )
    let payload = ToolResultPayload.failure(
      ToolFailure(
        toolName: rawRequest.toolName,
        path: nil,
        reason: failureReason(for: requestedTool, reason: reason),
        recovery: .askUser(message: "Ask the user to send another message before using tools.")
      )
    )
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: evaluationReason(for: requestedTool, reason: reason),
        riskLevel: .low
      ),
      events: [
        ToolCallEvent(
          actor: .system,
          kind: .failed,
          message: eventMessage(for: requestedTool, reason: reason)
        )
      ],
      state: .failed(payload)
    )
  }

  private func blockedParserError(
    for requestedTool: ToolName?,
    reason: FinalModeActionDetectionReason
  ) -> String {
    switch reason {
    case .finalMode:
      "Tool attempt ignored in final response mode before \(requestedToolName(requestedTool)) could run."
    case .toolBudgetExceeded:
      "Tool budget exceeded before \(requestedToolName(requestedTool)) could run."
    }
  }

  private func failureReason(
    for requestedTool: ToolName?,
    reason: FinalModeActionDetectionReason
  ) -> ToolFailureReason {
    switch reason {
    case .finalMode:
      .finalModeToolAttempt(requestedTool: requestedTool)
    case .toolBudgetExceeded(let iterationLimit):
      .toolBudgetExceeded(requestedTool: requestedTool, iterationLimit: iterationLimit)
    }
  }

  private func evaluationReason(
    for requestedTool: ToolName?,
    reason: FinalModeActionDetectionReason
  ) -> String {
    switch reason {
    case .finalMode:
      "Tool attempt ignored because this turn is in final response mode."
    case .toolBudgetExceeded:
      "Tool budget exhausted for this request."
    }
  }

  private func eventMessage(
    for requestedTool: ToolName?,
    reason: FinalModeActionDetectionReason
  ) -> String {
    switch reason {
    case .finalMode:
      "Ignored \(requestedToolName(requestedTool)) because final response mode forbids tool execution."
    case .toolBudgetExceeded:
      "Tool budget exhausted before \(requestedToolName(requestedTool)) could execute."
    }
  }

  private func requestedToolName(_ requestedTool: ToolName?) -> String {
    requestedTool?.rawValue ?? "unknown"
  }

  private func invalidToolCallOutput(
    originalToolName: String,
    error: String,
    rawText: String,
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID
  ) -> ToolCallParseOutput {
    let request = RawToolCallRequest(
      workspaceID: workspaceID,
      sessionID: sessionID,
      toolName: .invalid,
      arguments: [
        "tool": .string(originalToolName),
        "error": .string(error),
      ],
      rawText: rawText
    )
    return ToolCallParseOutput(
      request: request,
      modelMessage: ToolCallModelMessage(rawRequest: request)
    )
  }

  private func recoverableToolActionContent(from content: String) -> String? {
    guard let actionStart = content.range(of: "<action")?.lowerBound,
      let actionEnd = content.range(of: "</action>", range: actionStart..<content.endIndex)
    else {
      return nil
    }

    let afterFirstAction = actionEnd.upperBound
    guard content.range(of: "<action", range: afterFirstAction..<content.endIndex) == nil else {
      return nil
    }

    return String(content[actionStart..<afterFirstAction])
  }

  private func errorDescription(from parseError: TaggedToolCallParseError) -> String {
    parseError.errorDescription ?? String(describing: parseError)
  }

  private func messageContent(for id: UUID, in messages: [ChatMessage]) -> String {
    messages.first { $0.id == id }?.content ?? ""
  }
}

extension ForbiddenToolAttempt {
  fileprivate var toolName: String? {
    switch self {
    case .none:
      nil
    case .toolCall(let output):
      output.request.toolName.rawValue
    case .invalid(let originalToolName, _):
      originalToolName
    }
  }
}
