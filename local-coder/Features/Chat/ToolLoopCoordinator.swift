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

nonisolated struct ToolLoopCoordinator: Sendable {
  private let toolCallParser: any ToolCallParsing
  private let toolOrchestrator: any ToolOrchestrating
  private let maxToolIterations: Int

  init(
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    toolOrchestrator: any ToolOrchestrating = ToolOrchestrator(),
    maxToolIterations: Int = 1
  ) {
    self.toolCallParser = toolCallParser
    self.toolOrchestrator = toolOrchestrator
    self.maxToolIterations = maxToolIterations
  }

  var toolRegistry: ToolRegistry {
    toolOrchestrator.toolRegistry
  }

  func run(_ request: ToolLoopRequest) async throws -> ToolLoopResult? {
    guard maxToolIterations > 0 else {
      return nil
    }

    try Task.checkCancellation()
    let assistantContent = messageContent(for: request.assistantMessageID, in: request.messages)
    let parseResult = try parseToolCallResult(
      assistantContent,
      workspaceID: request.workspace.id,
      sessionID: request.sessionID
    )

    guard case .toolCall(let output) = parseResult else {
      return nil
    }

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
    if output.request.toolName == .writeFile && record.status == .completed {
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

  private func parseToolCallResult(
    _ content: String,
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID
  ) throws -> ToolCallParseResult {
    do {
      return try toolCallParser.parse(
        content,
        workspaceID: workspaceID,
        sessionID: sessionID,
        createdAt: Date()
      )
    } catch is TaggedToolCallParseError {
      guard let actionContent = recoverableToolActionContent(from: content) else {
        return .none
      }

      do {
        return try toolCallParser.parse(
          actionContent,
          workspaceID: workspaceID,
          sessionID: sessionID,
          createdAt: Date()
        )
      } catch is TaggedToolCallParseError {
        return .none
      }
    }
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
