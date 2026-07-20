import Foundation

enum ChatToolLoopLimits {
  static let defaultMaxToolLoopIterations = 8
}

// Turn execution stays in the canonical live-session owner so cancellation,
// transcript application, and finalization cannot drift apart.
@MainActor
extension ChatSessionController {
  @discardableResult
  func startTurn(
    id turnID: ChatTurn.ID,
    operation: @escaping @MainActor @Sendable (ChatTurn.ID) async -> Void
  ) -> ChatTurn.ID {
    activeTurnTask?.cancel()
    activeTurnID = turnID
    activeTurnTask = Task {
      await operation(turnID)
    }
    return turnID
  }

  private func takeActiveTurnForCancellation() -> ChatTurn.ID? {
    guard let activeTurnID else {
      return nil
    }

    activeTurnTask?.cancel()
    activeTurnTask = nil
    self.activeTurnID = nil
    turnToolRegistries[activeTurnID] = nil
    return activeTurnID
  }

  func finishTurn(_ turnID: ChatTurn.ID) {
    guard activeTurnID == turnID else {
      return
    }

    activeTurnTask = nil
    activeTurnID = nil
  }

  func isActive(_ turnID: ChatTurn.ID) -> Bool {
    activeTurnID == turnID
  }

  @discardableResult
  func startUserTurn(
    prompt: String,
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    attachments: [ChatAttachment],
    runtime: ChatTurnRuntimeContext,
    runtimeContextClearCoordinator: RuntimeContextClearCoordinator
  ) -> ChatTurn.ID {
    let interactionMode = chatSession.interactionMode
    let toolProfile = turnExecutionCoordinator.activeToolProfile(
      workspace: workspace,
      sessionID: sessionID,
      interactionMode: interactionMode,
      selectedModel: runtime.selectedModel
    )
    let initialToolPromptMode = turnExecutionCoordinator.toolPromptMode(
      for: toolProfile
    )
    let turnID = UUID()
    let turnToolRegistry = runtime.toolLoopCoordinator.toolRegistry(for: toolProfile)
    turnToolRegistries[turnID] = turnToolRegistry
    let userMessageID = UUID()
    let assistantMessageID = UUID()

    turnExecutionCoordinator.emitUserTurnStartEvents(
      prompt: prompt,
      turnID: turnID,
      userMessageID: userMessageID,
      assistantMessageID: assistantMessageID,
      attachments: attachments,
      workspace: workspace,
      interactionMode: interactionMode,
      conversation: self
    )
    let stableInstructions = turnExecutionCoordinator.systemPrompt(
      session: chatSession,
      selectedModel: runtime.selectedModel,
      toolLoopCoordinator: runtime.toolLoopCoordinator,
      toolPromptMode: initialToolPromptMode,
      turnToolRegistry: turnToolRegistry
    )
    notifySessionDidChange()

    runTurnTask(turnID) { [weak self] turnID in
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
          in: chatSession
        ),
          let currentPromptContext = self.promptContext(
            for: userMessageID,
            in: chatSession
          )
        {
          self.applyWorkflowEvents([
            .userMessagePromptContextUpdated(
              messageID: userMessageID,
              promptContext: currentPromptContext.appendingWorkspaceInstructions(update)
            )
          ])
          self.notifySessionDidChange()
        }
      }
      self.refreshContextUsage(toolPromptMode: initialToolPromptMode)
      let generationResult = try await turnExecutionCoordinator.streamAssistantReply(
        to: assistantMessageID,
        runtime: runtime,
        conversation: self,
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
        try turnExecutionCoordinator.requireVisibleTextOrToolCall(generationResult)
        let toolLoopOutcome = try await turnExecutionCoordinator.runToolLoop(
          workspace: workspace,
          sessionID: sessionID,
          lastAssistantMessageID: assistantMessageID,
          turnID: turnID,
          interactionMode: interactionMode,
          runtime: runtime,
          conversation: self,
          turnToolRegistry: turnToolRegistry,
          stableInstructions: stableInstructions,
          lastNativeToolCalls: generationResult.nativeToolCalls
        )
        return try await self.resolveToolLoopOutcome(
          toolLoopOutcome,
          in: workspace,
          turnID: turnID,
          runtime: runtime
        )
      }
      try turnExecutionCoordinator.requireVisibleFinalResponse(generationResult)
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
    approvalSource: ToolApprovalSource = .manual,
    runtime: ChatTurnRuntimeContext
  ) {
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      )
    ])
    notifySessionDidChange()

    runTurnTask(turnID) { [weak self] turnID in
      guard let self else {
        return .stop
      }
      return try await self.resumeApprovedToolCalls(
        [existingRecord],
        batchAnchorID: existingRecord.id,
        in: workspace,
        turnID: turnID,
        toolOrchestrator: toolOrchestrator,
        approvalSource: approvalSource,
        runtime: runtime
      )
    }
  }

  func approveToolCallBatch(
    _ existingRecords: [ToolCallRecord],
    batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    toolOrchestrator: ToolOrchestrator,
    approvalSource: ToolApprovalSource = .manual,
    runtime: ChatTurnRuntimeContext
  ) {
    guard !existingRecords.isEmpty else {
      return
    }
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      )
    ])
    notifySessionDidChange()

    runTurnTask(turnID) { [weak self] turnID in
      guard let self else {
        return .stop
      }
      return try await self.resumeApprovedToolCalls(
        existingRecords,
        batchAnchorID: batchAnchorID,
        in: workspace,
        turnID: turnID,
        toolOrchestrator: toolOrchestrator,
        approvalSource: approvalSource,
        runtime: runtime
      )
    }
  }

  func answerAskUserToolCall(
    _ existingRecord: ToolCallRecord,
    answer: String,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext
  ) {
    runTurnTask(turnID) { [weak self] turnID in
      guard let self else {
        return .stop
      }
      return try await self.resumeAnsweredAskUserToolCall(
        existingRecord,
        answer: answer,
        in: workspace,
        turnID: turnID,
        runtime: runtime
      )
    }
  }

  func denyToolCall(
    _ existingRecord: ToolCallRecord,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext
  ) {
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      )
    ])
    notifySessionDidChange()

    runTurnTask(turnID) { [weak self] turnID in
      guard let self else {
        return .stop
      }
      return try await self.resumeDeniedToolCall(
        existingRecord,
        turnID: turnID,
        runtime: runtime
      )
    }
  }

  @discardableResult
  func cancelActiveTurn() -> Bool {
    guard let turnID = takeActiveTurnForCancellation() else {
      return false
    }

    applyWorkflowEvents(cancelledTurnEvents(turnID))
    finishGeneratingTurn(contextRefreshMode: .disabled)
    return true
  }

  private func runTurnTask(
    _ turnID: ChatTurn.ID,
    operation: @escaping @MainActor @Sendable (ChatTurn.ID) async throws -> ChatTurnTaskOutcome
  ) {
    startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }

      do {
        switch try await operation(turnID) {
        case .complete:
          self.completeTurn(turnID)
        case .pause(let status):
          self.pauseTurn(turnID, status: status)
        case .stop:
          return
        case .fail(let cancelsStreaming):
          self.failTurn(turnID, error: nil, cancelsStreaming: cancelsStreaming)
        }
      } catch is CancellationError {
        self.cancelTurn(turnID)
      } catch {
        self.failTurn(turnID, error: error, cancelsStreaming: true)
      }
    }
  }

  private func completeTurn(_ turnID: ChatTurn.ID) {
    guard isActive(turnID) else {
      return
    }

    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .completed,
        modelContextPolicy: nil
      )
    ])
    turnToolRegistries[turnID] = nil
    finishTurn(turnID)
    finishGeneratingTurn(contextRefreshMode: .disabled)
    notifySessionDidChange()
  }

  private func pauseTurn(
    _ turnID: ChatTurn.ID,
    status: ChatTurnStatus
  ) {
    guard isActive(turnID) else {
      return
    }

    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: status,
        modelContextPolicy: nil
      )
    ])
    finishTurn(turnID)
    finishGeneratingTurn(contextRefreshMode: .disabled)
    notifySessionDidChange()
  }

  private func cancelTurn(_ turnID: ChatTurn.ID) {
    guard isActive(turnID) else {
      return
    }

    applyWorkflowEvents(cancelledTurnEvents(turnID))
    turnToolRegistries[turnID] = nil
    finishTurn(turnID)
    finishGeneratingTurn(contextRefreshMode: .disabled)
    notifySessionDidChange()
  }

  private func failTurn(
    _ turnID: ChatTurn.ID,
    error: Error?,
    cancelsStreaming: Bool
  ) {
    guard isActive(turnID) else {
      return
    }

    applyWorkflowEvents(failedTurnEvents(turnID, cancelsStreaming: cancelsStreaming))
    if let error {
      setConversationErrorMessage(error.localizedDescription)
    }
    turnToolRegistries[turnID] = nil
    finishTurn(turnID)
    finishGeneratingTurn(contextRefreshMode: .disabled)
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
extension ChatSessionController {
  private func resolveToolLoopOutcome(
    _ outcome: ChatToolLoopOutcome,
    in workspace: Workspace?,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext
  ) async throws -> ChatTurnTaskOutcome {
    switch outcome {
    case .complete:
      return .complete
    case .stop:
      return .stop
    case .resumeAutomaticApproval(let batchAnchorID):
      guard isActive(turnID) else {
        return .stop
      }
      guard let workspace else {
        return .fail(cancelsStreaming: false)
      }
      let session = chatSession
      guard session.interactionMode == .agent,
        session.toolApprovalPolicy == .automatic
      else {
        return .pause(.awaitingApproval)
      }
      guard let turn = session.turns.first(where: { $0.id == turnID }),
        let batch = turn.toolCallBatch(containing: batchAnchorID),
        batch.anchorID == batchAnchorID,
        !batch.pendingApprovalRecords.isEmpty
      else {
        return .fail(cancelsStreaming: false)
      }

      applyWorkflowEvents([
        .turnStatusChanged(
          turnID: turnID,
          status: .running,
          modelContextPolicy: nil
        )
      ])
      notifySessionDidChange()
      return try await resumeApprovedToolCalls(
        batch.pendingApprovalRecords,
        batchAnchorID: batch.anchorID,
        in: workspace,
        turnID: turnID,
        toolOrchestrator: runtime.agentToolOrchestrator,
        approvalSource: .automatic,
        runtime: runtime
      )
    }
  }

  private func resumeApprovedToolCalls(
    _ existingRecords: [ToolCallRecord],
    batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    toolOrchestrator: ToolOrchestrator,
    approvalSource: ToolApprovalSource,
    runtime: ChatTurnRuntimeContext
  ) async throws -> ChatTurnTaskOutcome {
    for requestedRecord in existingRecords {
      try Task.checkCancellation()
      guard isActive(turnID) else {
        return .stop
      }
      if approvalSource == .automatic {
        let session = chatSession
        guard session.interactionMode == .agent,
          session.toolApprovalPolicy == .automatic
        else {
          return try await continueAfterResolvedToolBatch(
            containing: batchAnchorID,
            in: workspace,
            turnID: turnID,
            runtime: runtime
          )
        }
      }
      guard
        let liveRecord = chatSession.toolCallRecord(id: requestedRecord.id),
        liveRecord.status == .awaitingApproval
      else {
        continue
      }

      var approvedRecord: ToolCallRecord
      if approvalSource == .automatic {
        approvedRecord = await toolOrchestrator.executeApproved(
          request: liveRecord.request,
          workspace: workspace
        )
      } else {
        approvedRecord = await toolOrchestrator.executeApproved(
          request: liveRecord.request,
          approvedEvaluation: liveRecord.evaluation,
          workspace: workspace
        )
      }
      if approvedRecord.status != .awaitingApproval,
        approvedRecord.evaluation.decision != .denied
      {
        approvedRecord.approvalSource = approvalSource
      }
      guard isActive(turnID), !Task.isCancelled else {
        applyWorkflowEvents([.toolCallUpdated(approvedRecord)])
        notifySessionDidChange()
        return .stop
      }
      if approvedRecord.status == .awaitingApproval {
        applyWorkflowEvents([.toolCallUpdated(approvedRecord)])
        notifySessionDidChange()
        continue
      }
      let resumeResult = toolResumeCoordinator.approvedToolResult(
        record: approvedRecord,
        focusedFileState: chatSession.focusedFileState,
        turnID: turnID
      )
      applyWorkflowEvents(resumeResult.events)
      notifySessionDidChange()
    }

    return try await continueAfterResolvedToolBatch(
      containing: batchAnchorID,
      in: workspace,
      turnID: turnID,
      runtime: runtime
    )
  }

  private func resumeAnsweredAskUserToolCall(
    _ existingRecord: ToolCallRecord,
    answer: String,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext
  ) async throws -> ChatTurnTaskOutcome {
    let resumeResult = toolResumeCoordinator.answeredAskUserTool(
      record: existingRecord,
      answer: answer,
      turnID: turnID
    )
    guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID else {
      return .stop
    }

    applyWorkflowEvents(resumeResult.events)
    let toolProfile = turnExecutionCoordinator.activeToolProfile(
      workspace: workspace,
      sessionID: existingRecord.request.sessionID,
      interactionMode: chatSession.interactionMode,
      selectedModel: runtime.selectedModel
    )
    guard let turn = chatSession.turns.first(where: { $0.id == turnID }) else {
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
    turnExecutionCoordinator.applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      conversation: self
    )
    refreshContextUsage(toolPromptMode: promptMode)
    notifySessionDidChange()

    let turnToolRegistry = frozenToolRegistry(
      for: turnID,
      toolProfile: toolProfile,
      runtime: runtime
    )
    let stableInstructions = stableInstructions(
      toolProfile: toolProfile,
      turnToolRegistry: turnToolRegistry,
      runtime: runtime
    )
    let generationResult = try await turnExecutionCoordinator.streamAssistantReply(
      to: nextAssistantMessageID,
      runtime: runtime,
      conversation: self,
      interactionMode: chatSession.interactionMode,
      toolPromptMode: promptMode,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: turn.toolCallBatchCount
    )
    if promptMode.isFinal {
      try turnExecutionCoordinator.requireVisibleFinalResponse(generationResult)
      return .complete
    }
    try turnExecutionCoordinator.requireVisibleTextOrToolCall(generationResult)
    let toolLoopOutcome = try await turnExecutionCoordinator.runToolLoop(
      workspace: workspace,
      sessionID: existingRecord.request.sessionID,
      lastAssistantMessageID: nextAssistantMessageID,
      turnID: turnID,
      interactionMode: chatSession.interactionMode,
      runtime: runtime,
      conversation: self,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      lastNativeToolCalls: generationResult.nativeToolCalls
    )
    return try await resolveToolLoopOutcome(
      toolLoopOutcome,
      in: workspace,
      turnID: turnID,
      runtime: runtime
    )
  }

  private func resumeDeniedToolCall(
    _ existingRecord: ToolCallRecord,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext
  ) async throws -> ChatTurnTaskOutcome {
    let resumeResult = toolResumeCoordinator.deniedTool(
      record: existingRecord,
      turnID: turnID
    )
    applyWorkflowEvents(resumeResult.events)
    notifySessionDidChange()

    return try await continueAfterResolvedToolBatch(
      containing: existingRecord.id,
      in: nil,
      turnID: turnID,
      runtime: runtime
    )
  }

  private func continueAfterResolvedToolBatch(
    containing toolCallID: ToolCallRecord.ID,
    in workspace: Workspace?,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext
  ) async throws -> ChatTurnTaskOutcome {
    guard let turn = chatSession.turns.first(where: { $0.id == turnID }),
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
      runtime: runtime
    )
    let promptMode = ToolFollowUpPromptPolicy.promptMode(
      for: toolProfile,
      finalReason: finalReason(batch, in: turn)
    )
    let nextAssistantMessageID = UUID()
    applyWorkflowEvents([
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
    turnExecutionCoordinator.applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      conversation: self
    )
    refreshContextUsage(toolPromptMode: promptMode)
    notifySessionDidChange()

    let turnToolRegistry = frozenToolRegistry(
      for: turnID,
      toolProfile: toolProfile,
      runtime: runtime
    )
    let stableInstructions = stableInstructions(
      toolProfile: toolProfile,
      turnToolRegistry: turnToolRegistry,
      runtime: runtime
    )
    let generationResult = try await turnExecutionCoordinator.streamAssistantReply(
      to: nextAssistantMessageID,
      runtime: runtime,
      conversation: self,
      interactionMode: chatSession.interactionMode,
      toolPromptMode: promptMode,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: turn.toolCallBatchCount
    )
    if promptMode.isFinal {
      try turnExecutionCoordinator.requireVisibleFinalResponse(generationResult)
      return .complete
    }

    guard let workspace else {
      return .fail(cancelsStreaming: false)
    }
    try turnExecutionCoordinator.requireVisibleTextOrToolCall(generationResult)
    let toolLoopOutcome = try await turnExecutionCoordinator.runToolLoop(
      workspace: workspace,
      sessionID: firstRecord.request.sessionID,
      lastAssistantMessageID: nextAssistantMessageID,
      turnID: turnID,
      interactionMode: chatSession.interactionMode,
      runtime: runtime,
      conversation: self,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      lastNativeToolCalls: generationResult.nativeToolCalls
    )
    return try await resolveToolLoopOutcome(
      toolLoopOutcome,
      in: workspace,
      turnID: turnID,
      runtime: runtime
    )
  }

  private func resolvedToolProfile(
    workspace: Workspace?,
    sessionID: ChatSession.ID,
    runtime: ChatTurnRuntimeContext
  ) -> ToolExecutionProfile {
    if let workspace {
      return turnExecutionCoordinator.activeToolProfile(
        workspace: workspace,
        sessionID: sessionID,
        interactionMode: chatSession.interactionMode,
        selectedModel: runtime.selectedModel
      )
    }
    return chatSession.interactionMode == .chat ? .chatWeb : .agent
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
    runtime: ChatTurnRuntimeContext
  ) -> String {
    turnExecutionCoordinator.systemPrompt(
      session: chatSession,
      selectedModel: runtime.selectedModel,
      toolLoopCoordinator: runtime.toolLoopCoordinator,
      toolPromptMode: turnExecutionCoordinator.toolPromptMode(for: toolProfile),
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
