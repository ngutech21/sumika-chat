import Foundation

public protocol ToolOrchestrating: Sendable {
  var toolRegistry: ToolRegistry { get }

  func execute(request: RawToolCallRequest, workspace: Workspace) async -> ToolCallRecord
}

extension ToolOrchestrator: ToolOrchestrating {}

public struct ToolLoopRequest: Sendable {
  public let workspace: Workspace
  public let sessionID: CodingSession.ID
  public let turnID: ChatTurnRecord.ID
  public let assistantMessageID: UUID
  public let messages: [ChatMessage]
  public let focusedFileState: FocusedFileState
  public let followUpPromptMode: ToolPromptMode

  public init(
    workspace: Workspace,
    sessionID: CodingSession.ID,
    turnID: ChatTurnRecord.ID,
    assistantMessageID: UUID,
    messages: [ChatMessage],
    focusedFileState: FocusedFileState = .empty,
    followUpPromptMode: ToolPromptMode = .afterToolResultCanContinue
  ) {
    self.workspace = workspace
    self.sessionID = sessionID
    self.turnID = turnID
    self.assistantMessageID = assistantMessageID
    self.messages = messages
    self.focusedFileState = focusedFileState
    self.followUpPromptMode = followUpPromptMode
  }
}

nonisolated private enum ToolLoopParsedAction: Equatable, Sendable {
  case none
  case toolCall(ToolCallParseOutput)
  case invalid(originalToolName: String, error: String)
}

public struct ToolLoopCoordinator: Sendable {
  private let toolCallParser: any ToolCallParsing
  private let toolOrchestrator: any ToolOrchestrating
  private let focusedFileReducer: FocusedFileStateReducer

  public init(
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    toolOrchestrator: any ToolOrchestrating = ToolOrchestrator(),
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer()
  ) {
    self.toolCallParser = toolCallParser
    self.toolOrchestrator = toolOrchestrator
    self.focusedFileReducer = focusedFileReducer
  }

  public var toolRegistry: ToolRegistry {
    toolOrchestrator.toolRegistry
  }

  public func run(_ request: ToolLoopRequest) async throws -> ChatWorkflowStep? {
    try Task.checkCancellation()
    let assistantContent = messageContent(for: request.assistantMessageID, in: request.messages)
    let parsedAction = try parseToolAction(
      assistantContent,
      workspaceID: request.workspace.id,
      sessionID: request.sessionID
    )

    switch parsedAction {
    case .none:
      return nil
    case .invalid(let originalToolName, let error):
      let output = invalidToolCallOutput(
        originalToolName: originalToolName,
        error: error,
        workspaceID: request.workspace.id,
        sessionID: request.sessionID
      )
      let record = invalidToolCallRecord(
        request: output.request,
        originalToolName: originalToolName,
        error: error
      )
      return completedStep(
        assistantMessageID: request.assistantMessageID,
        turnID: request.turnID,
        toolCall: output.modelMessage,
        record: record,
        toolResult: ToolResultModelMessage(
          callID: output.request.id,
          toolName: output.request.toolName,
          payload: record.resultPayload,
          preview: record.resultPreview
            ?? ToolResultPreview(status: .failed, text: invalidToolMessage(error: error))
        ),
        focusedFileState: request.focusedFileState,
        followUpPromptMode: request.followUpPromptMode
      )
    case .toolCall(let output):
      let record = await toolOrchestrator.execute(
        request: output.request,
        workspace: request.workspace
      )
      guard record.status != .awaitingApproval else {
        return ChatWorkflowStep(
          events: [
            .assistantMessageAnnotatedAsToolCall(
              assistantMessageID: request.assistantMessageID,
              toolCall: output.modelMessage
            ),
            .toolCallAppended(record, turnID: request.turnID),
            .turnStatusChanged(
              turnID: request.turnID,
              status: .awaitingApproval,
              modelContextPolicy: nil
            ),
          ],
          continuation: .awaitingApproval
        )
      }

      let resultPreview =
        record.resultPreview
        ?? ToolResultPreview(
          status: .failed,
          text: "Tool result unavailable for \(output.request.toolName.rawValue)."
        )
      let toolResult = ToolResultModelMessage(
        callID: output.request.id,
        toolName: output.request.toolName,
        payload: record.resultPayload,
        preview: resultPreview
      )

      if completesTurnWithoutFollowUp(output.request.toolName) && record.status == .completed {
        return completedWithoutFollowUpStep(
          assistantMessageID: request.assistantMessageID,
          turnID: request.turnID,
          toolCall: output.modelMessage,
          record: record,
          toolResult: toolResult,
          focusedFileState: request.focusedFileState
        )
      }

      return completedStep(
        assistantMessageID: request.assistantMessageID,
        turnID: request.turnID,
        toolCall: output.modelMessage,
        record: record,
        toolResult: toolResult,
        focusedFileState: request.focusedFileState,
        followUpPromptMode: request.followUpPromptMode
      )
    }
  }

