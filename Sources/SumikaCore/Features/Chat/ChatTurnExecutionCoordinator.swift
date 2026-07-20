import Foundation

@MainActor
struct ChatTurnRuntimeContext {
  let selectedModel: ManagedModel
  let operationID: UUID
  let chatGenerationCoordinator: ChatGenerationCoordinator
  let toolLoopCoordinator: ToolLoopCoordinator
  let agentToolOrchestrator: ToolOrchestrator
}

enum ChatTurnTaskOutcome {
  case complete
  case pause(ChatTurnStatus)
  case stop
  case fail(cancelsStreaming: Bool)
}

enum ChatToolLoopOutcome {
  case complete
  case stop
  case resumeAutomaticApproval(batchAnchorID: ToolCallRecord.ID)
}

@MainActor
struct ChatTurnExecutionCoordinator {
  private let focusedFileReducer: FocusedFileStateReducer
  private let modelContextBuilder: ChatModelContextBuilder
  private let toolPromptPolicy: ToolPromptPolicy
  private let toolFollowUpNoticePolicy: ToolFollowUpNoticePolicy
  private let turnTracer: any TurnTracing
  private let maxToolLoopIterations: Int

  init(
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    modelContextBuilder: ChatModelContextBuilder = ChatModelContextBuilder(),
    toolPromptPolicy: ToolPromptPolicy = ToolPromptPolicy(),
    toolFollowUpNoticePolicy: ToolFollowUpNoticePolicy = ToolFollowUpNoticePolicy(),
    turnTracer: any TurnTracing = NoopTurnTracer(),
    maxToolLoopIterations: Int = ChatToolLoopLimits.defaultMaxToolLoopIterations
  ) {
    self.focusedFileReducer = focusedFileReducer
    self.modelContextBuilder = modelContextBuilder
    self.toolPromptPolicy = toolPromptPolicy
    self.toolFollowUpNoticePolicy = toolFollowUpNoticePolicy
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
    conversation: ConversationEngine
  ) {
    let session = conversation.chatSession
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
    conversation.applyWorkflowEvents(
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

    conversation.applyWorkflowEvents([
      .assistantPlaceholderAppended(
        messageID: assistantMessageID,
        turnID: turnID
      )
    ])
  }

  func streamAssistantReply(
    to assistantMessageID: UUID,
    runtime: ChatTurnRuntimeContext,
    conversation: ConversationEngine,
    interactionMode: WorkspaceInteractionMode,
    toolPromptMode: ToolPromptMode,
    turnToolRegistry: ToolRegistry,
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
    var didCompleteAssistantThinking = false
    let toolCallingPolicy = runtime.selectedModel.toolCallingPolicy
    conversation.setActiveToolPromptMode(toolPromptMode)
    applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: toolPromptMode,
      turnID: turnID,
      conversation: conversation
    )
    let systemPromptStartedAt = Date()
    let promptPlan = try runtimePromptPlan(
      session: conversation.chatSession,
      stableInstructions: stableInstructions,
      toolPromptMode: toolPromptMode,
      toolCallingPolicy: toolCallingPolicy,
      turnToolRegistry: turnToolRegistry
    )
    traceTurnPhase(
      .renderSystemPrompt,
      startedAt: systemPromptStartedAt,
      turnID: turnID,
      generationID: nil,
      promptBytes: promptPlan.stableInstructions.utf8.count,
      messageCount: conversation.chatSession.turns.flatMap(\.items).count,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode,
      selectedMCPServerIDs: conversation.chatSession.selectedMCPServerIDs,
      activeMCPToolCount: promptPlan.toolContext?.registry.tools.count {
        $0.capabilities.contains(.externalService)
      } ?? 0
    )
    let contextBuildStartedAt = Date()
    let modelPromptProjection = modelContextBuilder.transcript(
      from: conversation.chatSession,
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
      session: conversation.chatSession,
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
      settings: conversation.chatSession.generationSettings,
      appendChunk: { chunk in
        guard conversation.isActive(turnID) else {
          return
        }
        if failedCommandGuard != nil {
          guardedAssistantChunks += chunk
          return
        }
        var events: [ChatWorkflowEvent] = []
        // Reasoning ends the moment visible output starts, not when the whole
        // generation finishes: the transcript switches the thinking row to its
        // "Reasoned for Xs" summary while the answer keeps streaming.
        if didAppendAssistantThinking, !didCompleteAssistantThinking {
          didCompleteAssistantThinking = true
          events.append(.assistantThinkingCompleted(messageID: assistantThinkingMessageID))
        }
        events.append(
          .assistantChunkAppended(
            chunk: chunk,
            messageID: assistantMessageID
          ))
        conversation.applyWorkflowEvents(events)
      },
      appendThinkingChunk: { chunk in
        guard conversation.isActive(turnID) else {
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
        conversation.applyWorkflowEvents(events)
      },
      updateGenerationMetrics: { metrics in
        guard conversation.isActive(turnID) else {
          return
        }
        var events: [ChatWorkflowEvent] = []
        if didAppendAssistantThinking, !didCompleteAssistantThinking {
          didCompleteAssistantThinking = true
          events.append(.assistantThinkingCompleted(messageID: assistantThinkingMessageID))
        }
        events.append(
          .assistantGenerationCompleted(
            messageID: assistantMessageID,
            metrics: metrics
          )
        )
        conversation.applyWorkflowEvents(events)
      },
      updateRuntimeCacheDebugSnapshot: { snapshot in
        guard conversation.isActive(turnID) else {
          return
        }
        conversation.updateRuntimeCacheDebugSnapshot(snapshot)
      }
    )
    guard conversation.isActive(turnID) else {
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
        conversation.applyWorkflowEvents([
          .assistantChunkAppended(
            chunk: guardedContent,
            messageID: assistantMessageID
          )
        ])
      }
      generationResult.assistantContent = guardedContent
      guardedAssistantChunks = ""
    }
    conversation.refreshContextUsage(toolPromptMode: toolPromptMode)
    return generationResult
  }

