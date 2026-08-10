import Foundation

@MainActor
struct ChatTurnRuntimeContext {
  let selectedModel: ManagedModel
  let operationID: UUID
  let chatGenerationCoordinator: ChatGenerationCoordinator
  let toolLoopCoordinator: ToolLoopCoordinator
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

private enum ToolBudgetFinalizationFailure {
  case missingFinishTask
  case unavailableTool(ToolName)
  case unknownTool
  case invalidFinishTask
  case mixedFinishTaskBatch
  case multipleInvalidOrUnavailableTools

  var userVisibleMessage: String {
    switch self {
    case .missingFinishTask:
      "Tool budget exhausted. The model did not produce the required `finish_task` call. Changes may be incomplete."
    case .unavailableTool(let toolName):
      "Tool budget exhausted. The model attempted `\(toolName.rawValue)`, but only `finish_task` was available. This final tool attempt was not executed. Any earlier successful changes remain applied."
    case .unknownTool:
      "Tool budget exhausted. The model attempted an invalid tool call, but only `finish_task` was available. This final tool attempt was not executed. Any earlier successful changes remain applied."
    case .invalidFinishTask, .mixedFinishTaskBatch:
      "Tool budget exhausted. The final `finish_task` response was invalid and was not accepted. No call from this finalization batch was executed. Changes may be incomplete."
    case .multipleInvalidOrUnavailableTools:
      "Tool budget exhausted. The model attempted invalid or unavailable tool calls, but only `finish_task` was available. No call from this finalization batch was executed. Any earlier successful changes remain applied."
    }
  }
}

@MainActor
struct ChatTurnExecutionCoordinator {
  private let focusedFileReducer: FocusedFileStateReducer
  private let modelContextBuilder: ChatModelContextBuilder
  private let toolPromptPolicy: ToolPromptPolicy
  private let toolFollowUpNoticePolicy: ToolFollowUpNoticePolicy
  private let turnTracer: any TurnTracing