  private func completedStep(
    assistantMessageID: ChatMessage.ID,
    turnID: ChatTurnRecord.ID,
    toolCall: ToolCallModelMessage,
    record: ToolCallRecord,
    toolResult: ToolResultModelMessage,
    focusedFileState: FocusedFileState,
    followUpPromptMode: ToolPromptMode
  ) -> ChatWorkflowStep {
    let nextAssistantMessageID = UUID()
    var events: [ChatWorkflowEvent] = [
      .assistantMessageAnnotatedAsToolCall(
        assistantMessageID: assistantMessageID,
        toolCall: toolCall
      ),
      .toolCallAppended(record, turnID: turnID),
      .toolResultAppended(toolResult, messageID: UUID(), turnID: turnID),
    ]
    events.append(contentsOf: focusedFileEvents(record: record, from: focusedFileState))
    events.append(.assistantPlaceholderAppended(messageID: nextAssistantMessageID, turnID: turnID))
    return ChatWorkflowStep(
      events: events,
      continuation: .resumeGeneration(
        assistantMessageID: nextAssistantMessageID,
        promptMode: followUpPromptMode
      )
    )
  }

  private func completedWithoutFollowUpStep(
    assistantMessageID: ChatMessage.ID,
    turnID: ChatTurnRecord.ID,
    toolCall: ToolCallModelMessage,
    record: ToolCallRecord,
    toolResult: ToolResultModelMessage,
    focusedFileState: FocusedFileState
  ) -> ChatWorkflowStep {
    var events: [ChatWorkflowEvent] = [
      .assistantMessageAnnotatedAsToolCall(
        assistantMessageID: assistantMessageID,
        toolCall: toolCall
      ),
      .toolCallAppended(record, turnID: turnID),
      .toolResultAppended(toolResult, messageID: UUID(), turnID: turnID),
    ]
    events.append(contentsOf: focusedFileEvents(record: record, from: focusedFileState))
    return ChatWorkflowStep(
      events: events,
      continuation: .stopTurn
    )
  }

  private func focusedFileEvents(
    record: ToolCallRecord,
    from focusedFileState: FocusedFileState
  ) -> [ChatWorkflowEvent] {
    let updatedState = focusedFileReducer.applyingToolResult(
      record.resultPayload,
      request: record.request,
      to: focusedFileState
    )
    guard updatedState != focusedFileState else {
      return []
    }
    return [.focusedFileStateChanged(updatedState)]
  }

  private func parseToolAction(
    _ content: String,
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID
  ) throws -> ToolLoopParsedAction {
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

  private func completesTurnWithoutFollowUp(_ toolName: ToolName) -> Bool {
    toolName == .writeFile || toolName == .editFile
  }

  private func invalidToolCallOutput(
    originalToolName: String,
    error: String,
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
      ]
    )
    return ToolCallParseOutput(
      request: request,
      modelMessage: ToolCallModelMessage(rawRequest: request)
    )
  }

  private func invalidToolCallRecord(
    request rawRequest: RawToolCallRequest,
    originalToolName: String,
    error: String
  ) -> ToolCallRecord {
    let message = invalidToolMessage(error: error)
    let request = ToolCallRequest.invalid(
      raw: rawRequest,
      input: InvalidToolInput(
        originalName: originalToolName,
        rawArguments: rawRequest.arguments,
        reason: .parserError(error)
      )
    )
    let resultPayload = ToolResultPayload.invalidTool(
      InvalidToolResult(originalName: originalToolName, reason: .parserError(error))
    )
    return ToolCallRecord(
      request: request,
      status: .failed,
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: message,
        riskLevel: .low
      ),
      events: [
        ToolCallEvent(
          actor: .assistant,
          kind: .requested,
          message: "Requested invalid tool fallback for \(originalToolName)."
        ),
        ToolCallEvent(actor: .system, kind: .failed, message: message),
      ],
      resultPayload: resultPayload,
      resultPreview: resultPayload.preview
    )
  }

  private func invalidToolMessage(error: String) -> String {
    "The tool call was invalid: \(error)"
  }

  private func errorDescription(from error: Error) -> String {
    if let localizedError = error as? LocalizedError,
      let description = localizedError.errorDescription
    {
      return description
    }
    return error.localizedDescription
  }

  private func recoverableToolActionContent(from content: String) -> String? {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    if let fencedContent = singleFencedCodeBlockContent(from: trimmed) {
      return recoverableToolActionContent(from: fencedContent)
    }

    guard let actionStart = trimmed.range(of: "<action") else {
      return nil
    }
    guard
      let actionEnd = trimmed.range(
        of: "</action>", range: actionStart.upperBound..<trimmed.endIndex)
    else {
      return nil
    }

    let blockEnd = actionEnd.upperBound
    guard trimmed[blockEnd...].range(of: "<action") == nil else {
      return nil
    }

    return String(trimmed[actionStart.lowerBound..<blockEnd])
  }

  private func singleFencedCodeBlockContent(from content: String) -> String? {
    guard content.hasPrefix("```") else {
      return nil
    }

    var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 2 else {
      return nil
    }
    guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    else {
      return nil
    }
    guard let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" else {
      return nil
    }

    lines.removeFirst()
    lines.removeLast()
    return lines.joined(separator: "\n")
  }

  private func messageContent(for id: UUID, in messages: [ChatMessage]) -> String {
    messages.first(where: { $0.id == id })?.content ?? ""
  }
}
