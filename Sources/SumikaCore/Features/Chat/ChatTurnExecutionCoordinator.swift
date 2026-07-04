import Foundation

typealias ChatTurnSessionProvider = @MainActor @Sendable () -> ChatSession
typealias ChatWorkflowEventEmitter = @MainActor @Sendable ([ChatWorkflowEvent]) -> Void
typealias ChatTurnActiveToolPromptModeHandler = @MainActor @Sendable (ToolPromptMode?) -> Void
typealias ChatTurnRuntimeCacheDebugSnapshotHandler =
  @MainActor @Sendable (
    RuntimeCacheDebugSnapshot?
  ) -> Void
typealias ChatTurnContextRefreshHandler = @MainActor @Sendable (ToolPromptMode) -> Void
typealias ChatTurnErrorMessageHandler = @MainActor @Sendable (String) -> Void
typealias ChatTurnFinishedHandler = @MainActor @Sendable (ChatTurn.ID, ToolPromptMode) -> Void
typealias ChatTurnNotifyHandler = @MainActor @Sendable () -> Void
typealias ChatTurnActiveChecker = @MainActor @Sendable (ChatTurn.ID) -> Bool
typealias ChatTurnFinisher = @MainActor @Sendable (ChatTurn.ID) -> Void

@MainActor
struct ChatTurnRuntimeContext {
  let selectedModel: ManagedModel
  let operationID: UUID
  let chatGenerationCoordinator: ChatGenerationCoordinator
  let toolLoopCoordinator: ToolLoopCoordinator
}

@MainActor
struct ChatTurnCallbacks {
  let session: ChatTurnSessionProvider
  let emitEvents: ChatWorkflowEventEmitter
  let setActiveToolPromptMode: ChatTurnActiveToolPromptModeHandler
  let updateRuntimeCacheDebugSnapshot: ChatTurnRuntimeCacheDebugSnapshotHandler
  let refreshContextUsage: ChatTurnContextRefreshHandler
  let setErrorMessage: ChatTurnErrorMessageHandler
  let turnDidFinish: ChatTurnFinishedHandler
  let notifySessionDidChange: ChatTurnNotifyHandler
}

enum ChatTurnTaskOutcome {
  case complete
  case stop
  case fail(cancelsStreaming: Bool)
}

@MainActor
struct ChatTurnExecutionCoordinator {
  private let focusedFileReducer: FocusedFileStateReducer
  private let modelContextBuilder: ChatModelContextBuilder
  private let toolPromptPolicy: ToolPromptPolicy
  private let turnTracer: any TurnTracing
  private let maxToolLoopIterations: Int

  init(
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    modelContextBuilder: ChatModelContextBuilder = ChatModelContextBuilder(),
    toolPromptPolicy: ToolPromptPolicy = ToolPromptPolicy(),
    turnTracer: any TurnTracing = NoopTurnTracer(),
    maxToolLoopIterations: Int = ChatToolLoopLimits.defaultMaxToolLoopIterations
  ) {
    self.focusedFileReducer = focusedFileReducer
    self.modelContextBuilder = modelContextBuilder
    self.toolPromptPolicy = toolPromptPolicy
    self.turnTracer = turnTracer
    self.maxToolLoopIterations = maxToolLoopIterations
  }

  func emitUserTurnStartEvents(
    prompt: String,
    turnID: ChatTurn.ID,
    userMessageID: UUID,
    assistantMessageID: UUID,
    attachments: [ChatAttachment],
    workspace: Workspace?,
    interactionMode: WorkspaceInteractionMode,
    callbacks: ChatTurnCallbacks
  ) {
    let session = callbacks.session()
    let focusedEvents = focusEventsForAttachments(
      attachments,
      workspace: workspace,
      focusedFileState: session.focusedFileState
    )
    let currentPromptContext = modelContextBuilder.currentPromptContext(
      userInput: prompt,
      mode: interactionMode,
      focusedFileState: session.focusedFileState,
      attachments: attachments,
      workspace: workspace
    )
    callbacks.emitEvents(
      focusedEvents + [
        .turnAppended(
          ChatTurn(
            id: turnID,
            status: .running
          )),
        .userMessageAppended(
          content: prompt,
          messageID: userMessageID,
          turnID: turnID,
          attachments: attachments,
          promptContext: currentPromptContext.consumedContext
        ),
      ])

    callbacks.emitEvents([
      .assistantPlaceholderAppended(
        messageID: assistantMessageID,
        turnID: turnID
      )
    ])
  }