  func runToolLoop(
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    lastAssistantMessageID: UUID,
    turnID: ChatTurn.ID,
    interactionMode: WorkspaceInteractionMode,
    runtime: ChatTurnRuntimeContext,
    conversation: ConversationEngine,
    turnToolRegistry: ToolRegistry,
    stableInstructions: String,
    lastNativeToolCalls: [ChatRuntimeToolCall] = []
  ) async throws -> ChatToolLoopOutcome {
    let toolProfile = activeToolProfile(
      workspace: workspace,
      sessionID: sessionID,
      interactionMode: interactionMode,
      selectedModel: runtime.selectedModel
    )
    guard toolProfile.allowsToolLoop, let workspace, let sessionID else {
      return .complete
    }

    var currentAssistantMessageID = lastAssistantMessageID
    var currentNativeToolCalls = lastNativeToolCalls
    let toolCallingPolicy = runtime.selectedModel.toolCallingPolicy

    while !currentNativeToolCalls.isEmpty {
      let consumedBatchCount = toolCallBatchCount(
        turnID: turnID,
        session: conversation.chatSession
      )
      guard consumedBatchCount < maxToolLoopIterations else {
        throw ChatGenerationError.emptyModelResponse
      }
      let toolLoopIteration = consumedBatchCount + 1
      let followUpPromptMode = ToolFollowUpPromptPolicy.promptMode(
        for: toolProfile,
        finalReason: toolLoopIteration == maxToolLoopIterations
          ? .toolBatchBudgetExhausted
          : nil
      )
      guard
        let step = try await runtime.toolLoopCoordinator.run(
          ToolLoopRequest(
            workspace: workspace,
            sessionID: sessionID,
            turnID: turnID,
            assistantMessageID: currentAssistantMessageID,
            items: conversation.chatSession.turns.flatMap(\.items),
            focusedFileState: conversation.chatSession.focusedFileState,
            interactionMode: interactionMode,
            toolProfile: toolProfile,
            followUpPromptMode: followUpPromptMode,
            toolLoopIteration: toolLoopIteration,
            toolCallingPolicy: toolCallingPolicy,
            nativeToolCalls: currentNativeToolCalls,
            toolRegistry: turnToolRegistry,
            approvalPolicyProvider: {
              let session = await conversation.chatSession
              guard session.interactionMode == .agent else {
                return .manual
              }
              return session.toolApprovalPolicy
            }
          )
        )
      else {
        return .complete
      }
      currentNativeToolCalls = []
      try Task.checkCancellation()
      guard conversation.isActive(turnID) else {
        return .stop
      }

      conversation.applyWorkflowEvents(step.events)
      conversation.notifySessionDidChange()

      switch step.continuation {
      case .awaitingApproval, .awaitingUserAnswer:
        conversation.finishTurn(turnID)
        conversation.finishGeneratingTurn(contextRefreshMode: .disabled)
        conversation.notifySessionDidChange()
        return .stop
      case .resumeAutomaticApproval(let batchAnchorID):
        return .resumeAutomaticApproval(batchAnchorID: batchAnchorID)
      case .resumeGeneration(let nextAssistantMessageID, let promptMode):
        conversation.setActiveToolPromptMode(promptMode)
        let generationResult = try await streamAssistantReply(
          to: nextAssistantMessageID,
          runtime: runtime,
          conversation: conversation,
          interactionMode: interactionMode,
          toolPromptMode: promptMode,
          turnToolRegistry: turnToolRegistry,
          stableInstructions: stableInstructions,
          turnID: turnID,
          toolLoopIteration: toolLoopIteration
        )
        currentNativeToolCalls = generationResult.nativeToolCalls
        try requireVisibleTextOrToolCall(generationResult)
        guard !promptMode.isFinal else {
          try requireVisibleFinalResponse(generationResult)
          return .complete
        }
        currentAssistantMessageID = nextAssistantMessageID
      case .resumeCorrectionGeneration(let nextAssistantMessageID, let promptMode):
        let effectivePromptMode = ToolFollowUpPromptPolicy.promptMode(
          for: toolProfile,
          default: promptMode,
          finalReason:
            toolCallBatchCount(
              turnID: turnID,
              session: conversation.chatSession
            ) >= maxToolLoopIterations
            ? .toolBatchBudgetExhausted
            : nil
        )
        conversation.setActiveToolPromptMode(effectivePromptMode)
        let generationResult = try await streamAssistantReply(
          to: nextAssistantMessageID,
          runtime: runtime,
          conversation: conversation,
          interactionMode: interactionMode,
          toolPromptMode: effectivePromptMode,
          turnToolRegistry: turnToolRegistry,
          stableInstructions: stableInstructions,
          turnID: turnID,
          toolLoopIteration: toolLoopIteration
        )
        currentNativeToolCalls = generationResult.nativeToolCalls
        try requireVisibleTextOrToolCall(generationResult)
        guard !effectivePromptMode.isFinal else {
          try requireVisibleFinalResponse(generationResult)
          return .complete
        }
        currentAssistantMessageID = nextAssistantMessageID
      case .none, .stopTurn:
        return .complete
      }
    }

    return .complete
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

  @discardableResult
  func applyToolFollowUpNoticeIfNeeded(
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurn.ID,
    conversation: ConversationEngine
  ) -> Bool {
    guard
      let update = toolFollowUpNoticePolicy.update(
        session: conversation.chatSession,
        turnID: turnID,
        promptMode: toolPromptMode
      )
    else {
      return false
    }

    conversation.applyWorkflowEvents([.toolCallUpdated(update.record)])
    conversation.notifySessionDidChange()
    return true
  }
}

extension ChatTurnExecutionCoordinator {
  func systemPrompt(
    session: ChatSession,
    selectedModel: ManagedModel,
    toolLoopCoordinator: ToolLoopCoordinator,
    toolPromptMode: ToolPromptMode,
    turnToolRegistry: ToolRegistry? = nil
  ) -> String {
    let registry =
      turnToolRegistry
      ?? toolRegistry(for: toolPromptMode, toolLoopCoordinator: toolLoopCoordinator)
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
    turnToolRegistry: ToolRegistry
  ) throws -> ChatRuntimePromptPlan {
    let cacheIdentityInstructions = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: stableInstructions,
      registry: turnToolRegistry
    )
    return ChatRuntimePromptPlan(
      stableInstructions: stableInstructions,
      transientInstructions: transientInstructions(
        session: session,
        turnToolRegistry: turnToolRegistry
      ),
      toolContext: runtimeToolContext(
        for: toolPromptMode,
        policy: toolCallingPolicy,
        registry: turnToolRegistry,
        cacheIdentityInstructions: cacheIdentityInstructions
      ),
      cacheIdentityInstructions: cacheIdentityInstructions
    )
  }

