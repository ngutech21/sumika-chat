import Foundation

@MainActor
public final class ChatTurnCoordinator {
  private(set) var activeTurnID: ChatTurn.ID?
  private var activeTask: Task<Void, Never>?
  private let focusedFileReducer: FocusedFileStateReducer
  private let modelContextBuilder: ChatModelContextBuilder
  private let toolPromptPolicy: ToolPromptPolicy
  private let toolResumeCoordinator: ToolResumeCoordinator
  private let turnTracer: any TurnTracing
  private let maxToolLoopIterations: Int

  typealias SessionProvider = @MainActor @Sendable () -> ChatSession
  typealias EventEmitter = @MainActor @Sendable ([ChatWorkflowEvent]) -> Void
  typealias ActiveToolPromptModeHandler = @MainActor @Sendable (ToolPromptMode?) -> Void
  typealias RuntimeCacheDebugSnapshotHandler =
    @MainActor @Sendable (
      RuntimeCacheDebugSnapshot?
    ) -> Void
  typealias ContextRefreshHandler = @MainActor @Sendable (ToolPromptMode) -> Void
  typealias ErrorMessageHandler = @MainActor @Sendable (String) -> Void
  typealias TurnFinishedHandler = @MainActor @Sendable (ChatTurn.ID, ToolPromptMode) -> Void
  typealias NotifyHandler = @MainActor @Sendable () -> Void

  public init(
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    modelContextBuilder: ChatModelContextBuilder = ChatModelContextBuilder(),
    toolPromptPolicy: ToolPromptPolicy = ToolPromptPolicy(),
    toolResumeCoordinator: ToolResumeCoordinator = ToolResumeCoordinator(),
    turnTracer: any TurnTracing = NoopTurnTracer(),
    maxToolLoopIterations: Int = 6
  ) {
    self.focusedFileReducer = focusedFileReducer
    self.modelContextBuilder = modelContextBuilder
    self.toolPromptPolicy = toolPromptPolicy
    self.toolResumeCoordinator = toolResumeCoordinator
    self.turnTracer = turnTracer
    self.maxToolLoopIterations = maxToolLoopIterations
  }

  deinit {
    activeTask?.cancel()
  }

  @discardableResult
  public func startTurn(
    id turnID: ChatTurn.ID,
    operation: @escaping @MainActor @Sendable (ChatTurn.ID) async -> Void
  ) -> ChatTurn.ID {
    activeTask?.cancel()
    activeTurnID = turnID
    activeTask = Task {
      await operation(turnID)
    }
    return turnID
  }

  public func cancelActiveTurn() -> ChatTurn.ID? {
    guard let activeTurnID else {
      return nil
    }

    activeTask?.cancel()
    activeTask = nil
    self.activeTurnID = nil
    return activeTurnID
  }

  public func finishTurn(_ turnID: ChatTurn.ID) {
    guard activeTurnID == turnID else {
      return
    }

    activeTask = nil
    activeTurnID = nil
  }

  public func isActive(_ turnID: ChatTurn.ID) -> Bool {
    activeTurnID == turnID
  }

  @discardableResult
  func startUserTurn(
    prompt: String,
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    attachments: [ChatAttachment],
    selectedModel: ManagedModel,
    operationID: UUID,
    runtimeContextClearCoordinator: RuntimeContextClearCoordinator,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    toolLoopCoordinator: ToolLoopCoordinator,
    session: @escaping SessionProvider,
    emitEvents: @escaping EventEmitter,
    setActiveToolPromptMode: @escaping ActiveToolPromptModeHandler,
    updateRuntimeCacheDebugSnapshot: @escaping RuntimeCacheDebugSnapshotHandler,
    refreshContextUsage: @escaping ContextRefreshHandler,
    setErrorMessage: @escaping ErrorMessageHandler,
    turnDidFinish: @escaping TurnFinishedHandler,
    notifySessionDidChange: @escaping NotifyHandler
  ) -> ChatTurn.ID {
    let interactionMode = session().interactionMode
    let toolsAvailable = toolsAvailable(
      workspace: workspace,
      sessionID: sessionID,
      interactionMode: interactionMode,
      selectedModel: selectedModel
    )
    let initialToolPromptMode = toolPromptMode(
      for: interactionMode,
      toolsAvailable: toolsAvailable
    )
    let turnID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()

    emitUserTurnStartEvents(
      prompt: prompt,
      turnID: turnID,
      userMessageID: userMessageID,
      assistantMessageID: assistantMessageID,
      attachments: attachments,
      workspace: workspace,
      interactionMode: interactionMode,
      session: session,
      emitEvents: emitEvents
    )
    notifySessionDidChange()

    startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }

