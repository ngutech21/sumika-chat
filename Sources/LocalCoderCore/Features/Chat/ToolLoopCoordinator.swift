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
    toolCallingPolicy: ToolCallingPolicy = .taggedAction,
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

nonisolated private enum ToolLoopParsedAction: Equatable, Sendable {
  case none
  case toolCalls([ToolCallParseOutput], recoveredFromMalformedContent: Bool)
  case invalid(originalToolName: String, error: String)
}

public struct ToolLoopCoordinator: Sendable {
  private let toolCallParser: any ToolCallParsing
  private let agentToolOrchestrator: any ToolOrchestrating
  private let focusedFileReducer: FocusedFileStateReducer
  private let turnTracer: any TurnTracing

  public init(
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    agentToolOrchestrator: any ToolOrchestrating = ToolOrchestrator(
      executorRegistry: .codingAgent),
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.toolCallParser = toolCallParser
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

    let assistantContent = assistantContent(for: request.assistantMessageID, in: request.items)
    let parseStartedAt = Date()
    let parsedAction: ToolLoopParsedAction
    do {
      if !request.nativeToolCalls.isEmpty {
        parsedAction = nativeToolActions(
          request.nativeToolCalls,
          policy: request.toolCallingPolicy,
          workspaceID: request.workspace.id,
          sessionID: request.sessionID
        )
      } else {
        parsedAction = try parseToolAction(
          assistantContent,
          workspaceID: request.workspace.id,
          sessionID: request.sessionID
        )
      }
    } catch {
      await traceToolPhase(
        .toolParse,
        startedAt: parseStartedAt,
        request: request,
        toolName: nil
      )
      throw error
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
    case .invalid(let originalToolName, let error):
      let output = invalidToolCallOutput(
        originalToolName: originalToolName,
        error: error,
        rawText: assistantContent,
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
          payload: record.resultPayload
            ?? .failure(
              ToolFailure(
                toolName: output.request.toolName,
                path: nil,
                reason: .executionError(invalidToolMessage(error: error))
              ))
        ),
        focusedFileState: request.focusedFileState,
        followUpPromptMode: request.followUpPromptMode
      )
    case .toolCalls(let outputs, let recoveredFromMalformedContent):
      return await executeToolCalls(
        outputs,
        recoveredFromMalformedContent: recoveredFromMalformedContent,
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
    recoveredFromMalformedContent: Bool,
    request: ToolLoopRequest
  ) async -> ChatWorkflowStep {
    guard !outputs.isEmpty else {
      return ChatWorkflowStep(events: [], continuation: .none)
    }

    let nextAssistantMessageID = UUID()
    var events: [ChatWorkflowEvent] = []
    var focusedFileState = request.focusedFileState
    var nextFollowUpPromptMode = request.followUpPromptMode

    for (index, output) in outputs.enumerated() {
      let executeStartedAt = Date()
      var record = await toolOrchestrator(for: request.interactionMode).execute(
        request: output.request,
        workspace: request.workspace
      )
      await traceToolExecution(
        startedAt: executeStartedAt,
        loopRequest: request,
        rawRequest: output.request,
        record: record
      )
      appendRecoveryEventIfNeeded(
        to: &record,
        recoveredFromMalformedContent: recoveredFromMalformedContent && index == 0
      )

      if index == 0 {
        events.append(
          .assistantMessageAnnotatedAsToolCall(
            assistantMessageID: request.assistantMessageID,
            toolCall: output.modelMessage
          ))
      }
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
        defaultMode: nextFollowUpPromptMode,
        interactionMode: request.interactionMode
      )

      if let directResponse = directResponse(
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
        toolCallFormat: loopRequest.nativeToolCalls.isEmpty ? "tagged" : "native",
        toolValidationStatus: invalidInput == nil ? "valid" : "invalid",
        toolValidationError: invalidInput?.reason.message,
        toolOriginalName: invalidInput?.originalName,
        toolArgumentKeys: rawRequest.arguments.keys.sorted(),
        toolArguments: toolArgumentTraces(
          from: rawRequest.arguments,
          toolName: rawRequest.toolName
        )
      )
    )
  }

