import Foundation

public enum ChatToolLoopLimits {
  public static let defaultMaxToolLoopIterations = 8
}

@MainActor
public final class ChatTurnCoordinator {
  private(set) var activeTurnID: ChatTurn.ID?
  private var activeTask: Task<Void, Never>?
  private var turnToolRegistries: [ChatTurn.ID: ToolRegistry] = [:]
  private let executionCoordinator: ChatTurnExecutionCoordinator
  private let workspaceInstructionsLoader: any WorkspaceInstructionsLoading
  private let toolResumeCoordinator = ToolResumeCoordinator()
  private let maxToolLoopIterations: Int

  public init(
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    modelContextBuilder: ChatModelContextBuilder = ChatModelContextBuilder(),
    toolPromptPolicy: ToolPromptPolicy = ToolPromptPolicy(),
    workspaceInstructionsLoader: any WorkspaceInstructionsLoading = WorkspaceInstructionsLoader(),
    turnTracer: any TurnTracing = NoopTurnTracer(),
    maxToolLoopIterations: Int = ChatToolLoopLimits.defaultMaxToolLoopIterations
  ) {
    self.executionCoordinator = ChatTurnExecutionCoordinator(
      focusedFileReducer: focusedFileReducer,
      modelContextBuilder: modelContextBuilder,
      toolPromptPolicy: toolPromptPolicy,
      turnTracer: turnTracer,
      maxToolLoopIterations: maxToolLoopIterations
    )
    self.workspaceInstructionsLoader = workspaceInstructionsLoader
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
    turnToolRegistries[activeTurnID] = nil
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
    let turnToolRegistry = runtime.toolLoopCoordinator.toolRegistry(for: toolProfile)
    turnToolRegistries[turnID] = turnToolRegistry
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
    let stableInstructions = executionCoordinator.systemPrompt(
      session: callbacks.session(),
      selectedModel: runtime.selectedModel,
      toolLoopCoordinator: runtime.toolLoopCoordinator,
      toolPromptMode: initialToolPromptMode,
      turnToolRegistry: turnToolRegistry
    )
    callbacks.notifySessionDidChange()

    runTurnTask(turnID, callbacks: callbacks) { [weak self] turnID in
      guard let self else {
        return .stop
      }

      try await runtimeContextClearCoordinator.awaitPendingClear()
      if toolProfile == .agent, let workspace {
        let loadResult = try await workspaceInstructionsLoader.loadInstructions(from: workspace)
        guard self.isActive(turnID) else {
          return .stop
        }
        if let update = WorkspaceInstructionsPromptPolicy.update(
          for: loadResult,
          in: callbacks.session()
        ),
          let currentPromptContext = self.promptContext(
            for: userMessageID,
            in: callbacks.session()
          )
        {
          callbacks.emitEvents([
            .userMessagePromptContextUpdated(
              messageID: userMessageID,
              promptContext: currentPromptContext.appendingWorkspaceInstructions(update)
            )
          ])
          callbacks.notifySessionDidChange()
        }
      }
      callbacks.refreshContextUsage(initialToolPromptMode)
      let generationResult = try await executionCoordinator.streamAssistantReply(
        to: assistantMessageID,
        runtime: runtime,
        callbacks: callbacks,
        isActive: self.isActive,
        interactionMode: interactionMode,
        toolPromptMode: initialToolPromptMode,
        turnToolRegistry: turnToolRegistry,
        stableInstructions: stableInstructions,
        turnID: turnID,
        attachments: attachments
      )
      guard self.isActive(turnID) else {
        return .stop
      }
      if toolProfile.allowsToolLoop {
        try executionCoordinator.requireVisibleTextOrToolCall(generationResult)
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
          turnToolRegistry: turnToolRegistry,
          stableInstructions: stableInstructions,
          lastNativeToolCalls: generationResult.nativeToolCalls
        )
        guard shouldComplete else {
          return .stop
        }
      } else {
        try executionCoordinator.requireVisibleFinalResponse(generationResult)
      }
      return .complete
    }