      do {
        try await runtimeContextClearCoordinator.awaitPendingClear()
        refreshContextUsage(initialToolPromptMode)
        let generationResult = try await self.streamAssistantReply(
          to: assistantMessageID,
          selectedModel: selectedModel,
          operationID: operationID,
          chatGenerationCoordinator: chatGenerationCoordinator,
          toolLoopCoordinator: toolLoopCoordinator,
          session: session,
          emitEvents: emitEvents,
          setActiveToolPromptMode: setActiveToolPromptMode,
          updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
          refreshContextUsage: refreshContextUsage,
          interactionMode: interactionMode,
          toolPromptMode: initialToolPromptMode,
          turnID: turnID,
          attachments: attachments
        )
        guard self.isActive(turnID) else {
          return
        }
        if toolsAvailable && interactionMode.allowsToolLoop {
          let shouldComplete = try await self.runToolLoop(
            workspace: workspace,
            sessionID: sessionID,
            lastAssistantMessageID: assistantMessageID,
            turnID: turnID,
            interactionMode: interactionMode,
            selectedModel: selectedModel,
            operationID: operationID,
            chatGenerationCoordinator: chatGenerationCoordinator,
            toolLoopCoordinator: toolLoopCoordinator,
            session: session,
            emitEvents: emitEvents,
            setActiveToolPromptMode: setActiveToolPromptMode,
            updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
            refreshContextUsage: refreshContextUsage,
            turnDidFinish: turnDidFinish,
            notifySessionDidChange: notifySessionDidChange,
            lastNativeToolCalls: generationResult.nativeToolCalls
          )
          guard shouldComplete else {
            return
          }
        }
      } catch is CancellationError {
        self.cancelTurn(
          turnID,
          emitEvents: emitEvents,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      } catch {
        self.failTurn(
          turnID,
          error: error,
          cancelsStreaming: true,
          emitEvents: emitEvents,
          setErrorMessage: setErrorMessage,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      }

      self.completeTurn(
        turnID,
        emitEvents: emitEvents,
        turnDidFinish: turnDidFinish,
        notifySessionDidChange: notifySessionDidChange
      )
    }

    return turnID
  }