  func streamAssistantReply(
    to assistantMessageID: UUID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks,
    isActive: ChatTurnActiveChecker,
    interactionMode: WorkspaceInteractionMode,
    toolPromptMode: ToolPromptMode,
    stableInstructions: String,
    turnID: ChatTurn.ID,
    toolLoopIteration: Int? = nil,
    attachments: [ChatAttachment] = []
  )
    async throws
    -> ChatGenerationResult
  {
    let assistantThinkingMessageID = UUID()
    var didAppendAssistantThinking = false
    let toolCallingPolicy = runtime.selectedModel.toolCallingPolicy
    callbacks.setActiveToolPromptMode(toolPromptMode)
    let systemPromptStartedAt = Date()
    let promptPlan = runtimePromptPlan(
      session: callbacks.session(),
      stableInstructions: stableInstructions,
      toolPromptMode: toolPromptMode,
      toolCallingPolicy: toolCallingPolicy,
      toolLoopCoordinator: runtime.toolLoopCoordinator,
      turnID: turnID
    )
    traceTurnPhase(
      .renderSystemPrompt,
      startedAt: systemPromptStartedAt,
      turnID: turnID,
      generationID: nil,
      promptBytes: promptPlan.stableInstructions.utf8.count,
      messageCount: callbacks.session().turns.flatMap(\.items).count,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode
    )
    let contextBuildStartedAt = Date()
    let modelPromptProjection = modelContextBuilder.transcript(
      from: callbacks.session(),
      includingTurnID: turnID
    )
    traceTurnPhase(
      .contextBuild,
      startedAt: contextBuildStartedAt,
      turnID: turnID,
      generationID: nil,
      messageCount: modelPromptProjection.entries.count,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode
    )
    let failedCommandGuard = failedRunCommandGuardContext(
      session: callbacks.session(),
      turnID: turnID
    )
    var guardedAssistantChunks = ""
    var generationResult = try await runtime.chatGenerationCoordinator.streamAssistantReplyResult(
      turnID: turnID,
      operationID: runtime.operationID,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode,
      transcript: modelPromptProjection,
      attachments: attachments,
      promptPlan: promptPlan,
      settings: callbacks.session().generationSettings,
      appendChunk: { chunk in
        guard isActive(turnID) else {
          return
        }
        if failedCommandGuard != nil {
          guardedAssistantChunks += chunk
          return
        }
        callbacks.emitEvents([
          .assistantChunkAppended(
            chunk: chunk,
            messageID: assistantMessageID
          )
        ])
      },
      appendThinkingChunk: { chunk in
        guard isActive(turnID) else {
          return
        }
        var events: [ChatWorkflowEvent] = []
        if !didAppendAssistantThinking {
          didAppendAssistantThinking = true
          events.append(
            .assistantThinkingPlaceholderAppended(
              messageID: assistantThinkingMessageID,
              turnID: turnID
            ))
        }
        events.append(
          .assistantThinkingChunkAppended(
            chunk: chunk,
            messageID: assistantThinkingMessageID
          ))
        callbacks.emitEvents(events)
      },
      updateGenerationMetrics: { metrics in
        guard isActive(turnID) else {
          return
        }
        var events: [ChatWorkflowEvent] = []
        if didAppendAssistantThinking {
          events.append(.assistantThinkingCompleted(messageID: assistantThinkingMessageID))
        }
        events.append(
          .assistantGenerationCompleted(
            messageID: assistantMessageID,
            metrics: metrics
          )
        )
        callbacks.emitEvents(events)
      },
      updateRuntimeCacheDebugSnapshot: { snapshot in
        guard isActive(turnID) else {
          return
        }
        callbacks.updateRuntimeCacheDebugSnapshot(snapshot)
      },
      updateContextUsage: {
        await MainActor.run {}
      }
    )
    guard isActive(turnID) else {
      return ChatGenerationResult(assistantContent: "")
    }
    if let failedCommandGuard {
      let streamedContent =
        guardedAssistantChunks.isEmpty ? generationResult.assistantContent : guardedAssistantChunks
      let guardedContent = guardedVisibleContent(
        streamedContent,
        guardContext: failedCommandGuard,
        nativeToolCalls: generationResult.nativeToolCalls
      )
      if !guardedContent.isEmpty {
        callbacks.emitEvents([
          .assistantChunkAppended(
            chunk: guardedContent,
            messageID: assistantMessageID
          )
        ])
      }
      generationResult.assistantContent = guardedContent
      guardedAssistantChunks = ""
    }
    callbacks.refreshContextUsage(toolPromptMode)
    return generationResult
  }

