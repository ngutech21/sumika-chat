import Foundation

public enum ChatToolLoopLimits {
  public static let defaultMaxToolLoopIterations = 8
}

@MainActor
public final class ChatTurnCoordinator {
  private(set) var activeTurnID: ChatTurn.ID?
  private var activeTask: Task<Void, Never>?
  private let executionCoordinator: ChatTurnExecutionCoordinator
  private let toolTurnResumeCoordinator: ToolTurnResumeCoordinator

  public init(
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    modelContextBuilder: ChatModelContextBuilder = ChatModelContextBuilder(),
    toolPromptPolicy: ToolPromptPolicy = ToolPromptPolicy(),
    toolResumeCoordinator: ToolResumeCoordinator = ToolResumeCoordinator(),
    turnTracer: any TurnTracing = NoopTurnTracer(),
    maxToolLoopIterations: Int = ChatToolLoopLimits.defaultMaxToolLoopIterations
  ) {
    let executionCoordinator = ChatTurnExecutionCoordinator(
      focusedFileReducer: focusedFileReducer,
      modelContextBuilder: modelContextBuilder,
      toolPromptPolicy: toolPromptPolicy,
      turnTracer: turnTracer,
      maxToolLoopIterations: maxToolLoopIterations
    )
    self.executionCoordinator = executionCoordinator
    self.toolTurnResumeCoordinator = ToolTurnResumeCoordinator(
      toolResumeCoordinator: toolResumeCoordinator,
      executionCoordinator: executionCoordinator,
      maxToolLoopIterations: maxToolLoopIterations
    )
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
    runtime: ChatTurnRuntimeContext,
    runtimeContextClearCoordinator: RuntimeContextClearCoordinator,
    callbacks: ChatTurnCallbacks
  ) -> ChatTurn.ID {
    let interactionMode = callbacks.session().interactionMode
    let toolProfile = executionCoordinator.activeToolProfile(
      workspace: workspace,
      sessionID: sessionID,
      interactionMode: interactionMode,
      selectedModel: runtime.selectedModel
    )
    let initialToolPromptMode = executionCoordinator.toolPromptMode(
      for: toolProfile
    )
    let turnID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()

    executionCoordinator.emitUserTurnStartEvents(
      prompt: prompt,
      turnID: turnID,
      userMessageID: userMessageID,
      assistantMessageID: assistantMessageID,
      attachments: attachments,
      workspace: workspace,
      interactionMode: interactionMode,
      callbacks: callbacks
    )
    callbacks.notifySessionDidChange()

    runTurnTask(turnID, callbacks: callbacks) { [weak self] turnID in
      guard let self else {
        return .stop
      }

      try await runtimeContextClearCoordinator.awaitPendingClear()
      callbacks.refreshContextUsage(initialToolPromptMode)
      let generationResult = try await executionCoordinator.streamAssistantReply(
        to: assistantMessageID,
        runtime: runtime,
        callbacks: callbacks,
        isActive: self.isActive,
        interactionMode: interactionMode,
        toolPromptMode: initialToolPromptMode,
        turnID: turnID,
        attachments: attachments
      )
      guard self.isActive(turnID) else {
        return .stop
      }
      if toolProfile.allowsToolLoop {
        let shouldComplete = try await executionCoordinator.runToolLoop(
          workspace: workspace,
          sessionID: sessionID,
          lastAssistantMessageID: assistantMessageID,
          turnID: turnID,
          interactionMode: interactionMode,
          runtime: runtime,
          callbacks: callbacks,
          isActive: self.isActive,
          finishTurn: self.finishTurn,
          lastNativeToolCalls: generationResult.nativeToolCalls
        )
        guard shouldComplete else {
          return .stop
        }
      }
      return .complete
    }

    return turnID
  }

