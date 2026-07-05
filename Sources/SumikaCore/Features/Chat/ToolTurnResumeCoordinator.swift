import Foundation

@MainActor
struct ToolTurnResumeCoordinator {
  private let toolResumeCoordinator: ToolResumeCoordinator
  private let executionCoordinator: ChatTurnExecutionCoordinator
  private let maxToolLoopIterations: Int

  init(
    toolResumeCoordinator: ToolResumeCoordinator,
    executionCoordinator: ChatTurnExecutionCoordinator,
    maxToolLoopIterations: Int
  ) {
    self.toolResumeCoordinator = toolResumeCoordinator
    self.executionCoordinator = executionCoordinator
    self.maxToolLoopIterations = maxToolLoopIterations
  }

  func approveToolCall(
    _ existingRecord: ToolCallRecord,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    toolOrchestrator: ToolOrchestrator,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks,
    isActive: ChatTurnActiveChecker,
    finishTurn: ChatTurnFinisher
  ) async throws -> ChatTurnTaskOutcome {
    let approvedRecord = await toolOrchestrator.executeApproved(
      request: existingRecord.request,
      workspace: workspace
    )
    guard isActive(turnID) else {
      return .stop
    }

    let toolProfile = executionCoordinator.activeToolProfile(
      workspace: workspace,
      sessionID: existingRecord.request.sessionID,
      interactionMode: callbacks.session().interactionMode,
      selectedModel: runtime.selectedModel
    )
    let stableInstructions = stableInstructions(
      toolProfile: toolProfile,
      runtime: runtime,
      callbacks: callbacks
    )
    let resumeResult = toolResumeCoordinator.approvedToolResult(
      record: approvedRecord,
      focusedFileState: callbacks.session().focusedFileState,
      turnID: turnID,
      toolProfile: toolProfile
    )

    guard approvedRecord.status == .completed else {
      callbacks.emitEvents(resumeResult.events)
      return .fail(cancelsStreaming: false)
    }

    guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID,
      let promptMode = resumeResult.followUpPromptMode
    else {
      return .fail(cancelsStreaming: false)
    }

    callbacks.emitEvents(resumeResult.events)
    executionCoordinator.applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      callbacks: callbacks
    )
    callbacks.notifySessionDidChange()
    executionCoordinator.appendFinalToolFollowUpBoundaryIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      emitEvents: callbacks.emitEvents
    )
    let generationResult = try await executionCoordinator.streamAssistantReply(
      to: nextAssistantMessageID,
      runtime: runtime,
      callbacks: callbacks,
      isActive: isActive,
      interactionMode: callbacks.session().interactionMode,
      toolPromptMode: promptMode,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: 1
    )
    if toolResumeCoordinator.isFinalApprovedToolFollowUp(approvedRecord) {
      try executionCoordinator.requireVisibleFinalResponse(generationResult)
    } else {
      try executionCoordinator.requireVisibleTextOrToolCall(generationResult)
      let shouldComplete = try await executionCoordinator.runToolLoop(
        workspace: workspace,
        sessionID: existingRecord.request.sessionID,
        lastAssistantMessageID: nextAssistantMessageID,
        turnID: turnID,
        interactionMode: callbacks.session().interactionMode,
        runtime: runtime,
        callbacks: callbacks,
        isActive: isActive,
        finishTurn: finishTurn,
        stableInstructions: stableInstructions,
        remainingIterations: maxToolLoopIterations - 1,
        lastNativeToolCalls: generationResult.nativeToolCalls
      )
      guard shouldComplete else {
        return .stop
      }
    }
    return .complete
  }

  func answerAskUserToolCall(
    _ existingRecord: ToolCallRecord,
    answer: String,
    in workspace: Workspace,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks,
    isActive: ChatTurnActiveChecker,
    finishTurn: ChatTurnFinisher
  ) async throws -> ChatTurnTaskOutcome {
    let resumeResult = toolResumeCoordinator.answeredAskUserTool(
      record: existingRecord,
      answer: answer,
      turnID: turnID
    )
    guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID,
      let promptMode = resumeResult.followUpPromptMode
    else {
      return .stop
    }

    callbacks.emitEvents(resumeResult.events)
    executionCoordinator.applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      callbacks: callbacks
    )
    callbacks.refreshContextUsage(promptMode)
    callbacks.notifySessionDidChange()

    let toolProfile = executionCoordinator.activeToolProfile(
      workspace: workspace,
      sessionID: existingRecord.request.sessionID,
      interactionMode: callbacks.session().interactionMode,
      selectedModel: runtime.selectedModel
    )
    let stableInstructions = stableInstructions(
      toolProfile: toolProfile,
      runtime: runtime,
      callbacks: callbacks
    )
    let generationResult = try await executionCoordinator.streamAssistantReply(
      to: nextAssistantMessageID,
      runtime: runtime,
      callbacks: callbacks,
      isActive: isActive,
      interactionMode: callbacks.session().interactionMode,
      toolPromptMode: promptMode,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: 1
    )
    try executionCoordinator.requireVisibleTextOrToolCall(generationResult)
    let shouldComplete = try await executionCoordinator.runToolLoop(
      workspace: workspace,
      sessionID: existingRecord.request.sessionID,
      lastAssistantMessageID: nextAssistantMessageID,
      turnID: turnID,
      interactionMode: callbacks.session().interactionMode,
      runtime: runtime,
      callbacks: callbacks,
      isActive: isActive,
      finishTurn: finishTurn,
      stableInstructions: stableInstructions,
      remainingIterations: maxToolLoopIterations - 1,
      lastNativeToolCalls: generationResult.nativeToolCalls
    )
    return shouldComplete ? .complete : .stop
  }

  func denyToolCall(
    _ existingRecord: ToolCallRecord,
    message: String,
    turnID: ChatTurn.ID,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks,
    isActive: ChatTurnActiveChecker
  ) async throws -> ChatTurnTaskOutcome {
    let resumeResult = toolResumeCoordinator.deniedTool(
      record: existingRecord,
      message: message,
      turnID: turnID
    )
    guard let nextAssistantMessageID = resumeResult.nextAssistantMessageID,
      let promptMode = resumeResult.followUpPromptMode
    else {
      return .stop
    }

    callbacks.emitEvents(resumeResult.events)
    executionCoordinator.applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      callbacks: callbacks
    )
    executionCoordinator.appendFinalToolFollowUpBoundaryIfNeeded(
      toolPromptMode: promptMode,
      turnID: turnID,
      emitEvents: callbacks.emitEvents
    )
    callbacks.refreshContextUsage(promptMode)
    callbacks.notifySessionDidChange()

    let stableInstructions = stableInstructions(
      toolProfile: callbacks.session().interactionMode == .chat ? .chatWeb : .agent,
      runtime: runtime,
      callbacks: callbacks
    )
    let generationResult = try await executionCoordinator.streamAssistantReply(
      to: nextAssistantMessageID,
      runtime: runtime,
      callbacks: callbacks,
      isActive: isActive,
      interactionMode: callbacks.session().interactionMode,
      toolPromptMode: promptMode,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: 1
    )
    try executionCoordinator.requireVisibleFinalResponse(generationResult)
    return .complete
  }

  private func stableInstructions(
    toolProfile: ToolExecutionProfile,
    runtime: ChatTurnRuntimeContext,
    callbacks: ChatTurnCallbacks
  ) -> String {
    executionCoordinator.systemPrompt(
      session: callbacks.session(),
      selectedModel: runtime.selectedModel,
      toolLoopCoordinator: runtime.toolLoopCoordinator,
      toolPromptMode: executionCoordinator.toolPromptMode(for: toolProfile)
    )
  }
}