  init(
    focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer(),
    modelContextBuilder: ChatModelContextBuilder = ChatModelContextBuilder(),
    toolPromptPolicy: ToolPromptPolicy = ToolPromptPolicy(),
    toolFollowUpNoticePolicy: ToolFollowUpNoticePolicy = ToolFollowUpNoticePolicy(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.focusedFileReducer = focusedFileReducer
    self.modelContextBuilder = modelContextBuilder
    self.toolPromptPolicy = toolPromptPolicy
    self.toolFollowUpNoticePolicy = toolFollowUpNoticePolicy
    self.turnTracer = turnTracer
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
      mode: interactionMode,
      focusedFileState: session.focusedFileState,
      attachments: attachments
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
          promptContext: currentPromptContext
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
    var assistantThinkingMessageID = UUID()
    var didAppendAssistantThinking = false
    var didCompleteAssistantThinking = false
    let generationContext = prepareGenerationContext(
      runtime: runtime,
      conversation: conversation,
      interactionMode: interactionMode,
      toolPromptMode: toolPromptMode,
      turnToolRegistry: turnToolRegistry,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: toolLoopIteration
    )
    let promptPlan = generationContext.promptPlan
    let modelPromptProjection = generationContext.modelPromptProjection
    let failedCommandGuard = failedRunCommandGuardContext(
      session: conversation.chatSession,
      turnID: turnID
    )
    let suppressVisibleAssistantContent = toolPromptMode == .afterToolBudgetExhausted
    var guardedAssistantChunks = ""

    func generate(using currentPromptPlan: ChatRuntimePromptPlan) async throws
      -> ChatGenerationResult
    {
      try await runtime.chatGenerationCoordinator.streamAssistantReplyResult(
        turnID: turnID,
        operationID: runtime.operationID,
        toolLoopIteration: toolLoopIteration,
        interactionMode: interactionMode,
        transcript: modelPromptProjection,
        attachments: attachments,
        promptPlan: currentPromptPlan,
        settings: conversation.chatSession.generationSettings,
        appendChunk: { chunk in
          guard conversation.isActive(turnID) else {
            return
          }
          if failedCommandGuard != nil || suppressVisibleAssistantContent {
            guardedAssistantChunks += chunk
            return
          }
          let events: [ChatWorkflowEvent] = [
            .assistantChunkAppended(
              chunk: chunk,
              messageID: assistantMessageID
            )
          ]
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
        completeThinking: {
          guard conversation.isActive(turnID),
            didAppendAssistantThinking,
            !didCompleteAssistantThinking
          else {
            return
          }
          didCompleteAssistantThinking = true
          conversation.applyWorkflowEvents([
            .assistantThinkingCompleted(messageID: assistantThinkingMessageID)
          ])
        },
        updateGenerationMetrics: { metrics in
          guard conversation.isActive(turnID) else {
            return
          }
          let events: [ChatWorkflowEvent] = [
            .assistantGenerationCompleted(
              messageID: assistantMessageID,
              metrics: metrics
            )
          ]
          conversation.applyWorkflowEvents(events)
        },
        updateRuntimeCacheDebugSnapshot: { snapshot in
          guard conversation.isActive(turnID) else {
            return
          }
          conversation.updateRuntimeCacheDebugSnapshot(snapshot)
        }
      )
    }

    var generationResult = try await generate(using: promptPlan)
    if interactionMode == .agent,
      toolPromptMode != .afterToolBudgetExhausted,
      generationResult.nativeToolCalls.isEmpty,
      generationResult.termination == .outputLimit(discardedToolProtocolTail: true)
    {
      if didAppendAssistantThinking {
        conversation.applyWorkflowEvents([
          .assistantThinkingCancelled(messageID: assistantThinkingMessageID)
        ])
      }
      assistantThinkingMessageID = UUID()
      didAppendAssistantThinking = false
      didCompleteAssistantThinking = false
      generationResult = try await generate(
        using: promptPlan.appendingTransientInstruction(
          Self.outputLimitRetryInstruction
        )
      )
    }
    if toolPromptMode != .afterToolBudgetExhausted,
      generationResult.nativeToolCalls.isEmpty,
      case .outputLimit = generationResult.termination
    {
      throw ChatGenerationError.outputLimitReached
    }
    guard conversation.isActive(turnID) else {
      return ChatGenerationResult(assistantContent: "")
    }
    if let failedCommandGuard, !suppressVisibleAssistantContent {
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
    if didAppendAssistantThinking, !didCompleteAssistantThinking {
      conversation.applyWorkflowEvents([
        .assistantThinkingCancelled(messageID: assistantThinkingMessageID)
      ])
    }
    completeOutputLimitedTranscriptIfNeeded(
      generationResult,
      assistantMessageID: assistantMessageID,
      conversation: conversation
    )
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
    turnToolOrchestrator: ToolOrchestrator,
    stableInstructions: String,
    lastNativeToolCalls: [ChatRuntimeToolCall] = [],
    lastBatchFollowUpNotice: String? = nil
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
    var currentBatchFollowUpNotice = lastBatchFollowUpNotice
    let toolCallingPolicy = runtime.selectedModel.toolCallingPolicy
    let maxToolLoopIterations = runtime.selectedModel.maxToolLoopIterations
    let turnToolRegistry = turnToolOrchestrator.toolRegistry

    while !currentNativeToolCalls.isEmpty {
      let consumedBatchCount = toolCallBatchCount(
        turnID: turnID,
        session: conversation.chatSession
      )
      guard consumedBatchCount < maxToolLoopIterations else {
        throw ChatGenerationError.emptyModelResponse
      }
      let toolLoopIteration = consumedBatchCount + 1
      let followUpPromptMode =
        if toolProfile == .agent, toolLoopIteration == maxToolLoopIterations {
          ToolPromptMode.afterToolBudgetExhausted
        } else {
          ToolFollowUpPromptPolicy.promptMode(
            for: toolProfile,
            finalReason: toolLoopIteration == maxToolLoopIterations
              ? .toolBatchBudgetExhausted
              : nil
          )
        }
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
            followUpPromptMode: followUpPromptMode,
            toolLoopIteration: toolLoopIteration,
            toolCallingPolicy: toolCallingPolicy,
            nativeToolCalls: currentNativeToolCalls,
            batchFollowUpNotice: currentBatchFollowUpNotice,
            approvalPolicyProvider: {
              let session = await conversation.chatSession
              guard session.interactionMode == .agent else {
                return .manual
              }
              return session.toolApprovalPolicy
            }
          ),
          using: turnToolOrchestrator
        )
      else {
        return .complete
      }
      currentNativeToolCalls = []
      currentBatchFollowUpNotice = nil
      try Task.checkCancellation()
      guard conversation.isActive(turnID) else {
        return .stop
      }

      conversation.applyWorkflowEvents(step.events)
      conversation.notifySessionDidChange()

      switch step.continuation {
      case .awaitingApproval, .awaitingUserAnswer:
        conversation.finishTurn(turnID)
        conversation.finishGeneratingTurn()
        conversation.notifySessionDidChange()
        return .stop
      case .resumeAutomaticApproval(let batchAnchorID):
        return .resumeAutomaticApproval(batchAnchorID: batchAnchorID)
      case .resumeGeneration(let nextAssistantMessageID, .afterToolBudgetExhausted),
        .resumeCorrectionGeneration(let nextAssistantMessageID, .afterToolBudgetExhausted):
        return try await finishAfterToolBudgetExhaustion(
          workspace: workspace,
          sessionID: sessionID,
          assistantMessageID: nextAssistantMessageID,
          turnID: turnID,
          interactionMode: interactionMode,
          runtime: runtime,
          conversation: conversation,
          turnToolOrchestrator: turnToolOrchestrator,
          stableInstructions: stableInstructions,
          toolLoopIteration: maxToolLoopIterations + 1
        )
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
        currentBatchFollowUpNotice = outputLimitFollowUpNotice(for: generationResult)
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
        currentBatchFollowUpNotice = outputLimitFollowUpNotice(for: generationResult)
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

  func finishAfterToolBudgetExhaustion(
    workspace: Workspace,
    sessionID: ChatSession.ID,
    assistantMessageID: UUID,
    turnID: ChatTurn.ID,
    interactionMode: WorkspaceInteractionMode,
    runtime: ChatTurnRuntimeContext,
    conversation: ConversationEngine,
    turnToolOrchestrator: ToolOrchestrator,
    stableInstructions: String,
    toolLoopIteration: Int
  ) async throws -> ChatToolLoopOutcome {
    let finishTaskOrchestrator = turnToolOrchestrator.replacingExecutorRegistry(
      ToolExecutorRegistry([
        AnyToolExecutor(FinishTaskToolExecutor())
      ])
    )
    let finishTaskRegistry = finishTaskOrchestrator.toolRegistry
    let generationResult = try await streamAssistantReply(
      to: assistantMessageID,
      runtime: runtime,
      conversation: conversation,
      interactionMode: interactionMode,
      toolPromptMode: .afterToolBudgetExhausted,
      turnToolRegistry: finishTaskRegistry,
      stableInstructions: stableInstructions,
      turnID: turnID,
      toolLoopIteration: toolLoopIteration
    )
    try Task.checkCancellation()
    guard conversation.isActive(turnID) else {
      return .stop
    }
    guard !generationResult.nativeToolCalls.isEmpty else {
      appendToolBudgetFallback(
        to: assistantMessageID,
        failure: .missingFinishTask,
        conversation: conversation
      )
      return .complete
    }

    guard
      let step = try await runtime.toolLoopCoordinator.run(
        ToolLoopRequest(
          workspace: workspace,
          sessionID: sessionID,
          turnID: turnID,
          assistantMessageID: assistantMessageID,
          items: conversation.chatSession.turns.flatMap(\.items),
          focusedFileState: conversation.chatSession.focusedFileState,
          interactionMode: interactionMode,
          followUpPromptMode: .afterToolBudgetExhausted,
          toolLoopIteration: toolLoopIteration,
          toolCallingPolicy: runtime.selectedModel.toolCallingPolicy,
          nativeToolCalls: generationResult.nativeToolCalls
        ),
        using: finishTaskOrchestrator
      )
    else {
      appendToolBudgetFallback(
        to: assistantMessageID,
        failure: finalizationFailure(
          nativeToolCalls: generationResult.nativeToolCalls,
          step: nil
        ),
        conversation: conversation
      )
      return .complete
    }
    try Task.checkCancellation()
    guard conversation.isActive(turnID) else {
      return .stop
    }

    conversation.applyWorkflowEvents(step.events)
    conversation.notifySessionDidChange()
    guard step.continuation != .stopTurn else {
      return .complete
    }

    let fallbackMessageID =
      switch step.continuation {
      case .resumeGeneration(let messageID, _),
        .resumeCorrectionGeneration(let messageID, _):
        messageID
      case .none, .awaitingApproval, .awaitingUserAnswer, .resumeAutomaticApproval,
        .stopTurn:
        assistantMessageID
      }
    appendToolBudgetFallback(
      to: fallbackMessageID,
      failure: finalizationFailure(
        nativeToolCalls: generationResult.nativeToolCalls,
        step: step
      ),
      conversation: conversation
    )
    return .complete
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
      return .agent
    }
  }

  @discardableResult
  func applyToolFollowUpNoticeIfNeeded(
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurn.ID,
    maxToolLoopIterations: Int,
    conversation: ConversationEngine
  ) -> Bool {
    guard
      let update = toolFollowUpNoticePolicy.update(
        session: conversation.chatSession,
        turnID: turnID,
        promptMode: toolPromptMode,
        maxToolLoopIterations: maxToolLoopIterations
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
  private func prepareGenerationContext(
    runtime: ChatTurnRuntimeContext,
    conversation: ConversationEngine,
    interactionMode: WorkspaceInteractionMode,
    toolPromptMode: ToolPromptMode,
    turnToolRegistry: ToolRegistry,
    stableInstructions: String,
    turnID: ChatTurn.ID,
    toolLoopIteration: Int?
  ) -> (promptPlan: ChatRuntimePromptPlan, modelPromptProjection: ModelPromptProjection) {
    conversation.setActiveToolPromptMode(toolPromptMode)
    applyToolFollowUpNoticeIfNeeded(
      toolPromptMode: toolPromptMode,
      turnID: turnID,
      maxToolLoopIterations: runtime.selectedModel.maxToolLoopIterations,
      conversation: conversation
    )

    let systemPromptStartedAt = Date()
    let promptPlan = runtimePromptPlan(
      session: conversation.chatSession,
      stableInstructions: stableInstructions,
      toolPromptMode: toolPromptMode,
      toolCallingPolicy: runtime.selectedModel.toolCallingPolicy,
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
      includingTurnID: turnID,
      supportsHistoricalReasoningPreservation:
        runtime.selectedModel.supportsHistoricalReasoningPreservation
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
    return (promptPlan, modelPromptProjection)
  }

  private func appendToolBudgetFallback(
    to assistantMessageID: UUID,
    failure: ToolBudgetFinalizationFailure,
    conversation: ConversationEngine
  ) {
    let targetMessage = conversation.chatSession.turns
      .flatMap(\.items)
      .compactMap { item -> AssistantTurnMessage? in
        guard case .assistantMessage(let message) = item,
          message.id == assistantMessageID
        else {
          return nil
        }
        return message
      }
      .first
    var events: [ChatWorkflowEvent] = [
      .assistantChunkAppended(
        chunk: failure.userVisibleMessage,
        messageID: assistantMessageID
      )
    ]
    if targetMessage?.deliveryStatus == .streaming {
      events.append(
        .assistantGenerationCompleted(
          messageID: assistantMessageID,
          metrics: targetMessage?.generationMetrics
        ))
    }
    conversation.applyWorkflowEvents(events)
    conversation.notifySessionDidChange()
  }

  private func finalizationFailure(
    nativeToolCalls: [ChatRuntimeToolCall],
    step: ChatWorkflowStep?
  ) -> ToolBudgetFinalizationFailure {
    guard !nativeToolCalls.isEmpty else {
      return .missingFinishTask
    }
    let records =
      step?.events.compactMap { event -> ToolCallRecord? in
        guard case .toolCallAppended(let record, _) = event else {
          return nil
        }
        return record
      } ?? []
    if nativeToolCalls.count > 1 {
      return records.contains { $0.request.toolName == .finishTask }
        ? .mixedFinishTaskBatch
        : .multipleInvalidOrUnavailableTools
    }
    guard records.first?.request.toolName != .finishTask else {
      return .invalidFinishTask
    }

    guard let record = records.first, case .invalid(let input) = record.request.payload else {
      return .unknownTool
    }
    switch input.reason {
    case .unavailableToolName:
      return .unavailableTool(record.request.toolName)
    case .unknownToolName:
      return .unknownTool
    default:
      return .unknownTool
    }
  }

  private func completeOutputLimitedTranscriptIfNeeded(
    _ result: ChatGenerationResult,
    assistantMessageID: UUID,
    conversation: ConversationEngine
  ) {
    guard case .outputLimit = result.termination else {
      return
    }
    let events: [ChatWorkflowEvent] = [
      .assistantGenerationOutputLimitReached(
        messageID: assistantMessageID
      )
    ]
    conversation.applyWorkflowEvents(events)
  }

  private static let outputLimitRetryInstruction =
    """
    [Output-limit recovery]
    The previous generation reached its output limit while emitting an incomplete tool call. No call from that generation was accepted.
    Retry only the remaining work. Keep each individual tool payload small. Multiple complete tool calls are allowed.
    For a large new file, create a compact valid scaffold first, then extend it with edit_file in later calls.
    Do not repeat changes that already completed earlier in this turn.
    """

  private static let outputLimitFollowUpNotice =
    """
    The previous generation reached its output limit after the tool calls above. Those complete tool calls were accepted; do not repeat them.
    Continue only the remaining work with smaller individual tool payloads. Multiple complete tool calls are allowed.
    For a large new file, create a compact valid scaffold first, then extend it with edit_file in later calls.
    """

  func outputLimitFollowUpNotice(for result: ChatGenerationResult) -> String? {
    guard !result.nativeToolCalls.isEmpty,
      case .outputLimit = result.termination
    else {
      return nil
    }
    return Self.outputLimitFollowUpNotice
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

  func systemPrompt(
    session: ChatSession,
    selectedModel: ManagedModel,
    toolPromptMode: ToolPromptMode,
    toolRegistry: ToolRegistry
  ) -> String {
    return toolPromptPolicy.systemPrompt(
      basePrompt: session.systemPrompt,
      mode: toolPromptMode,
      toolRegistry: toolRegistry,
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
  ) -> ChatRuntimePromptPlan {
    let runtimeToolRegistry =
      toolPromptMode == .afterToolBudgetExhausted
      ? ToolRegistry(tools: [.finishTask])
      : turnToolRegistry
    return ChatRuntimePromptPlan(
      stableInstructions: stableInstructions,
      transientInstructions: transientInstructions(
        session: session,
        toolPromptMode: toolPromptMode,
        turnToolRegistry: runtimeToolRegistry
      ),
      toolContext: runtimeToolContext(
        for: toolPromptMode,
        policy: toolCallingPolicy,
        registry: runtimeToolRegistry
      )
    )
  }

  private func runtimeToolContext(
    for toolPromptMode: ToolPromptMode,
    policy: ToolCallingPolicy,
    registry: ToolRegistry
  ) -> ChatRuntimeToolContext? {
    guard policy.isEnabled else {
      return nil
    }
    switch toolPromptMode {
    case .disabled, .afterToolResultFinal, .afterChatWebToolResultFinal:
      return nil
    case .chatWeb, .afterChatWebToolResultCanContinue, .afterToolResultCanContinue,
      .afterToolBudgetExhausted, .agent:
      break
    }
    return ChatRuntimeToolContext(registry: registry)
  }

  private func transientInstructions(
    session: ChatSession,
    toolPromptMode: ToolPromptMode,
    turnToolRegistry: ToolRegistry
  ) -> [String] {
    var instructions: [String] = []
    if toolPromptMode == .afterToolBudgetExhausted {
      instructions.append(ToolFollowUpNoticePolicy.toolBudgetExhaustedNotice)
    }
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