  func runToolLoop(
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    lastAssistantMessageID: UUID,
    turnID: ChatTurn.ID,
    interactionMode: WorkspaceInteractionMode,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks,
    isActive: ChatTurnActiveChecker,
    finishTurn: ChatTurnFinisher,
    stableInstructions: String,
    remainingIterations initialRemainingIterations: Int? = nil,
    lastNativeToolCalls: [ChatRuntimeToolCall] = []
  ) async throws -> Bool {
    let toolProfile = activeToolProfile(
      workspace: workspace,
      sessionID: sessionID,
      interactionMode: interactionMode,
      selectedModel: runtime.selectedModel
    )
    guard toolProfile.allowsToolLoop, let workspace, let sessionID else {
      return true
    }

    var currentAssistantMessageID = lastAssistantMessageID
    var currentNativeToolCalls = lastNativeToolCalls
    var remainingIterations = initialRemainingIterations ?? maxToolLoopIterations
    let toolCallingPolicy = runtime.selectedModel.toolCallingPolicy

    while remainingIterations > 0 {
      let toolLoopIteration = (maxToolLoopIterations - remainingIterations) + 1
      let followUpPromptMode: ToolPromptMode =
        followUpPromptMode(for: toolProfile, remainingIterations: remainingIterations)
      guard
        let step = try await runtime.toolLoopCoordinator.run(
          ToolLoopRequest(
            workspace: workspace,
            sessionID: sessionID,
            turnID: turnID,
            assistantMessageID: currentAssistantMessageID,
            items: callbacks.session().turns.flatMap(\.items),
            focusedFileState: callbacks.session().focusedFileState,
            interactionMode: interactionMode,
            toolProfile: toolProfile,
            followUpPromptMode: followUpPromptMode,
            toolLoopIteration: toolLoopIteration,
            toolCallingPolicy: toolCallingPolicy,
            nativeToolCalls: currentNativeToolCalls
          )
        )
      else {
        return true
      }
      currentNativeToolCalls = []
      remainingIterations -= 1
      try Task.checkCancellation()
      guard isActive(turnID) else {
        return false
      }

      callbacks.emitEvents(step.events)
      callbacks.notifySessionDidChange()

      switch step.continuation {
      case .awaitingApproval, .awaitingUserAnswer:
        finishTurn(turnID)
        callbacks.turnDidFinish(turnID, .disabled)
        callbacks.notifySessionDidChange()
        return false
      case .resumeGeneration(let nextAssistantMessageID, let promptMode):
        callbacks.setActiveToolPromptMode(promptMode)
        let generationResult = try await streamAssistantReply(
          to: nextAssistantMessageID,
          runtime: runtime,
          callbacks: callbacks,
          isActive: isActive,
          interactionMode: interactionMode,
          toolPromptMode: promptMode,
          stableInstructions: stableInstructions,
          turnID: turnID,
          toolLoopIteration: toolLoopIteration
        )
        currentNativeToolCalls = generationResult.nativeToolCalls
        try requireVisibleTextOrToolCall(generationResult)
        guard promptMode != .afterToolResultFinal else {
          try requireVisibleFinalResponse(generationResult)
          return true
        }
        currentAssistantMessageID = nextAssistantMessageID
      case .none, .stopTurn:
        return true
      }
    }

    throw ChatGenerationError.emptyModelResponse
  }