  private func toolArgumentTraces(
    from arguments: ToolCallArguments,
    toolName: ToolName
  ) -> [ToolArgumentTrace] {
    arguments.keys.sorted().map { name in
      let value = arguments[name] ?? .null
      let preview =
        shouldRedactToolArgument(name, toolName: toolName)
        ? (value: "[redacted]", truncated: false)
        : truncatedToolArgumentPreview(value.displayValue)
      return ToolArgumentTrace(
        name: name,
        valueType: toolArgumentTypeName(value),
        preview: preview.value,
        previewTruncated: preview.truncated
      )
    }
  }

  private func shouldRedactToolArgument(_ name: String, toolName: ToolName) -> Bool {
    switch toolName {
    case .writeFile:
      name == "content"
    case .editFile:
      name == "old_text" || name == "new_text"
    default:
      false
    }
  }

  private func toolArgumentTypeName(_ value: ToolArgumentValue) -> String {
    switch value {
    case .string:
      return "string"
    case .number:
      return "number"
    case .bool:
      return "bool"
    case .array:
      return "array"
    case .object:
      return "object"
    case .null:
      return "null"
    }
  }

  private func truncatedToolArgumentPreview(_ value: String) -> (value: String, truncated: Bool) {
    let limit = 500
    guard value.count > limit else {
      return (value, false)
    }
    return (String(value.prefix(limit)), true)
  }

