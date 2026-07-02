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
  private static let toolLimitFinalizationPrompt = """
    Tool limit reached. Tools are no longer available.
    Do not call tools. Briefly summarize what you completed, what changed,
    what remains unfinished, and the next recommended step.
    """

  private static let toolLimitFallbackMessage =
    "Tool limit reached. I stopped tool use for this turn. Some work may be unfinished; "
    + "send another message to continue from the recorded tool results."

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
    maxToolLoopIterations: Int = 6
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
          attachments: attachments
        ),
      ])

    let currentPromptContext = modelContextBuilder.currentPromptContext(
      userInput: prompt,
      mode: interactionMode,
      focusedFileState: session.focusedFileState,
      attachments: attachments,
      workspace: workspace
    )
    if let entry = try? ModelFacingPromptRenderer.userPromptEntry(
      turnID: turnID,
      sourceMessageID: userMessageID,
      prompt: prompt,
      attachments: attachments,
      systemContext: currentPromptContext.renderedBlocks,
      currentPromptContext: currentPromptContext.consumedContext
    ) {
      callbacks.emitEvents([.modelContextEntryAppended(entry)])
    }
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
    let renderedSystemPrompt = systemPrompt(
      session: callbacks.session(),
      selectedModel: runtime.selectedModel,
      toolLoopCoordinator: runtime.toolLoopCoordinator,
      toolPromptMode: toolPromptMode
    )
    traceTurnPhase(
      .renderSystemPrompt,
      startedAt: systemPromptStartedAt,
      turnID: turnID,
      generationID: nil,
      promptBytes: renderedSystemPrompt.utf8.count,
      messageCount: callbacks.session().modelContextSnapshot.entries.count,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode
    )
    let contextBuildStartedAt = Date()
    let modelContextSnapshot = modelContextBuilder.transcript(
      from: callbacks.session(),
      includingTurnID: turnID
    )
    traceTurnPhase(
      .contextBuild,
      startedAt: contextBuildStartedAt,
      turnID: turnID,
      generationID: nil,
      messageCount: modelContextSnapshot.entries.count,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode
    )
    let generationResult = try await runtime.chatGenerationCoordinator.streamAssistantReplyResult(
      turnID: turnID,
      operationID: runtime.operationID,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode,
      transcript: modelContextSnapshot,
      attachments: attachments,
      systemPrompt: renderedSystemPrompt,
      settings: callbacks.session().generationSettings,
      toolContext: runtimeToolContext(
        for: toolPromptMode,
        policy: toolCallingPolicy,
        session: callbacks.session(),
        toolLoopCoordinator: runtime.toolLoopCoordinator
      ),
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
    if !generationResult.assistantContent.isEmpty {
      if let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: assistantMessageID,
        content: generationResult.assistantContent
      ) {
        callbacks.emitEvents([.modelContextEntryAppended(entry)])
      }
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
          turnID: turnID,
          toolLoopIteration: toolLoopIteration
        )
        currentNativeToolCalls = generationResult.nativeToolCalls
        guard promptMode != .afterToolResultFinal else {
          if !hasVisibleAssistantContent(generationResult) {
            try await streamToolLimitFinalization(
              runtime: runtime,
              callbacks: callbacks,
              isActive: isActive,
              interactionMode: interactionMode,
              turnID: turnID
            )
          }
          return true
        }
        currentAssistantMessageID = nextAssistantMessageID
      case .none, .stopTurn:
        return true
      }
    }

    try await streamToolLimitFinalization(
      runtime: runtime,
      callbacks: callbacks,
      isActive: isActive,
      interactionMode: interactionMode,
      turnID: turnID
    )
    return true
  }

  private func streamToolLimitFinalization(
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks,
    isActive: ChatTurnActiveChecker,
    interactionMode: WorkspaceInteractionMode,
    turnID: ChatTurn.ID
  ) async throws {
    guard isActive(turnID) else {
      return
    }

    let assistantMessageID = UUID()
    callbacks.emitEvents([
      .assistantPlaceholderAppended(messageID: assistantMessageID, turnID: turnID)
    ])
    if let entry = try? ModelFacingPromptRenderer.userPromptEntry(
      turnID: turnID,
      prompt: Self.toolLimitFinalizationPrompt
    ) {
      callbacks.emitEvents([.modelContextEntryAppended(entry)])
    }
    callbacks.notifySessionDidChange()

    let generationResult = try await streamAssistantReply(
      to: assistantMessageID,
      runtime: runtime,
      callbacks: callbacks,
      isActive: isActive,
      interactionMode: interactionMode,
      toolPromptMode: .disabled,
      turnID: turnID
    )

    guard isActive(turnID), !hasVisibleAssistantContent(generationResult) else {
      return
    }

    callbacks.emitEvents([
      .assistantChunkAppended(
        chunk: Self.toolLimitFallbackMessage,
        messageID: assistantMessageID
      )
    ])
    if let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
      turnID: turnID,
      sourceMessageID: assistantMessageID,
      content: Self.toolLimitFallbackMessage
    ) {
      callbacks.emitEvents([.modelContextEntryAppended(entry)])
    }
    callbacks.notifySessionDidChange()
  }

  private func hasVisibleAssistantContent(_ generationResult: ChatGenerationResult) -> Bool {
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
    guard toolPromptMode == .afterToolResultFinal else {
      return
    }

    emitEvents([
      .finalToolResultFollowUpBoundaryAppended(
        content: "Use the preceding tool result to answer the user's request.",
        turnID: turnID
      )
    ])
  }

  func systemPrompt(
    session: ChatSession,
    selectedModel: ManagedModel,
    toolLoopCoordinator: ToolLoopCoordinator,
    toolPromptMode: ToolPromptMode
  ) -> String {
    let registry = toolRegistry(for: toolPromptMode, toolLoopCoordinator: toolLoopCoordinator)
    let renderedPrompt = toolPromptPolicy.systemPrompt(
      basePrompt: session.systemPrompt,
      mode: toolPromptMode,
      toolRegistry: registry,
      toolCallingPolicy: selectedModel.toolCallingPolicy
    )
    guard session.interactionMode == .agent,
      registry.definition(for: .todoWrite) != nil,
      let planBlock = TodoPromptRenderer.compactPlanBlock(for: session.todoState)
    else {
      return renderedPrompt
    }
    return [renderedPrompt, planBlock].joined(separator: "\n\n")
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

  private func runtimeToolContext(
    for toolPromptMode: ToolPromptMode,
    policy: ToolCallingPolicy,
    session: ChatSession,
    toolLoopCoordinator: ToolLoopCoordinator
  ) -> ChatRuntimeToolContext? {
    guard policy.strategy == .nativeGemma4 else {
      return nil
    }
    switch toolPromptMode {
    case .disabled, .enabled(false):
      return nil
    case .chatWeb, .afterChatWebToolResultCanContinue, .afterToolResultCanContinue,
      .afterToolResultFinal, .enabled(true):
      break
    }
    let registry = toolRegistry(for: toolPromptMode, toolLoopCoordinator: toolLoopCoordinator)
    return ChatRuntimeToolContext(
      strategy: policy.strategy,
      registry: registry,
      cacheSystemPrompt: session.systemPrompt
    )
  }

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