  func approveToolCall(
    _ existingRecord: ToolCallRecord,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    toolOrchestrator: ToolOrchestrator,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) {
    callbacks.emitEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      )
    ])
    callbacks.notifySessionDidChange()

    runTurnTask(turnID, callbacks: callbacks) { [weak self] turnID in
      guard let self else {
        return .stop
      }
      return try await toolTurnResumeCoordinator.approveToolCall(
        existingRecord,
        in: workspace,
        turnID: turnID,
        toolOrchestrator: toolOrchestrator,
        runtime: runtime,
        callbacks: callbacks,
        isActive: self.isActive,
        finishTurn: self.finishTurn
      )
    }
  }

  func answerAskUserToolCall(
    _ existingRecord: ToolCallRecord,
    answer: String,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) {
    runTurnTask(turnID, callbacks: callbacks) { [weak self] turnID in
      guard let self else {
        return .stop
      }
      return try await toolTurnResumeCoordinator.answerAskUserToolCall(
        existingRecord,
        answer: answer,
        in: workspace,
        turnID: turnID,
        runtime: runtime,
        callbacks: callbacks,
        isActive: self.isActive,
        finishTurn: self.finishTurn
      )
    }
  }

  func denyToolCall(
    _ existingRecord: ToolCallRecord,
    message: String,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) {
    runTurnTask(turnID, callbacks: callbacks) { [weak self] turnID in
      guard let self else {
        return .stop
      }
      return try await toolTurnResumeCoordinator.denyToolCall(
        existingRecord,
        message: message,
        turnID: turnID,
        runtime: runtime,
        callbacks: callbacks,
        isActive: self.isActive
      )
    }
  }

  @discardableResult
  func cancelActiveTurn(
    emitEvents: ChatWorkflowEventEmitter,
    turnDidFinish: ChatTurnFinishedHandler,
    notifySessionDidChange: ChatTurnNotifyHandler
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
    executionCoordinator.systemPrompt(
      session: session,
      selectedModel: selectedModel,
      toolLoopCoordinator: toolLoopCoordinator,
      toolPromptMode: toolPromptMode
    )
  }

  func currentToolPromptMode(
    session: ChatSession,
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    selectedModel: ManagedModel
  ) -> ToolPromptMode {
    executionCoordinator.currentToolPromptMode(
      session: session,
      workspace: workspace,
      sessionID: sessionID,
      selectedModel: selectedModel
    )
  }

  private func runTurnTask(
    _ turnID: ChatTurn.ID,
    callbacks: ChatTurnCallbacks,
    operation: @escaping @MainActor @Sendable (ChatTurn.ID) async throws -> ChatTurnTaskOutcome
  ) {
    startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }

      do {
        switch try await operation(turnID) {
        case .complete:
          self.completeTurn(
            turnID,
            emitEvents: callbacks.emitEvents,
            turnDidFinish: callbacks.turnDidFinish,
            notifySessionDidChange: callbacks.notifySessionDidChange
          )
        case .stop:
          return
        case .fail(let cancelsStreaming):
          self.failTurn(
            turnID,
            error: nil,
            cancelsStreaming: cancelsStreaming,
            emitEvents: callbacks.emitEvents,
            setErrorMessage: callbacks.setErrorMessage,
            turnDidFinish: callbacks.turnDidFinish,
            notifySessionDidChange: callbacks.notifySessionDidChange
          )
        }
      } catch is CancellationError {
        self.cancelTurn(
          turnID,
          emitEvents: callbacks.emitEvents,
          turnDidFinish: callbacks.turnDidFinish,
          notifySessionDidChange: callbacks.notifySessionDidChange
        )
      } catch {
        self.failTurn(
          turnID,
          error: error,
          cancelsStreaming: true,
          emitEvents: callbacks.emitEvents,
          setErrorMessage: callbacks.setErrorMessage,
          turnDidFinish: callbacks.turnDidFinish,
          notifySessionDidChange: callbacks.notifySessionDidChange
        )
      }
    }
  }

  private func completeTurn(
    _ turnID: ChatTurn.ID,
    emitEvents: ChatWorkflowEventEmitter,
    turnDidFinish: ChatTurnFinishedHandler,
    notifySessionDidChange: ChatTurnNotifyHandler
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
    emitEvents: ChatWorkflowEventEmitter,
    turnDidFinish: ChatTurnFinishedHandler,
    notifySessionDidChange: ChatTurnNotifyHandler
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
    emitEvents: ChatWorkflowEventEmitter,
    setErrorMessage: ChatTurnErrorMessageHandler,
    turnDidFinish: ChatTurnFinishedHandler,
    notifySessionDidChange: ChatTurnNotifyHandler
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
}