  private func completedStep(
    assistantMessageID: UUID,
    turnID: ChatTurn.ID,
    toolCall: ToolCallModelMessage,
    record: ToolCallRecord,
    toolResult: ToolResultModelMessage,
    focusedFileState: FocusedFileState,
    followUpPromptMode: ToolPromptMode,
    directResponse: DirectToolResultResponse? = nil
  ) -> ChatWorkflowStep {
    let nextAssistantMessageID = UUID()
    var events: [ChatWorkflowEvent] = [
      .assistantMessageAnnotatedAsToolCall(
        assistantMessageID: assistantMessageID,
        toolCall: toolCall
      ),
      .toolCallAppended(record, turnID: turnID),
      .toolResultAppended(toolResult, turnID: turnID),
    ]
    events.append(contentsOf: focusedFileEvents(record: record, from: focusedFileState))
    if let directResponse {
      events.append(
        .assistantMessageAppended(
          content: directResponse.content,
          modelContextContent: directResponse.modelContextContent,
          messageID: nextAssistantMessageID,
          turnID: turnID
        )
      )
      return ChatWorkflowStep(events: events, continuation: .stopTurn)
    }
    events.append(.assistantPlaceholderAppended(messageID: nextAssistantMessageID, turnID: turnID))
    return ChatWorkflowStep(
      events: events,
      continuation: .resumeGeneration(
        assistantMessageID: nextAssistantMessageID,
        promptMode: followUpPromptMode
      )
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
    sessionID: ChatSession.ID
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
        return .toolCalls([output], recoveredFromMalformedContent: false)
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
          return .toolCalls([output], recoveredFromMalformedContent: true)
        }
      } catch let parseError as TaggedToolCallParseError {
        return .invalid(
          originalToolName: ToolIntentHeuristics.inferredToolName(from: content),
          error: errorDescription(from: parseError)
        )
      }
    }
  }

  private func nativeToolActions(
    _ toolCalls: [ChatRuntimeToolCall],
    policy: ToolCallingPolicy,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) -> ToolLoopParsedAction {
    guard toolCalls.count <= 1 || policy.allowsMultipleToolCalls else {
      return .invalid(
        originalToolName: toolCalls.first?.name ?? "native_tool_call",
        error:
          "Model emitted multiple native tool calls, but this model is configured for one "
          + "tool call per turn. Emit one tool call, wait for the result, then continue."
      )
    }

    let outputs = toolCalls.map { toolCall in
      let request = RawToolCallRequest(
        workspaceID: workspaceID,
        sessionID: sessionID,
        toolName: ToolName(canonicalizing: toolCall.name),
        arguments: toolCall.arguments,
        rawText: toolCall.rawText,
        createdAt: Date()
      )
      return ToolCallParseOutput(
        request: request,
        modelMessage: ToolCallModelMessage(rawRequest: request)
      )
    }
    return .toolCalls(outputs, recoveredFromMalformedContent: false)
  }

  private func appendRecoveryEventIfNeeded(
    to record: inout ToolCallRecord,
    recoveredFromMalformedContent: Bool
  ) {
    guard recoveredFromMalformedContent else {
      return
    }

    record.events.append(
      ToolCallEvent(
        actor: .system,
        kind: .requested,
        message:
          "Recovered one complete tagged <action> block from malformed assistant content; "
          + "ignored surrounding text or Markdown."
      ))
  }

  private func followUpPromptMode(
    after record: ToolCallRecord,
    defaultMode: ToolPromptMode,
    interactionMode: WorkspaceInteractionMode
  ) -> ToolPromptMode {
    guard record.status == .completed else {
      return defaultMode
    }
    switch record.request.toolName {
    case .writeFile, .editFile:
      return .afterToolResultFinal
    default:
      return defaultMode
    }
  }

  private func directResponse(
    after record: ToolCallRecord,
    toolResult: ToolResultModelMessage,
    request: ToolLoopRequest
  ) -> DirectToolResultResponse? {
    guard record.status == .completed else {
      return nil
    }

    switch record.resultPayload {
    case .readFile(.success(let path, _)) where record.request.toolName == .showFile:
      let projection = ToolResultProjector.project(
        payload: toolResult.payload, request: record.request)
      return DirectToolResultResponse(
        content: directReadFileResponse(path: path, display: projection.display),
        modelContextContent:
          "Displayed show_file result for \(path.rawValue) directly to the user."
      )
    case .listFiles(let result) where shouldRespondDirectlyToListFiles(request):
      let projection = ToolResultProjector.project(
        payload: toolResult.payload, request: record.request)
      return DirectToolResultResponse(
        content: directListFilesResponse(result: result, display: projection.display),
        modelContextContent:
          "Displayed list_files result for \(result.root.rawValue) directly to the user."
      )
    case .workspaceDiff(.success(let path, let content))
    where shouldRespondDirectlyToWorkspaceDiff(request):
      return DirectToolResultResponse(
        content: directWorkspaceDiffResponse(path: path, content: content),
        modelContextContent: "Displayed workspace_diff result directly to the user."
      )
    default:
      return nil
    }
  }

  private func directReadFileResponse(
    path: WorkspaceRelativePath,
    display: ToolDisplayPayload
  ) -> String {
    var response = "Here is `\(path.rawValue)`:"
    guard case .fileContent(_, let content) = display else {
      return response
    }
    let body = content.text.isEmpty ? "(empty)" : content.text
    response += "\n\n"
    response += body.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "    \($0)" }
      .joined(separator: "\n")
    if content.truncated {
      response += "\n\nResult truncated."
    }
    if content.redacted {
      response += "\n\nSome content was redacted."
    }
    return response
  }

  private func directListFilesResponse(
    result: ListFilesResult,
    display: ToolDisplayPayload
  ) -> String {
    var response = "Files in `\(result.root.rawValue)`:"
    guard case .fileList(_, let entries, let truncated) = display else {
      return response
    }
    let body =
      entries.isEmpty
      ? "(empty)"
      : entries.map { entry in
        entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
      }.joined(separator: "\n")
    response += "\n\n"
    response += body.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "    \($0)" }
      .joined(separator: "\n")
    if truncated {
      response += "\n\nResult truncated."
    }
    return response
  }

  private func directWorkspaceDiffResponse(
    path: WorkspaceRelativePath?,
    content: ToolTextOutput
  ) -> String {
    var response =
      if let path {
        "Workspace changes for `\(path.rawValue)`:"
      } else {
        "Workspace changes:"
      }
    let body = content.text.isEmpty ? "No workspace changes." : content.text
    response += "\n\n"
    response += body.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "    \($0)" }
      .joined(separator: "\n")
    if content.truncated {
      response += "\n\nResult truncated."
    }
    if content.redacted {
      response += "\n\nSome content was redacted."
    }
    return response
  }

  private func shouldRespondDirectlyToListFiles(_ request: ToolLoopRequest) -> Bool {
    guard request.interactionMode == .agent,
      let userContent = latestUserRequestContent(for: request)
    else {
      return false
    }
    return isDirectListFilesRequest(userContent)
  }

  private func latestUserRequestContent(for request: ToolLoopRequest) -> String? {
    guard
      let assistantIndex = request.items.firstIndex(where: {
        $0.messageID == request.assistantMessageID
      }
      )
    else {
      return request.items.reversed().compactMap(\.userContent).first
    }

    return request.items[..<assistantIndex].reversed().compactMap(\.userContent).first
  }

  private func isDirectListFilesRequest(_ content: String) -> Bool {
    let lowered = content.lowercased()
    guard
      !containsAny(
        [
          " and ",
          " then ",
          "tell me",
          "summarize",
          "summary",
          "explain",
          "analy",
          "inspect",
          "read",
          "search",
          "find",
          "choose",
          "entry point",
          "structure",
          "which one",
          "which file should",
          "which file looks",
          "which file is",
        ],
        in: lowered
      )
    else {
      return false
    }

    let mentionsFile =
      containsAny(["file", "files"], in: lowered)
    let hasListVerb = containsAny(["list"], in: lowered)
    let asksWhichFiles = containsAny(
      ["what files", "which files"],
      in: lowered
    )
    let hasDisplayVerb = containsAny(
      ["show", "display", "print"],
      in: lowered
    )
    let mentionsDirectory = containsAny(
      ["directory", "current dir", "dir", "folder"],
      in: lowered
    )
    let mentionsPluralFiles = containsAny(["files"], in: lowered)

    return (hasListVerb && mentionsFile)
      || asksWhichFiles
      || (hasDisplayVerb && mentionsPluralFiles && mentionsDirectory)
  }

  private func shouldRespondDirectlyToWorkspaceDiff(_ request: ToolLoopRequest) -> Bool {
    guard let userContent = latestUserRequestContent(for: request) else {
      return false
    }

    let lowered = userContent.lowercased()
    guard
      !containsAny(
        [
          " and ",
          " then ",
          "tell me",
          "summarize",
          "summary",
          "explain",
          "analy",
          "inspect",
          "review",
          "fix",
          "edit",
          "change it",
          "implement",
          "update",
          "which ",
          "erklär",
          "erklaer",
          "analys",
          "prüf",
          "pruef",
          "repar",
          "ändere",
          "aendere",
          "implementier",
        ],
        in: lowered
      )
    else {
      return false
    }

    let asksForDisplay = containsAny(
      ["show", "display", "print", "zeige", "zeig", "anzeigen"],
      in: lowered
    )
    let asksForDiff = containsAny(
      [
        "git diff",
        "workspace diff",
        "diff",
        "changes",
        "änderungen",
        "aenderungen",
        "git status",
        "git changes",
      ],
      in: lowered
    )

    return asksForDisplay && asksForDiff
  }

  private func containsAny(_ needles: [String], in haystack: String) -> Bool {
    needles.contains { haystack.contains($0) }
  }

  private func invalidToolCallOutput(
    originalToolName: String,
    error: String,
    rawText: String,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
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
      state: .failed(resultPayload)
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

  private func assistantContent(for id: UUID, in items: [ChatTurnItem]) -> String {
    items.compactMap { item -> String? in
      guard case .assistantMessage(let message) = item, message.id == id else {
        return nil
      }
      return message.content
    }.first ?? ""
  }
}

extension ToolLoopParsedAction {
  fileprivate var toolName: String? {
    switch self {
    case .none:
      nil
    case .invalid(let originalToolName, _):
      originalToolName
    case .toolCalls(let outputs, _):
      outputs.map(\.request.toolName.rawValue).joined(separator: ",")
    }
  }
}

private struct DirectToolResultResponse: Equatable, Sendable {
  var content: String
  var modelContextContent: String
}