  func approveToolCall(
    _ existingRecord: ToolCallRecord,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    selectedModel: ManagedModel,
    operationID: UUID,
    toolOrchestrator: ToolOrchestrator,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    toolLoopCoordinator: ToolLoopCoordinator,
    session: @escaping SessionProvider,
    emitEvents: @escaping EventEmitter,
    setActiveToolPromptMode: @escaping ActiveToolPromptModeHandler,
    updateRuntimeCacheDebugSnapshot: @escaping RuntimeCacheDebugSnapshotHandler,
    refreshContextUsage: @escaping ContextRefreshHandler,
    setErrorMessage: @escaping ErrorMessageHandler,
    turnDidFinish: @escaping TurnFinishedHandler,
    notifySessionDidChange: @escaping NotifyHandler
  ) {
    emitEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      )
    ])
    notifySessionDidChange()

    startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }

      do {
        let approvedRecord = await toolOrchestrator.executeApproved(
          request: existingRecord.request,
          workspace: workspace
        )
        guard self.isActive(turnID) else {
          return
        }

        let mergedRecord = self.mergedToolCallRecord(
          existing: existingRecord,
          updated: approvedRecord
        )
        let resumeResult = self.toolResumeCoordinator.approvedToolResult(
          record: mergedRecord,
          focusedFileState: session().focusedFileState,
          turnID: turnID
        )

        guard mergedRecord.status == .completed else {
          emitEvents(resumeResult.events)
          self.failTurn(
            turnID,
            error: nil,
            cancelsStreaming: false,
            emitEvents: emitEvents,
            setErrorMessage: setErrorMessage,
            turnDidFinish: turnDidFinish,
            notifySessionDidChange: notifySessionDidChange
          )
          return
        }

        guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID,
          let promptMode = resumeResult.followUpPromptMode
        else {
          self.failTurn(
            turnID,
            error: nil,
            cancelsStreaming: false,
            emitEvents: emitEvents,
            setErrorMessage: setErrorMessage,
            turnDidFinish: turnDidFinish,
            notifySessionDidChange: notifySessionDidChange
          )
          return
        }

        emitEvents(resumeResult.events)
        notifySessionDidChange()
        self.appendFinalToolFollowUpBoundaryIfNeeded(
          toolPromptMode: promptMode,
          turnID: turnID,
          emitEvents: emitEvents
        )
        let generationResult = try await self.streamAssistantReply(
          to: nextAssistantMessageID,
          selectedModel: selectedModel,
          operationID: operationID,
          chatGenerationCoordinator: chatGenerationCoordinator,
          toolLoopCoordinator: toolLoopCoordinator,
          session: session,
          emitEvents: emitEvents,
          setActiveToolPromptMode: setActiveToolPromptMode,
          updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
          refreshContextUsage: refreshContextUsage,
          interactionMode: session().interactionMode,
          toolPromptMode: promptMode,
          turnID: turnID,
          toolLoopIteration: 1
        )
        if !self.toolResumeCoordinator.isFinalApprovedToolFollowUp(mergedRecord) {
          let shouldComplete = try await self.runToolLoop(
            workspace: workspace,
            sessionID: existingRecord.request.sessionID,
            lastAssistantMessageID: nextAssistantMessageID,
            turnID: turnID,
            interactionMode: session().interactionMode,
            selectedModel: selectedModel,
            operationID: operationID,
            chatGenerationCoordinator: chatGenerationCoordinator,
            toolLoopCoordinator: toolLoopCoordinator,
            session: session,
            emitEvents: emitEvents,
            setActiveToolPromptMode: setActiveToolPromptMode,
            updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
            refreshContextUsage: refreshContextUsage,
            turnDidFinish: turnDidFinish,
            notifySessionDidChange: notifySessionDidChange,
            remainingIterations: self.maxToolLoopIterations - 1,
            lastNativeToolCalls: generationResult.nativeToolCalls
          )
          guard shouldComplete else {
            return
          }
        }
      } catch is CancellationError {
        self.cancelTurn(
          turnID,
          emitEvents: emitEvents,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      } catch {
        self.failTurn(
          turnID,
          error: error,
          cancelsStreaming: true,
          emitEvents: emitEvents,
          setErrorMessage: setErrorMessage,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      }

      self.completeTurn(
        turnID,
        emitEvents: emitEvents,
        turnDidFinish: turnDidFinish,
        notifySessionDidChange: notifySessionDidChange
      )
    }
  }

  func answerAskUserToolCall(
    _ existingRecord: ToolCallRecord,
    answer: String,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    selectedModel: ManagedModel,
    operationID: UUID,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    toolLoopCoordinator: ToolLoopCoordinator,
    session: @escaping SessionProvider,
    emitEvents: @escaping EventEmitter,
    setActiveToolPromptMode: @escaping ActiveToolPromptModeHandler,
    updateRuntimeCacheDebugSnapshot: @escaping RuntimeCacheDebugSnapshotHandler,
    refreshContextUsage: @escaping ContextRefreshHandler,
    setErrorMessage: @escaping ErrorMessageHandler,
    turnDidFinish: @escaping TurnFinishedHandler,
    notifySessionDidChange: @escaping NotifyHandler
  ) {
    let resumeResult = toolResumeCoordinator.answeredAskUserTool(
      record: existingRecord,
      answer: answer,
      turnID: turnID
    )
    guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID,
      let promptMode = resumeResult.followUpPromptMode
    else {
      return
    }

    emitEvents(resumeResult.events)
    refreshContextUsage(promptMode)
    notifySessionDidChange()

    startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }
      do {
        let generationResult = try await self.streamAssistantReply(
          to: nextAssistantMessageID,
          selectedModel: selectedModel,
          operationID: operationID,
          chatGenerationCoordinator: chatGenerationCoordinator,
          toolLoopCoordinator: toolLoopCoordinator,
          session: session,
          emitEvents: emitEvents,
          setActiveToolPromptMode: setActiveToolPromptMode,
          updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
          refreshContextUsage: refreshContextUsage,
          interactionMode: session().interactionMode,
          toolPromptMode: promptMode,
          turnID: turnID,
          toolLoopIteration: 1
        )
        let shouldComplete = try await self.runToolLoop(
          workspace: workspace,
          sessionID: existingRecord.request.sessionID,
          lastAssistantMessageID: nextAssistantMessageID,
          turnID: turnID,
          interactionMode: session().interactionMode,
          selectedModel: selectedModel,
          operationID: operationID,
          chatGenerationCoordinator: chatGenerationCoordinator,
          toolLoopCoordinator: toolLoopCoordinator,
          session: session,
          emitEvents: emitEvents,
          setActiveToolPromptMode: setActiveToolPromptMode,
          updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
          refreshContextUsage: refreshContextUsage,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange,
          remainingIterations: self.maxToolLoopIterations - 1,
          lastNativeToolCalls: generationResult.nativeToolCalls
        )
        guard shouldComplete else {
          return
        }
      } catch is CancellationError {
        self.cancelTurn(
          turnID,
          emitEvents: emitEvents,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      } catch {
        self.failTurn(
          turnID,
          error: error,
          cancelsStreaming: true,
          emitEvents: emitEvents,
          setErrorMessage: setErrorMessage,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      }

      self.completeTurn(
        turnID,
        emitEvents: emitEvents,
        turnDidFinish: turnDidFinish,
        notifySessionDidChange: notifySessionDidChange
      )
    }
  }

  func denyToolCall(
    _ existingRecord: ToolCallRecord,
    message: String,
    turnID: ChatTurn.ID,
    selectedModel: ManagedModel,
    operationID: UUID,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    toolLoopCoordinator: ToolLoopCoordinator,
    session: @escaping SessionProvider,
    emitEvents: @escaping EventEmitter,
    setActiveToolPromptMode: @escaping ActiveToolPromptModeHandler,
    updateRuntimeCacheDebugSnapshot: @escaping RuntimeCacheDebugSnapshotHandler,
    refreshContextUsage: @escaping ContextRefreshHandler,
    setErrorMessage: @escaping ErrorMessageHandler,
    turnDidFinish: @escaping TurnFinishedHandler,
    notifySessionDidChange: @escaping NotifyHandler
  ) {
    let resumeResult = toolResumeCoordinator.deniedTool(
      record: existingRecord,
      message: message,
      turnID: turnID
    )
    guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID,
      let promptMode = resumeResult.followUpPromptMode
    else {
      return
    }

    emitEvents(resumeResult.events)
    appendFinalToolFollowUpBoundaryIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      emitEvents: emitEvents
    )
    refreshContextUsage(promptMode)
    notifySessionDidChange()

    startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }
      do {
        _ = try await self.streamAssistantReply(
          to: nextAssistantMessageID,
          selectedModel: selectedModel,
          operationID: operationID,
          chatGenerationCoordinator: chatGenerationCoordinator,
          toolLoopCoordinator: toolLoopCoordinator,
          session: session,
          emitEvents: emitEvents,
          setActiveToolPromptMode: setActiveToolPromptMode,
          updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
          refreshContextUsage: refreshContextUsage,
          interactionMode: session().interactionMode,
          toolPromptMode: promptMode,
          turnID: turnID,
          toolLoopIteration: 1
        )
      } catch is CancellationError {
        self.cancelTurn(
          turnID,
          emitEvents: emitEvents,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      } catch {
        self.failTurn(
          turnID,
          error: error,
          cancelsStreaming: true,
          emitEvents: emitEvents,
          setErrorMessage: setErrorMessage,
          turnDidFinish: turnDidFinish,
          notifySessionDidChange: notifySessionDidChange
        )
        return
      }

      self.completeTurn(
        turnID,
        emitEvents: emitEvents,
        turnDidFinish: turnDidFinish,
        notifySessionDidChange: notifySessionDidChange
      )
    }
  }

  @discardableResult
  func cancelActiveTurn(
    emitEvents: EventEmitter,
    turnDidFinish: TurnFinishedHandler,
    notifySessionDidChange: NotifyHandler
  ) -> Bool {
    guard let turnID = cancelActiveTurn() else {
      return false
    }

    emitEvents(cancelledTurnEvents(turnID))
    turnDidFinish(turnID, .disabled)
    notifySessionDidChange()
    return true
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
    let toolAvailability = toolPromptPolicy.toolAvailability(
      workspace: workspace,
      sessionID: sessionID
    )
    return toolPromptMode(
      for: session.interactionMode,
      toolsAvailable: toolAvailability == .availableForWorkspace
        && session.interactionMode != .chat
        && selectedModel.supportsWorkspaceTools
    )
  }

  private func emitUserTurnStartEvents(
    prompt: String,
    turnID: ChatTurn.ID,
    userMessageID: UUID,
    assistantMessageID: UUID,
    attachments: [ChatAttachment],
    workspace: Workspace?,
    interactionMode: WorkspaceInteractionMode,
    session: SessionProvider,
    emitEvents: EventEmitter
  ) {
    let focusedEvents = focusEventsForAttachments(
      attachments,
      workspace: workspace,
      focusedFileState: session().focusedFileState
    )
    emitEvents(
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
      focusedFileState: session().focusedFileState,
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
      emitEvents([.modelContextEntryAppended(entry)])
    }
    emitEvents([
      .assistantPlaceholderAppended(
        messageID: assistantMessageID,
        turnID: turnID
      )
    ])
  }

  private func streamAssistantReply(
    to assistantMessageID: UUID,
    selectedModel: ManagedModel,
    operationID: UUID,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    toolLoopCoordinator: ToolLoopCoordinator,
    session: SessionProvider,
    emitEvents: EventEmitter,
    setActiveToolPromptMode: ActiveToolPromptModeHandler,
    updateRuntimeCacheDebugSnapshot: RuntimeCacheDebugSnapshotHandler,
    refreshContextUsage: ContextRefreshHandler,
    interactionMode: WorkspaceInteractionMode,
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurn.ID,
    toolLoopIteration: Int? = nil,
    attachments: [ChatAttachment] = []
  )
    async throws
    -> ChatGenerationResult
  {
    let toolCallingPolicy = selectedModel.toolCallingPolicy
    setActiveToolPromptMode(toolPromptMode)
    let systemPromptStartedAt = Date()
    let renderedSystemPrompt = systemPrompt(
      session: session(),
      selectedModel: selectedModel,
      toolLoopCoordinator: toolLoopCoordinator,
      toolPromptMode: toolPromptMode
    )
    traceTurnPhase(
      .renderSystemPrompt,
      startedAt: systemPromptStartedAt,
      turnID: turnID,
      generationID: nil,
      promptBytes: renderedSystemPrompt.utf8.count,
      messageCount: session().modelContextSnapshot.entries.count,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode
    )
    let contextBuildStartedAt = Date()
    let modelContextSnapshot = modelContextBuilder.transcript(
      from: session(),
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
    let generationResult = try await chatGenerationCoordinator.streamAssistantReplyResult(
      turnID: turnID,
      operationID: operationID,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode,
      transcript: modelContextSnapshot,
      attachments: attachments,
      systemPrompt: renderedSystemPrompt,
      settings: session().generationSettings,
      toolContext: runtimeToolContext(
        for: toolPromptMode,
        policy: toolCallingPolicy,
        session: session(),
        toolLoopCoordinator: toolLoopCoordinator
      ),
      appendChunk: { chunk in
        guard isActive(turnID) else {
          return
        }
        emitEvents([
          .assistantChunkAppended(
            chunk: chunk,
            messageID: assistantMessageID
          )
        ])
      },
      updateGenerationMetrics: { metrics in
        guard isActive(turnID) else {
          return
        }
        emitEvents([
          .assistantGenerationCompleted(
            messageID: assistantMessageID,
            metrics: metrics
          )
        ])
      },
      updateRuntimeCacheDebugSnapshot: { snapshot in
        guard isActive(turnID) else {
          return
        }
        updateRuntimeCacheDebugSnapshot(snapshot)
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
        emitEvents([.modelContextEntryAppended(entry)])
      }
    }
    refreshContextUsage(toolPromptMode)
    return generationResult
  }

  private func runToolLoop(
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    lastAssistantMessageID: UUID,
    turnID: ChatTurn.ID,
    interactionMode: WorkspaceInteractionMode,
    selectedModel: ManagedModel,
    operationID: UUID,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    toolLoopCoordinator: ToolLoopCoordinator,
    session: SessionProvider,
    emitEvents: EventEmitter,
    setActiveToolPromptMode: ActiveToolPromptModeHandler,
    updateRuntimeCacheDebugSnapshot: RuntimeCacheDebugSnapshotHandler,
    refreshContextUsage: ContextRefreshHandler,
    turnDidFinish: TurnFinishedHandler,
    notifySessionDidChange: NotifyHandler,
    remainingIterations initialRemainingIterations: Int? = nil,
    lastNativeToolCalls: [ChatRuntimeToolCall] = []
  ) async throws -> Bool {
    guard interactionMode.allowsToolLoop, let workspace, let sessionID else {
      return true
    }

    var currentAssistantMessageID = lastAssistantMessageID
    var currentNativeToolCalls = lastNativeToolCalls
    var remainingIterations = initialRemainingIterations ?? maxToolLoopIterations
    let toolCallingPolicy = selectedModel.toolCallingPolicy

    while remainingIterations > 0 {
      let toolLoopIteration = (maxToolLoopIterations - remainingIterations) + 1
      let followUpPromptMode: ToolPromptMode =
        followUpPromptMode(for: interactionMode, remainingIterations: remainingIterations)
      guard
        let step = try await toolLoopCoordinator.run(
          ToolLoopRequest(
            workspace: workspace,
            sessionID: sessionID,
            turnID: turnID,
            assistantMessageID: currentAssistantMessageID,
            items: session().turns.flatMap(\.items),
            focusedFileState: session().focusedFileState,
            interactionMode: interactionMode,
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

      emitEvents(step.events)
      notifySessionDidChange()

      switch step.continuation {
      case .awaitingApproval, .awaitingUserAnswer:
        finishTurn(turnID)
        turnDidFinish(turnID, .disabled)
        notifySessionDidChange()
        return false
      case .resumeGeneration(let nextAssistantMessageID, let promptMode):
        setActiveToolPromptMode(promptMode)
        let generationResult = try await streamAssistantReply(
          to: nextAssistantMessageID,
          selectedModel: selectedModel,
          operationID: operationID,
          chatGenerationCoordinator: chatGenerationCoordinator,
          toolLoopCoordinator: toolLoopCoordinator,
          session: session,
          emitEvents: emitEvents,
          setActiveToolPromptMode: setActiveToolPromptMode,
          updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
          refreshContextUsage: refreshContextUsage,
          interactionMode: interactionMode,
          toolPromptMode: promptMode,
          turnID: turnID,
          toolLoopIteration: toolLoopIteration
        )
        currentNativeToolCalls = generationResult.nativeToolCalls
        guard promptMode != .afterToolResultFinal else { return true }
        currentAssistantMessageID = nextAssistantMessageID
      case .none, .stopTurn:
        return true
      }
    }

    return true
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
    case .inspect, .afterInspectToolResultCanContinue, .afterToolResultCanContinue,
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

  private func toolsAvailable(
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    interactionMode: WorkspaceInteractionMode,
    selectedModel: ManagedModel
  ) -> Bool {
    let toolAvailability = toolPromptPolicy.toolAvailability(
      workspace: workspace,
      sessionID: sessionID
    )
    return toolAvailability == .availableForWorkspace
      && interactionMode != .chat
      && selectedModel.supportsWorkspaceTools
  }

  private func toolPromptMode(
    for interactionMode: WorkspaceInteractionMode,
    toolsAvailable: Bool
  ) -> ToolPromptMode {
    guard toolsAvailable else {
      return .disabled
    }

    switch interactionMode {
    case .chat:
      return .disabled
    case .agent:
      return .enabled(true)
    }
  }

  private func followUpPromptMode(
    for interactionMode: WorkspaceInteractionMode,
    remainingIterations: Int
  ) -> ToolPromptMode {
    guard remainingIterations > 1 else {
      return .afterToolResultFinal
    }

    switch interactionMode {
    case .chat:
      return .disabled
    case .agent:
      return .afterToolResultCanContinue
    }
  }

  private func toolRegistry(
    for toolPromptMode: ToolPromptMode,
    toolLoopCoordinator: ToolLoopCoordinator
  ) -> ToolRegistry {
    switch toolPromptMode {
    case .inspect, .afterInspectToolResultCanContinue:
      return ToolExecutorRegistry.readOnly.toolRegistry
    case .enabled(true), .afterToolResultCanContinue:
      return toolLoopCoordinator.toolRegistry
    case .disabled, .enabled(false), .afterToolResultFinal:
      return ToolRegistry(tools: [])
    }
  }

  private func appendFinalToolFollowUpBoundaryIfNeeded(
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurn.ID,
    emitEvents: EventEmitter
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

  private func mergedToolCallRecord(
    existing: ToolCallRecord,
    updated: ToolCallRecord
  ) -> ToolCallRecord {
    var merged = updated
    let appendedEvents = updated.events.filter { newEvent in
      !existing.events.contains { existingEvent in
        existingEvent.actor == newEvent.actor
          && existingEvent.kind == newEvent.kind
          && existingEvent.message == newEvent.message
      }
    }
    merged.events = existing.events + appendedEvents
    return merged
  }

  private func completeTurn(
    _ turnID: ChatTurn.ID,
    emitEvents: EventEmitter,
    turnDidFinish: TurnFinishedHandler,
    notifySessionDidChange: NotifyHandler
  ) {
    guard isActive(turnID) else {
      return
    }

    emitEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .completed,
        modelContextPolicy: nil
      )
    ])
    finishTurn(turnID)
    turnDidFinish(turnID, .disabled)
    notifySessionDidChange()
  }

  private func cancelTurn(
    _ turnID: ChatTurn.ID,
    emitEvents: EventEmitter,
    turnDidFinish: TurnFinishedHandler,
    notifySessionDidChange: NotifyHandler
  ) {
    guard isActive(turnID) else {
      return
    }

    emitEvents(cancelledTurnEvents(turnID))
    finishTurn(turnID)
    turnDidFinish(turnID, .disabled)
    notifySessionDidChange()
  }

  private func failTurn(
    _ turnID: ChatTurn.ID,
    error: Error?,
    cancelsStreaming: Bool,
    emitEvents: EventEmitter,
    setErrorMessage: ErrorMessageHandler,
    turnDidFinish: TurnFinishedHandler,
    notifySessionDidChange: NotifyHandler
  ) {
    guard isActive(turnID) else {
      return
    }

    emitEvents(failedTurnEvents(turnID, cancelsStreaming: cancelsStreaming))
    if let error {
      setErrorMessage(error.localizedDescription)
    }
    finishTurn(turnID)
    turnDidFinish(turnID, .disabled)
    notifySessionDidChange()
  }

  private func cancelledTurnEvents(_ turnID: ChatTurn.ID) -> [ChatWorkflowEvent] {
    [
      .turnStatusChanged(
        turnID: turnID,
        status: .cancelled,
        modelContextPolicy: .excluded
      ),
      .streamingAssistantMessagesCancelled(turnID: turnID),
      .transientAssistantPlaceholdersRemoved,
    ]
  }

  private func failedTurnEvents(
    _ turnID: ChatTurn.ID,
    cancelsStreaming: Bool
  ) -> [ChatWorkflowEvent] {
    var events: [ChatWorkflowEvent] = [
      .turnStatusChanged(
        turnID: turnID,
        status: .failed,
        modelContextPolicy: .excluded
      )
    ]
    if cancelsStreaming {
      events.append(contentsOf: [
        .streamingAssistantMessagesCancelled(turnID: turnID),
        .transientAssistantPlaceholdersRemoved,
      ])
    }
    return events
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

extension WorkspaceInteractionMode {
  fileprivate var allowsToolLoop: Bool {
    switch self {
    case .chat:
      false
    case .agent:
      true
    }
  }
}