  private func runtimeToolContext(
    for toolPromptMode: ToolPromptMode,
    policy: ToolCallingPolicy,
    registry: ToolRegistry,
    cacheIdentityInstructions: String
  ) -> ChatRuntimeToolContext? {
    guard policy.isEnabled else {
      return nil
    }
    switch toolPromptMode {
    case .disabled, .enabled(false), .afterToolResultFinal, .afterChatWebToolResultFinal:
      return nil
    case .chatWeb, .afterChatWebToolResultCanContinue, .afterToolResultCanContinue,
      .enabled(true):
      break
    }
    return ChatRuntimeToolContext(
      registry: registry,
      cacheSystemPrompt: cacheIdentityInstructions
    )
  }

  private func transientInstructions(
    session: ChatSession,
    turnToolRegistry: ToolRegistry
  ) -> [String] {
    var instructions: [String] = []
    if session.interactionMode == .agent,
      turnToolRegistry.definition(for: .todoWrite) != nil,
      let planBlock = TodoPromptRenderer.compactPlanBlock(for: session.todoState)
    {
      instructions.append(
        """
        [Runtime Context]
        \(planBlock)
        """
      )
    }
    return instructions
  }

  private func toolCallBatchCount(
    turnID: ChatTurn.ID,
    session: ChatSession
  ) -> Int {
    session.turns.first(where: { $0.id == turnID })?.toolCallBatchCount ?? 0
  }

  private func toolRegistry(
    for toolPromptMode: ToolPromptMode,
    toolLoopCoordinator: ToolLoopCoordinator
  ) -> ToolRegistry {
    switch toolPromptMode {
    case .chatWeb, .afterChatWebToolResultCanContinue, .afterChatWebToolResultFinal:
      return toolLoopCoordinator.toolRegistry(for: .chatWeb)
    case .enabled(true), .afterToolResultCanContinue, .afterToolResultFinal:
      return toolLoopCoordinator.toolRegistry
    case .disabled, .enabled(false):
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
    interactionMode: WorkspaceInteractionMode? = nil,
    selectedMCPServerIDs: [UUID]? = nil,
    activeMCPToolCount: Int? = nil
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
          interactionMode: interactionMode,
          selectedMCPServerIDs: selectedMCPServerIDs,
          activeMCPToolCount: activeMCPToolCount
        )
      )
    }
  }
}

extension ChatTurnExecutionCoordinator {
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
    guard
      let result = toolFollowUpNoticePolicy.latestFailedRunCommandResult(
        session: session,
        turnID: turnID
      )
    else {
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
}