  func requireVisibleTextOrToolCall(_ generationResult: ChatGenerationResult) throws {
    guard
      hasVisibleAssistantContent(generationResult)
        || !generationResult.nativeToolCalls.isEmpty
    else {
      throw ChatGenerationError.emptyModelResponse
    }
  }

  func requireVisibleFinalResponse(_ generationResult: ChatGenerationResult) throws {
    guard generationResult.nativeToolCalls.isEmpty,
      hasVisibleAssistantContent(generationResult)
    else {
      throw ChatGenerationError.emptyModelResponse
    }
  }

  func hasVisibleAssistantContent(_ generationResult: ChatGenerationResult) -> Bool {
    !generationResult.assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func activeToolProfile(
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    interactionMode: WorkspaceInteractionMode,
    selectedModel: ManagedModel
  ) -> ToolExecutionProfile {
    let toolAvailability = toolPromptPolicy.toolAvailability(
      workspace: workspace,
      sessionID: sessionID
    )
    guard toolAvailability == .availableForWorkspace,
      selectedModel.supportsWorkspaceTools
    else {
      return .disabled
    }
    switch interactionMode {
    case .chat:
      return .chatWeb
    case .agent:
      return .agent
    }
  }

  func toolPromptMode(
    for toolProfile: ToolExecutionProfile
  ) -> ToolPromptMode {
    switch toolProfile {
    case .disabled:
      return .disabled
    case .chatWeb:
      return .chatWeb
    case .agent:
      return .enabled(true)
    }
  }

  func appendFinalToolFollowUpBoundaryIfNeeded(
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurn.ID,
    emitEvents: ChatWorkflowEventEmitter
  ) {
    _ = (toolPromptMode, turnID, emitEvents)
  }

  func systemPrompt(
    session: ChatSession,
    selectedModel: ManagedModel,
    toolLoopCoordinator: ToolLoopCoordinator,
    toolPromptMode: ToolPromptMode
  ) -> String {
    let registry = toolRegistry(for: toolPromptMode, toolLoopCoordinator: toolLoopCoordinator)
    return toolPromptPolicy.systemPrompt(
      basePrompt: session.systemPrompt,
      mode: toolPromptMode,
      toolRegistry: registry,
      toolCallingPolicy: selectedModel.toolCallingPolicy
    )
  }

  func currentToolPromptMode(
    session: ChatSession,
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    selectedModel: ManagedModel
  ) -> ToolPromptMode {
    return toolPromptMode(
      for: activeToolProfile(
        workspace: workspace,
        sessionID: sessionID,
        interactionMode: session.interactionMode,
        selectedModel: selectedModel
      )
    )
  }

  private func runtimePromptPlan(
    session: ChatSession,
    stableInstructions: String,
    toolPromptMode: ToolPromptMode,
    toolCallingPolicy: ToolCallingPolicy,
    toolLoopCoordinator: ToolLoopCoordinator,
    turnID: ChatTurn.ID
  ) -> ChatRuntimePromptPlan {
    ChatRuntimePromptPlan(
      stableInstructions: stableInstructions,
      transientInstructions: transientInstructions(
        session: session,
        toolPromptMode: toolPromptMode,
        toolLoopCoordinator: toolLoopCoordinator,
        turnID: turnID
      ),
      toolContext: runtimeToolContext(
        for: toolPromptMode,
        policy: toolCallingPolicy,
        stableInstructions: stableInstructions,
        toolLoopCoordinator: toolLoopCoordinator
      )
    )
  }

  private func runtimeToolContext(
    for toolPromptMode: ToolPromptMode,
    policy: ToolCallingPolicy,
    stableInstructions: String,
    toolLoopCoordinator: ToolLoopCoordinator
  ) -> ChatRuntimeToolContext? {
    guard policy.strategy == .nativeGemma4 else {
      return nil
    }
    switch toolPromptMode {
    case .disabled, .enabled(false), .afterToolResultFinal:
      return nil
    case .chatWeb, .afterChatWebToolResultCanContinue, .afterToolResultCanContinue,
      .enabled(true):
      break
    }
    let registry = toolRegistry(for: toolPromptMode, toolLoopCoordinator: toolLoopCoordinator)
    return ChatRuntimeToolContext(
      strategy: policy.strategy,
      registry: registry,
      cacheSystemPrompt: stableInstructions
    )
  }

  private func transientInstructions(
    session: ChatSession,
    toolPromptMode: ToolPromptMode,
    toolLoopCoordinator: ToolLoopCoordinator,
    turnID: ChatTurn.ID
  ) -> [String] {
    var instructions: [String] = []
    if session.interactionMode == .agent,
      toolLoopCoordinator.toolRegistry.definition(for: .todoWrite) != nil,
      let planBlock = TodoPromptRenderer.compactPlanBlock(for: session.todoState)
    {
      instructions.append(
        """
        [Runtime Context]
        \(planBlock)
        """
      )
    }
    if let failedCommandInstruction = failedRunCommandRuntimeInstruction(
      session: session,
      turnID: turnID
    ) {
      instructions.append(failedCommandInstruction)
    }
    if let repeatedCallInstruction = repeatedNonReadToolCallRuntimeInstruction(
      session: session,
      turnID: turnID
    ) {
      instructions.append(repeatedCallInstruction)
    }
    if let listingWanderingInstruction = listingWanderingRuntimeInstruction(
      session: session,
      turnID: turnID
    ) {
      instructions.append(listingWanderingInstruction)
    }
    if toolPromptMode == .afterToolResultFinal {
      instructions.append(Self.finalToolResultRuntimeInstruction)
    }
    return instructions
  }

  private static let finalToolResultRuntimeInstruction =
    """
    [Runtime Instruction]
    No more tools are available for this generation. Produce visible final text. Do not call another tool.
    Mention completed changes, affected paths, and run or verification steps if useful.
    Do not include generated file contents, code blocks, diffs, or tool arguments unless the user explicitly asked to display them in chat.
    Never say files were changed unless a successful write_file or edit_file result exists in this turn.
    Failed or invalid write/edit tool results mean no workspace change happened.
    If more work is needed, briefly say what remains and ask the user to send another message.
    """

  private func followUpPromptMode(
    for toolProfile: ToolExecutionProfile,
    remainingIterations: Int
  ) -> ToolPromptMode {
    guard remainingIterations > 1 else {
      return .afterToolResultFinal
    }

    switch toolProfile {
    case .disabled:
      return .disabled
    case .chatWeb:
      return .afterChatWebToolResultCanContinue
    case .agent:
      return .afterToolResultCanContinue
    }
  }

  private func toolRegistry(
    for toolPromptMode: ToolPromptMode,
    toolLoopCoordinator: ToolLoopCoordinator
  ) -> ToolRegistry {
    switch toolPromptMode {
    case .chatWeb, .afterChatWebToolResultCanContinue:
      return toolLoopCoordinator.toolRegistry(for: .chatWeb)
    case .enabled(true), .afterToolResultCanContinue:
      return toolLoopCoordinator.toolRegistry
    case .disabled, .enabled(false), .afterToolResultFinal:
      return ToolRegistry(tools: [])
    }
  }

  private func focusEventsForAttachments(
    _ attachments: [ChatAttachment],
    workspace: Workspace?,
    focusedFileState: FocusedFileState
  ) -> [ChatWorkflowEvent] {
    let updatedState = focusedFileReducer.applyingAttachments(
      attachments,
      workspace: workspace,
      to: focusedFileState
    )
    guard updatedState != focusedFileState else {
      return []
    }
    return [.focusedFileStateChanged(updatedState)]
  }

  private func traceTurnPhase(
    _ phase: TurnTracePhase,
    startedAt: Date,
    turnID: ChatTurn.ID?,
    generationID: UUID?,
    promptBytes: Int? = nil,
    promptTokens: Int? = nil,
    messageCount: Int,
    toolLoopIteration: Int? = nil,
    toolName: String? = nil,
    ttftMs: Double? = nil,
    tokensPerSecond: Double? = nil,
    cacheMode: String? = nil,
    interactionMode: WorkspaceInteractionMode? = nil
  ) {
    let durationMs = Date().timeIntervalSince(startedAt) * 1000
    Task {
      await turnTracer.recordTurnTraceEvent(
        TurnTraceEvent(
          turnID: turnID,
          generationID: generationID,
          phase: phase,
          durationMs: durationMs,
          promptBytes: promptBytes,
          promptTokens: promptTokens,
          messageCount: messageCount,
          toolLoopIteration: toolLoopIteration,
          toolName: toolName,
          ttftMs: ttftMs,
          tokensPerSecond: tokensPerSecond,
          cacheMode: cacheMode,
          interactionMode: interactionMode
        )
      )
    }
  }
}

extension ChatTurnExecutionCoordinator {
  fileprivate struct RepeatedToolCallSignature: Equatable {
    var toolName: ToolName
    var value: RepeatedToolCallSignatureValue
  }

