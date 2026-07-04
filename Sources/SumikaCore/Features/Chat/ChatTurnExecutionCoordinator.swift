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
      toolLoopCoordinator: runtime.toolLoopCoordinator
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
    let generationResult = try await runtime.chatGenerationCoordinator.streamAssistantReplyResult(
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
    toolLoopCoordinator: ToolLoopCoordinator
  ) -> ChatRuntimePromptPlan {
    ChatRuntimePromptPlan(
      stableInstructions: stableInstructions,
      transientInstructions: transientInstructions(
        session: session,
        toolPromptMode: toolPromptMode,
        toolLoopCoordinator: toolLoopCoordinator
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
    toolLoopCoordinator: ToolLoopCoordinator
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
