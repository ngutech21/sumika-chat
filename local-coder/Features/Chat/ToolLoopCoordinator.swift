import Foundation

nonisolated protocol ToolOrchestrating: Sendable {
  var toolRegistry: ToolRegistry { get }

  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolCallRecord
}

extension ToolOrchestrator: ToolOrchestrating {}

nonisolated struct ToolLoopRequest: Sendable {
  let workspace: Workspace
  let sessionID: CodingSession.ID
  let assistantMessageID: UUID
  let messages: [ChatMessage]
}

nonisolated struct ToolLoopResult: Equatable, Sendable {
  let assistantMessageID: UUID
  let toolCall: ToolCallModelMessage
  let toolCallRecord: ToolCallRecord
  let outcome: ToolLoopOutcome
}

nonisolated enum ToolLoopOutcome: Equatable, Sendable {
  case awaitingApproval
  case completed(toolResult: ToolResultModelMessage, nextAssistantMessageID: UUID)
  case completedWithoutFollowUp(toolResult: ToolResultModelMessage)
}

nonisolated private enum ToolLoopParsedAction: Equatable, Sendable {
  case none
  case toolCall(ToolCallParseOutput)
  case invalid(originalToolName: String, error: String)
}

nonisolated struct ToolLoopCoordinator: Sendable {
  private let toolCallParser: any ToolCallParsing
  private let toolOrchestrator: any ToolOrchestrating

  init(
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    toolOrchestrator: any ToolOrchestrating = ToolOrchestrator()
  ) {
    self.toolCallParser = toolCallParser
    self.toolOrchestrator = toolOrchestrator
  }

  var toolRegistry: ToolRegistry {
    toolOrchestrator.toolRegistry
  }

  func run(_ request: ToolLoopRequest) async throws -> ToolLoopResult? {
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
      return ToolLoopResult(
        assistantMessageID: request.assistantMessageID,
        toolCall: output.modelMessage,
        toolCallRecord: record,
        outcome: .completed(
          toolResult: ToolResultModelMessage(
            callID: output.request.id,
            toolName: output.request.toolName,
            preview: record.resultPreview
              ?? ToolResultPreview(status: .failed, text: invalidToolMessage(error: error))
          ),
          nextAssistantMessageID: UUID()
        )
      )
    case .toolCall(let output):
      let record = await toolOrchestrator.execute(
        request: output.request,
        workspace: request.workspace
      )
      guard record.status != .awaitingApproval else {
        return ToolLoopResult(
          assistantMessageID: request.assistantMessageID,
          toolCall: output.modelMessage,
          toolCallRecord: record,
          outcome: .awaitingApproval
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
        preview: resultPreview
      )

      let outcome: ToolLoopOutcome
      if completesTurnWithoutFollowUp(output.request.toolName) && record.status == .completed {
        outcome = .completedWithoutFollowUp(toolResult: toolResult)
      } else {
        outcome = .completed(toolResult: toolResult, nextAssistantMessageID: UUID())
      }

      return ToolLoopResult(
        assistantMessageID: request.assistantMessageID,
        toolCall: output.modelMessage,
        toolCallRecord: record,
        outcome: outcome
      )
    }
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
    let request = ToolCallRequest(
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
      modelMessage: ToolCallModelMessage(request: request)
    )
  }

  private func invalidToolCallRecord(
    request: ToolCallRequest,
    originalToolName: String,
    error: String
  ) -> ToolCallRecord {
    let message = invalidToolMessage(error: error)
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
      resultPreview: ToolResultPreview(status: .failed, text: message)
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