  fileprivate enum RepeatedToolCallSignatureValue: Equatable {
    case payload(ToolCallPayload)
    case runCommand(String)
  }

  fileprivate struct ListingWanderingState {
    var listingCountWithoutRead: Int = 0
    var latestReplayLines: [String] = []
  }

  fileprivate struct FailedRunCommandGuardContext {
    var exitCode: Int32?
    var timedOut: Bool
    var cancelled: Bool

    var replacementAssistantContent: String {
      var lines = [
        "The previous command failed.",
        "Exit code: \(exitCode.map(String.init) ?? "none").",
        "I cannot report the requested task as complete based on that failed command.",
      ]
      if timedOut {
        lines.append("The command timed out.")
      }
      if cancelled {
        lines.append("The command was cancelled.")
      }
      lines.append(
        "Inspect the output, run a corrected command, or ask me to continue with the next recovery step."
      )
      return lines.joined(separator: "\n")
    }
  }

  fileprivate func failedRunCommandGuardContext(
    session: ChatSession,
    turnID: ChatTurn.ID
  ) -> FailedRunCommandGuardContext? {
    guard let result = latestFailedRunCommandResult(session: session, turnID: turnID) else {
      return nil
    }
    return FailedRunCommandGuardContext(
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      cancelled: result.cancelled
    )
  }