    return turnID
  }

  private func promptContext(
    for messageID: UUID,
    in session: ChatSession
  ) -> CurrentPromptContext? {
    for turn in session.turns {
      for item in turn.items {
        guard case .userMessage(let message) = item, message.id == messageID else {
          continue
        }
        return message.promptContext
      }
    }
    return nil
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
      return try await self.resumeApprovedToolCalls(
        [existingRecord],
        batchAnchorID: existingRecord.id,
        in: workspace,
        turnID: turnID,
        toolOrchestrator: toolOrchestrator,
        runtime: runtime,
        callbacks: callbacks
      )
    }
  }

  func approveToolCallBatch(
    _ existingRecords: [ToolCallRecord],
    batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    toolOrchestrator: ToolOrchestrator,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) {
    guard !existingRecords.isEmpty else {
      return
    }
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
      return try await self.resumeApprovedToolCalls(
        existingRecords,
        batchAnchorID: batchAnchorID,
        in: workspace,
        turnID: turnID,
        toolOrchestrator: toolOrchestrator,
        runtime: runtime,
        callbacks: callbacks
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
      return try await self.resumeAnsweredAskUserToolCall(
        existingRecord,
        answer: answer,
        in: workspace,
        turnID: turnID,
        runtime: runtime,
        callbacks: callbacks
      )
    }
  }

  func denyToolCall(
    _ existingRecord: ToolCallRecord,
    turnID: ChatTurn.ID,
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
      return try await self.resumeDeniedToolCall(
        existingRecord,
        turnID: turnID,
        runtime: runtime,
        callbacks: callbacks
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
        case .pause(let status):
          self.pauseTurn(
            turnID,
            status: status,
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
    turnToolRegistries[turnID] = nil
    finishTurn(turnID)
    turnDidFinish(turnID, .disabled)
    notifySessionDidChange()
  }

  private func pauseTurn(
    _ turnID: ChatTurn.ID,
    status: ChatTurnStatus,
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
        status: status,
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
    turnToolRegistries[turnID] = nil
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
    turnToolRegistries[turnID] = nil
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

// Approval and denial first update their existing records, then cross the
// derived batch barrier together. ask_user intentionally keeps its dedicated
// single-call answer/resume path.
extension ChatTurnCoordinator {
  private func resumeApprovedToolCalls(
    _ existingRecords: [ToolCallRecord],
    batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    toolOrchestrator: ToolOrchestrator,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) async throws -> ChatTurnTaskOutcome {
    for requestedRecord in existingRecords {
      try Task.checkCancellation()
      guard isActive(turnID) else {
        return .stop
      }
      guard
        let liveRecord = callbacks.session().toolCallRecord(id: requestedRecord.id),
        liveRecord.status == .awaitingApproval
      else {
        continue
      }

      let approvedRecord = await toolOrchestrator.executeApproved(
        request: liveRecord.request,
        approvedEvaluation: liveRecord.evaluation,
        workspace: workspace
      )
      guard isActive(turnID) else {
        return .stop
      }
      if approvedRecord.status == .awaitingApproval {
        callbacks.emitEvents([.toolCallUpdated(approvedRecord)])
        callbacks.notifySessionDidChange()
        continue
      }
      let resumeResult = toolResumeCoordinator.approvedToolResult(
        record: approvedRecord,
        focusedFileState: callbacks.session().focusedFileState,
        turnID: turnID
      )
      callbacks.emitEvents(resumeResult.events)
      callbacks.notifySessionDidChange()
    }

    return try await continueAfterResolvedToolBatch(
      containing: batchAnchorID,
      in: workspace,
      turnID: turnID,
      runtime: runtime,
      callbacks: callbacks
    )
  }

  private func resumeAnsweredAskUserToolCall(
    _ existingRecord: ToolCallRecord,
    answer: String,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) async throws -> ChatTurnTaskOutcome {
    let resumeResult = toolResumeCoordinator.answeredAskUserTool(
      record: existingRecord,
      answer: answer,
      turnID: turnID
    )
    guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID else {
      return .stop
    }

    callbacks.emitEvents(resumeResult.events)
    let toolProfile = executionCoordinator.activeToolProfile(
      workspace: workspace,
      sessionID: existingRecord.request.sessionID,
      interactionMode: callbacks.session().interactionMode,
      selectedModel: runtime.selectedModel
    )
    guard let turn = callbacks.session().turns.first(where: { $0.id == turnID }) else {
      return .fail(cancelsStreaming: false)
    }
    let finalReason: ToolFollowUpFinalReason? =
      turn.toolCallBatchCount >= maxToolLoopIterations
      ? .toolBatchBudgetExhausted
      : nil
    let promptMode = ToolFollowUpPromptPolicy.promptMode(
      for: toolProfile,
      default: resumeResult.followUpPromptMode,
      finalReason: finalReason
    )
    executionCoordinator.applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      callbacks: callbacks
    )
    callbacks.refreshContextUsage(promptMode)
    callbacks.notifySessionDidChange()

    let turnToolRegistry = frozenToolRegistry(
      for: turnID,
      toolProfile: toolProfile,
      runtime: runtime
    )
    let stableInstructions = stableInstructions(
      toolProfile: toolProfile,
      turnToolRegistry: turnToolRegistry,
      runtime: runtime,
      callbacks: callbacks
    )
    let generationResult = try await executionCoordinator.streamAssistantReply(
      to: nextAssistantMessageID,
      runtime: runtime,
      callbacks: callbacks,
      isActive: self.isActive,
      interactionMode: callbacks.session().interactionMode,
      toolPromptMode: promptMode,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: turn.toolCallBatchCount
    )
    if promptMode.isFinal {
      try executionCoordinator.requireVisibleFinalResponse(generationResult)
      return .complete
    }
    try executionCoordinator.requireVisibleTextOrToolCall(generationResult)
    let shouldComplete = try await executionCoordinator.runToolLoop(
      workspace: workspace,
      sessionID: existingRecord.request.sessionID,
      lastAssistantMessageID: nextAssistantMessageID,
      turnID: turnID,
      interactionMode: callbacks.session().interactionMode,
      runtime: runtime,
      callbacks: callbacks,
      isActive: self.isActive,
      finishTurn: self.finishTurn,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      lastNativeToolCalls: generationResult.nativeToolCalls
    )
    return shouldComplete ? .complete : .stop
  }

  private func resumeDeniedToolCall(
    _ existingRecord: ToolCallRecord,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) async throws -> ChatTurnTaskOutcome {
    let resumeResult = toolResumeCoordinator.deniedTool(
      record: existingRecord,
      turnID: turnID
    )
    callbacks.emitEvents(resumeResult.events)
    callbacks.notifySessionDidChange()

    return try await continueAfterResolvedToolBatch(
      containing: existingRecord.id,
      in: nil,
      turnID: turnID,
      runtime: runtime,
      callbacks: callbacks
    )
  }

  private func continueAfterResolvedToolBatch(
    containing toolCallID: ToolCallRecord.ID,
    in workspace: Workspace?,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) async throws -> ChatTurnTaskOutcome {
    guard let turn = callbacks.session().turns.first(where: { $0.id == turnID }),
      let batch = turn.toolCallBatch(containing: toolCallID)
    else {
      return .fail(cancelsStreaming: false)
    }

    if !batch.pendingApprovalRecords.isEmpty {
      return .pause(.awaitingApproval)
    }
    if batch.hasPendingUserAnswer {
      return .pause(.awaitingUserAnswer)
    }
    guard batch.isModelReady, let firstRecord = batch.records.first else {
      return .fail(cancelsStreaming: false)
    }

    let toolProfile = resolvedToolProfile(
      workspace: workspace,
      sessionID: firstRecord.request.sessionID,
      runtime: runtime,
      callbacks: callbacks
    )
    let promptMode = ToolFollowUpPromptPolicy.promptMode(
      for: toolProfile,
      finalReason: finalReason(batch, in: turn)
    )
    let nextAssistantMessageID = UUID()
    callbacks.emitEvents([
      .assistantPlaceholderAppended(
        messageID: nextAssistantMessageID,
        turnID: turnID
      ),
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      ),
    ])
    executionCoordinator.applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      callbacks: callbacks
    )
    callbacks.refreshContextUsage(promptMode)
    callbacks.notifySessionDidChange()

    let turnToolRegistry = frozenToolRegistry(
      for: turnID,
      toolProfile: toolProfile,
      runtime: runtime
    )
    let stableInstructions = stableInstructions(
      toolProfile: toolProfile,
      turnToolRegistry: turnToolRegistry,
      runtime: runtime,
      callbacks: callbacks
    )
    let generationResult = try await executionCoordinator.streamAssistantReply(
      to: nextAssistantMessageID,
      runtime: runtime,
      callbacks: callbacks,
      isActive: self.isActive,
      interactionMode: callbacks.session().interactionMode,
      toolPromptMode: promptMode,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: turn.toolCallBatchCount
    )
    if promptMode.isFinal {
      try executionCoordinator.requireVisibleFinalResponse(generationResult)
      return .complete
    }

    guard let workspace else {
      return .fail(cancelsStreaming: false)
    }
    try executionCoordinator.requireVisibleTextOrToolCall(generationResult)
    let shouldComplete = try await executionCoordinator.runToolLoop(
      workspace: workspace,
      sessionID: firstRecord.request.sessionID,
      lastAssistantMessageID: nextAssistantMessageID,
      turnID: turnID,
      interactionMode: callbacks.session().interactionMode,
      runtime: runtime,
      callbacks: callbacks,
      isActive: self.isActive,
      finishTurn: self.finishTurn,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      lastNativeToolCalls: generationResult.nativeToolCalls
    )
    return shouldComplete ? .complete : .stop
  }

  private func resolvedToolProfile(
    workspace: Workspace?,
    sessionID: ChatSession.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) -> ToolExecutionProfile {
    if let workspace {
      return executionCoordinator.activeToolProfile(
        workspace: workspace,
        sessionID: sessionID,
        interactionMode: callbacks.session().interactionMode,
        selectedModel: runtime.selectedModel
      )
    }
    return callbacks.session().interactionMode == .chat ? .chatWeb : .agent
  }

  private func finalReason(
    _ batch: ToolCallBatch,
    in turn: ChatTurn
  ) -> ToolFollowUpFinalReason? {
    if batch.records.contains(where: { $0.status == .denied }) {
      return .denial
    }
    if batch.records.contains(where: isBlockedDuplicate(_:)) {
      return .blockedDuplicate
    }

    let batchIDs = Set(batch.records.map(\.id))
    var priorItems: [ChatTurnItem] = []
    for item in turn.items {
      guard case .tool(let record) = item, batchIDs.contains(record.id) else {
        priorItems.append(item)
        continue
      }
      if RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(
        record,
        priorItems: priorItems
      ) {
        return .repeatedRunCommandFailure
      }
      priorItems.append(item)
    }
    if turn.toolCallBatchCount >= maxToolLoopIterations {
      return .toolBatchBudgetExhausted
    }
    return nil
  }

  private func isBlockedDuplicate(_ record: ToolCallRecord) -> Bool {
    guard case .duplicateToolCall(let result)? = record.resultPayload else {
      return false
    }
    return result.blocked
  }

  private func stableInstructions(
    toolProfile: ToolExecutionProfile,
    turnToolRegistry: ToolRegistry,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) -> String {
    executionCoordinator.systemPrompt(
      session: callbacks.session(),
      selectedModel: runtime.selectedModel,
      toolLoopCoordinator: runtime.toolLoopCoordinator,
      toolPromptMode: executionCoordinator.toolPromptMode(for: toolProfile),
      turnToolRegistry: turnToolRegistry
    )
  }

  private func frozenToolRegistry(
    for turnID: ChatTurn.ID,
    toolProfile: ToolExecutionProfile,
    runtime: ChatTurnRuntimeContext
  ) -> ToolRegistry {
    if let registry = turnToolRegistries[turnID] {
      return registry
    }
    let registry = runtime.toolLoopCoordinator.toolRegistry(for: toolProfile)
    turnToolRegistries[turnID] = registry
    return registry
  }
}