  fileprivate func guardedVisibleContent(
    _ content: String,
    guardContext: FailedRunCommandGuardContext,
    nativeToolCalls: [ChatRuntimeToolCall]
  ) -> String {
    guard nativeToolCalls.isEmpty else {
      return content
    }
    guard containsUnqualifiedCompletionClaim(content) else {
      return content
    }
    return guardContext.replacementAssistantContent
  }

  fileprivate func containsUnqualifiedCompletionClaim(_ content: String) -> Bool {
    let lowercasedContent = content.lowercased()
    let failureSignals = [
      "failed",
      "failure",
      "error",
      "exit code",
      "did not",
      "does not",
      "cannot",
      "can't",
      "could not",
      "couldn't",
      "not complete",
      "not completed",
      "not successful",
      "unsuccessful",
      "non-zero",
      "nonzero",
    ]
    if failureSignals.contains(where: { lowercasedContent.contains($0) }) {
      return false
    }
    let completionSignals = [
      "success",
      "successful",
      "succeeded",
      "complete",
      "completed",
      "done",
      "finished",
      "committed",
      "staged",
      "passed",
      "built",
      "installed",
      "created",
      "updated",
      "applied",
    ]
    return completionSignals.contains { lowercasedContent.contains($0) }
  }

  fileprivate func failedRunCommandRuntimeInstruction(
    session: ChatSession,
    turnID: ChatTurn.ID
  ) -> String? {
    guard let result = latestFailedRunCommandResult(session: session, turnID: turnID) else {
      return nil
    }

    var lines = [
      "[System Notice]",
      "The previous run_command result in this turn failed.",
      "Command: \(result.command)",
      "Exit code: \(result.exitCode.map(String.init) ?? "none")",
      "Timed out: \(result.timedOut)",
      "Cancelled: \(result.cancelled)",
    ]
    if let outputRef = result.outputRef {
      lines.append("Output ref: \(outputRef)")
    }
    lines.append(
      "You MUST NOT report the requested task as complete based on this failed command."
    )
    lines.append(
      "Do not infer workspace state from this failure alone; verify with tools when state matters."
    )
    lines.append(
      "If tools are available, inspect the output, use workspace_diagnostics with the outputRef when useful, or rerun a corrected command. If tools are unavailable, say the command failed and briefly state what remains."
    )
    return lines.joined(separator: "\n")
  }

  fileprivate func repeatedNonReadToolCallRuntimeInstruction(
    session: ChatSession,
    turnID: ChatTurn.ID
  ) -> String? {
    guard session.interactionMode == .agent,
      let repeatedCall = repeatedNonReadToolCall(session: session, turnID: turnID),
      repeatedCall.count >= 3
    else {
      return nil
    }

    if repeatedCall.signature.toolName == .runCommand {
      return """
        [System Notice]
        You have made the same `run_command` command 3+ times in a row.
        Do not keep repeating it. Inspect the output, correct the command, or report what is blocking you.
        """
    }

    return """
      [System Notice]
      You have made the exact same `\(repeatedCall.signature.toolName.rawValue)` tool call with identical arguments 3+ times in a row.
      Do not keep repeating it. Inspect the output, change approach, or report what is blocking you.
      """
  }

  fileprivate func listingWanderingRuntimeInstruction(
    session: ChatSession,
    turnID: ChatTurn.ID
  ) -> String? {
    guard session.interactionMode == .agent,
      let turn = session.turns.first(where: { $0.id == turnID })
    else {
      return nil
    }

    let state = listingWanderingState(in: turn)
    guard state.listingCountWithoutRead >= 2 else {
      return nil
    }

    var lines = [
      "[System Notice]",
      "You are looping on listings/searches. Stop listing.",
      "Choose one path from the latest entries or matches and call read_file, or provide the final answer.",
      "Do not call list_files, glob_files, or search_files again for broad exploration.",
      "Only use them again for one specific missing filename.",
    ]
    if !state.latestReplayLines.isEmpty {
      lines.append("Latest entries or matches:")
      lines.append(contentsOf: state.latestReplayLines.map { "- \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  fileprivate func listingWanderingState(in turn: ChatTurn) -> ListingWanderingState {
    var state = ListingWanderingState()
    for item in turn.items {
      guard case .tool(let record) = item,
        let payload = record.resultPayload
      else {
        continue
      }

      switch payload {
      case .readFile(.success), .readFile(.unchanged):
        state = ListingWanderingState()
      case .listFiles(let result):
        state.listingCountWithoutRead += 1
        let replayLines = listingReplayLines(for: result)
        if !replayLines.isEmpty {
          state.latestReplayLines = replayLines
        }
      case .globFiles(let result):
        state.listingCountWithoutRead += 1
        let replayLines = listingReplayLines(for: result)
        if !replayLines.isEmpty {
          state.latestReplayLines = replayLines
        }
      case .searchFiles(let result):
        state.listingCountWithoutRead += 1
        let replayLines = listingReplayLines(for: result)
        if !replayLines.isEmpty {
          state.latestReplayLines = replayLines
        }
      default:
        continue
      }
    }
    return state
  }

  fileprivate func listingReplayLines(for result: ListFilesResult) -> [String] {
    result.entries.prefix(8).map { entry in
      entry.kind == .directory ? "\(entry.path.rawValue)/" : entry.path.rawValue
    }
  }

  fileprivate func listingReplayLines(for result: GlobFilesResult) -> [String] {
    result.matches.prefix(8).map(\.rawValue)
  }

  fileprivate func listingReplayLines(for result: SearchFilesResult) -> [String] {
    result.matches.prefix(8).map { match in
      let compactSnippet = compactListingReplaySnippet(match.snippet)
      guard !compactSnippet.isEmpty else {
        return "\(match.path.rawValue):\(match.line)"
      }
      return "\(match.path.rawValue):\(match.line): \(compactSnippet)"
    }
  }

  fileprivate func compactListingReplaySnippet(_ snippet: String) -> String {
    let compact =
      snippet
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count > 120 else {
      return compact
    }
    return String(compact.prefix(120))
  }

  fileprivate func repeatedNonReadToolCall(
    session: ChatSession,
    turnID: ChatTurn.ID
  ) -> (signature: RepeatedToolCallSignature, count: Int)? {
    guard let turn = session.turns.first(where: { $0.id == turnID }) else {
      return nil
    }

    var repeatedSignature: RepeatedToolCallSignature?
    var repeatedCount = 0

    for item in turn.items.reversed() {
      guard case .tool(let record) = item else {
        continue
      }
      guard isCompletedToolExecution(record),
        let signature = nonReadSignature(for: record)
      else {
        break
      }

      if repeatedSignature == nil {
        repeatedSignature = signature
      }
      guard signature == repeatedSignature else {
        break
      }
      repeatedCount += 1
    }

    guard let repeatedSignature else {
      return nil
    }
    return (repeatedSignature, repeatedCount)
  }

  fileprivate func isCompletedToolExecution(_ record: ToolCallRecord) -> Bool {
    if record.status == .completed {
      return true
    }
    if case .runCommand = record.resultPayload {
      return true
    }
    return false
  }

  fileprivate func nonReadSignature(for record: ToolCallRecord) -> RepeatedToolCallSignature? {
    guard !isReplayableReadLikeTool(record.request.toolName) else {
      return nil
    }
    if case .invalid = record.request.payload {
      return nil
    }
    if case .runCommand(let input) = record.request.payload {
      return RepeatedToolCallSignature(
        toolName: record.request.toolName,
        value: .runCommand(input.command)
      )
    }
    return RepeatedToolCallSignature(
      toolName: record.request.toolName,
      value: .payload(record.request.payload)
    )
  }

  fileprivate func isReplayableReadLikeTool(_ toolName: ToolName) -> Bool {
    switch toolName {
    case .readFile, .listFiles, .globFiles, .searchFiles, .workspaceDiff, .workspaceDiagnostics,
      .webSearch, .webFetch:
      return true
    default:
      return false
    }
  }

  fileprivate func latestFailedRunCommandResult(
    session: ChatSession,
    turnID: ChatTurn.ID
  ) -> RunCommandResult? {
    guard session.interactionMode == .agent,
      let turn = session.turns.first(where: { $0.id == turnID }),
      let record = latestToolRecord(in: turn),
      record.request.toolName == .runCommand,
      case .runCommand(let result) = record.resultPayload,
      result.outcomeStatus == .failed
    else {
      return nil
    }
    return result
  }

  fileprivate func latestToolRecord(in turn: ChatTurn) -> ToolCallRecord? {
    for item in turn.items.reversed() {
      guard case .tool(let record) = item else {
        continue
      }
      return record
    }
    return nil
  }
}
