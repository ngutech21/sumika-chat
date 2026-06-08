import Foundation
import Observation

@MainActor
@Observable
public final class ChatSessionController {
  public var chatSession = ChatSession.codingDefault
  public var contextUsage: ChatContextUsage?
  public var draft = ""
  public var isGenerating = false
  public var errorMessage: String?

  public let modelRuntime: ModelRuntimeController
  @ObservationIgnored private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  @ObservationIgnored private let contextUsageCoordinator: ContextUsageCoordinator
  @ObservationIgnored private let chatGenerationCoordinator: ChatGenerationCoordinator
  @ObservationIgnored private let toolPromptRenderer: any ToolPromptRendering
  @ObservationIgnored private let toolOrchestrator: ToolOrchestrator
  @ObservationIgnored private let toolPromptPolicy: ToolPromptPolicy
  @ObservationIgnored private let toolLoopCoordinator: ToolLoopCoordinator
  @ObservationIgnored private let finalModeActionDetector: FinalModeActionDetector
  @ObservationIgnored private let turnTracer: any TurnTracing
  @ObservationIgnored private let chatTurnCoordinator = ChatTurnCoordinator()
  @ObservationIgnored private let modelContextBuilder = ChatModelContextBuilder()
  @ObservationIgnored private let attachmentCoordinator: ChatAttachmentCoordinator
  @ObservationIgnored private let transcriptMutator = ChatTranscriptMutator()
  @ObservationIgnored private let workflowEventApplier = ChatWorkflowEventApplier()
  @ObservationIgnored private let focusedFileReducer = FocusedFileStateReducer()
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private var pendingRuntimeContextClear: PendingRuntimeContextClear?
  @ObservationIgnored private let streamingFlushInterval: TimeInterval = 0.05
  @ObservationIgnored private let streamingFlushCharacterLimit = 240
  @ObservationIgnored private let maxToolLoopIterations = 6

  public var canSend: Bool {
    modelRuntime.modelState == .ready
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
      && !hasPendingApproval
      && !hasPendingUserAnswer
  }

  public var hasPendingApproval: Bool {
    chatSession.toolCalls.contains { $0.status == .awaitingApproval }
  }

  public var hasPendingUserAnswer: Bool {
    chatSession.toolCalls.contains { $0.status == .awaitingUserAnswer }
  }

  public var isInputBlocked: Bool {
    hasPendingApproval || hasPendingUserAnswer
  }

  public var canChangeInteractionMode: Bool {
    !isGenerating && !isInputBlocked
  }

  public convenience init() {
    self.init(modelSettingsStore: ModelSettingsStore())
  }

  public convenience init(
    modelSettingsStore settingsStore: any ModelSettingsStoring,
    modelDownloader downloader: any ModelDownloading = UnavailableModelDownloader(),
    runtime: any ChatModelRuntime = MockChatRuntime(),
    resourceMonitor: any ProcessResourceMonitoring = ProcessResourceMonitor(),
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    toolPromptRenderer: any ToolPromptRendering = TaggedToolPromptRenderer(),
    toolOrchestrator: ToolOrchestrator = ToolOrchestrator(executorRegistry: .codingAgent),
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    let selectedModel = ManagedModelCatalog.defaultModel
    let storedSettings = StoredModelSettings(
      systemPrompt: selectedModel.defaultSystemPrompt,
      generationSettings: selectedModel.defaultGenerationSettings,
      contextTokenLimit: selectedModel.defaultContextTokenLimit
    )
    self.init(
      selectedModelID: selectedModel.id,
      modelPath: selectedModel.localPath,
      modelContextTokenLimit: storedSettings.contextTokenLimit,
      chatSession: ChatSession(
        modelContextSnapshot: ModelContextSnapshot(),
        toolCalls: [],
        turns: [],
        pendingAttachments: [],
        systemPrompt: storedSettings.systemPrompt,
        generationSettings: storedSettings.generationSettings
      ),
      modelSettingsStore: settingsStore,
      modelDownloader: downloader,
      runtime: runtime,
      resourceMonitor: resourceMonitor,
      toolCallParser: toolCallParser,
      toolPromptRenderer: toolPromptRenderer,
      toolOrchestrator: toolOrchestrator,
      chatAttachmentLoader: chatAttachmentLoader,
      turnTracer: turnTracer
    )
    modelRuntime.loadPersistedModelSelection()
  }

  convenience init(
    runtime: any ChatModelRuntime,
    resourceMonitor: any ProcessResourceMonitoring = ProcessResourceMonitor(),
    modelPath: String,
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    modelDownloader: any ModelDownloading = UnavailableModelDownloader(),
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    toolPromptRenderer: any ToolPromptRendering = TaggedToolPromptRenderer(),
    toolOrchestrator: ToolOrchestrator = ToolOrchestrator(executorRegistry: .codingAgent),
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.init(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      modelPath: modelPath,
      modelContextTokenLimit: ManagedModelCatalog.defaultModel.defaultContextTokenLimit,
      chatSession: .codingDefault,
      modelSettingsStore: modelSettingsStore,
      modelDownloader: modelDownloader,
      runtime: runtime,
      resourceMonitor: resourceMonitor,
      toolCallParser: toolCallParser,
      toolPromptRenderer: toolPromptRenderer,
      toolOrchestrator: toolOrchestrator,
      chatAttachmentLoader: chatAttachmentLoader,
      turnTracer: turnTracer
    )
  }

  private init(
    selectedModelID: ManagedModel.ID,
    modelPath: String,
    modelContextTokenLimit: Int,
    chatSession: ChatSession,
    modelSettingsStore: any ModelSettingsStoring,
    modelDownloader: any ModelDownloading,
    runtime: any ChatModelRuntime,
    resourceMonitor: any ProcessResourceMonitoring,
    toolCallParser: any ToolCallParsing,
    toolPromptRenderer: any ToolPromptRendering,
    toolOrchestrator: ToolOrchestrator,
    chatAttachmentLoader: any ChatAttachmentLoading,
    turnTracer: any TurnTracing
  ) {
    self.turnTracer = turnTracer
    let modelOperationID = UUID()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: modelOperationID
    )
    let modelLifecycleCoordinator = ModelLifecycleCoordinator(
      modelDownloader: modelDownloader,
      runtimeOperations: runtimeOperations
    )
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
    self.contextUsageCoordinator = ContextUsageCoordinator(
      modelLifecycleCoordinator: modelLifecycleCoordinator,
      turnTracer: turnTracer)
    self.chatGenerationCoordinator = ChatGenerationCoordinator(
      runtimeOperations: runtimeOperations,
      turnTracer: turnTracer,
      streamingFlushInterval: streamingFlushInterval,
      streamingFlushCharacterLimit: streamingFlushCharacterLimit
    )
    self.modelRuntime = ModelRuntimeController(
      selectedModelID: selectedModelID,
      modelPath: modelPath,
      modelContextTokenLimit: modelContextTokenLimit,
      modelSettingsStore: modelSettingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: modelLifecycleCoordinator,
      resourceMonitor: resourceMonitor,
      initialOperationID: modelOperationID
    )
    self.toolPromptRenderer = toolPromptRenderer
    self.toolOrchestrator = toolOrchestrator
    self.toolPromptPolicy = ToolPromptPolicy()
    self.toolLoopCoordinator = ToolLoopCoordinator(
      toolCallParser: toolCallParser,
      agentToolOrchestrator: toolOrchestrator,
      turnTracer: turnTracer
    )
    self.finalModeActionDetector = FinalModeActionDetector(
      toolCallParser: toolCallParser,
      turnTracer: turnTracer
    )
    self.attachmentCoordinator = ChatAttachmentCoordinator(loader: chatAttachmentLoader)
    self.chatSession = chatSession
    configureModelRuntimeCallbacks()
  }
}

extension ChatSessionController {
  private func configureModelRuntimeCallbacks() {
    modelRuntime.onModelDidChange = { [weak self] settings in
      guard let self else {
        return
      }

      self.clearChatHistory()
      self.disableUnsupportedInteractionModeIfNeeded()
      self.chatSession.systemPrompt = settings.systemPrompt
      self.chatSession.generationSettings = settings.generationSettings
      self.notifySessionDidChange()
    }
    modelRuntime.onRuntimeDidReset = { [weak self] in
      guard let self else {
        return
      }

      self.invalidateContextUsage()
    }
    modelRuntime.onContextUsageShouldRefresh = { [weak self] in
      await self?.updateContextUsage()
    }
    modelRuntime.onError = { [weak self] message in
      self?.errorMessage = message
    }
  }

  public func setSessionChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
    onSessionDidChange = handler
  }

  public func loadSession(_ session: ChatSession) {
    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel

    cancelGeneration(notify: false)
    let didResetRuntime = modelRuntime.applySessionModel(model)
    errorMessage = nil
    contextUsage = nil
    chatSession = session
    chatSession.pendingAttachments = []
    disableUnsupportedInteractionModeIfNeeded()

    if didResetRuntime {
      invalidateContextUsage()
    } else {
      clearRuntimeContextForReuse()
      refreshContextUsage()
    }
  }

  public func sessionSnapshot(updating session: ChatSession) -> ChatSession {
    var snapshot = session
    snapshot.selectedModelID = modelRuntime.selectedModelID
    snapshot.modelContextSnapshot = chatSession.modelContextSnapshot
    snapshot.toolCalls = chatSession.toolCalls
    snapshot.turns = chatSession.turns
    snapshot.focusedFileState = chatSession.focusedFileState
    snapshot.systemPrompt = chatSession.systemPrompt
    snapshot.generationSettings = chatSession.generationSettings
    snapshot.interactionMode = chatSession.interactionMode
    snapshot.pendingAttachments = []
    snapshot.updatedAt = Date()
    return snapshot
  }

  public func setInteractionMode(_ mode: WorkspaceInteractionMode) {
    guard canChangeInteractionMode, chatSession.interactionMode != mode else {
      return
    }
    guard modelRuntime.selectedModel.supports(interactionMode: mode) else {
      errorMessage = unsupportedInteractionModeMessage(for: modelRuntime.selectedModel)
      return
    }

    chatSession.interactionMode = mode
    errorMessage = nil
    clearRuntimeContextForReuse()
    refreshContextUsage(toolPromptMode: toolPromptMode(for: mode, toolsAvailable: true))
    notifySessionDidChange()
  }

  public func prepareForModelRuntimeAction(
    cancelGeneration shouldCancelGeneration: Bool,
    invalidateContext shouldInvalidateContext: Bool
  ) {
    if shouldCancelGeneration {
      cancelGeneration()
    }
    errorMessage = nil
    if shouldInvalidateContext {
      invalidateContextUsage()
    }
  }

  public func sendMessage() {
    sendMessage(workspace: nil, sessionID: nil)
  }

  public func sendMessage(in workspace: Workspace, sessionID: ChatSession.ID) {
    sendMessage(workspace: workspace, sessionID: sessionID)
  }

  public func sendMessage(in workspace: Workspace) {
    sendMessage(workspace: workspace, sessionID: workspace.sessions.first?.id)
  }

  private func sendMessage(workspace: Workspace?, sessionID: ChatSession.ID?) {
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend else { return }
    guard modelRuntime.selectedModel.supports(interactionMode: chatSession.interactionMode) else {
      errorMessage = unsupportedInteractionModeMessage(for: modelRuntime.selectedModel)
      return
    }
    let attachmentsForTurn = attachmentsForCurrentTurn()
    guard modelRuntime.selectedModel.supportsImageInput || !attachmentsForTurn.hasImages
    else {
      errorMessage = unsupportedImageInputMessage(for: modelRuntime.selectedModel)
      return
    }

    let toolAvailability = toolPromptPolicy.toolAvailability(
      workspace: workspace,
      sessionID: sessionID
    )
    let toolsAvailable =
      toolAvailability == .availableForWorkspace && chatSession.interactionMode != .chat
      && modelRuntime.selectedModel.supportsWorkspaceTools
    let interactionMode = chatSession.interactionMode
    let initialToolPromptMode = toolPromptMode(
      for: interactionMode,
      toolsAvailable: toolsAvailable
    )
    let initialSystemPromptSnapshot = systemPrompt(toolPromptMode: initialToolPromptMode)
    let sentAttachments = attachmentsForTurn
    let turnID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()
    draft = ""
    errorMessage = nil
    chatSession.pendingAttachments.removeAll()
    chatSession.activeAttachmentContext = .empty
    chatSession.focusedFileState.focusedAttachments = []
    applyWorkflowEvents(focusEventsForAttachments(sentAttachments, workspace: workspace))
    transcriptMutator.appendTurn(
      ChatTurn(
        id: turnID,
        status: .running
      ),
      to: &chatSession
    )
    transcriptMutator.appendUserMessage(
      prompt,
      id: userMessageID,
      turnID: turnID,
      attachments: sentAttachments,
      to: &chatSession
    )
    let currentPromptContext = modelContextBuilder.currentPromptContext(
      userInput: prompt,
      mode: interactionMode,
      focusedFileState: chatSession.focusedFileState,
      attachments: sentAttachments,
      workspace: workspace
    )
    if let entry = try? ModelFacingPromptRenderer.userPromptEntry(
      turnID: turnID,
      sourceMessageID: userMessageID,
      prompt: prompt,
      attachments: sentAttachments,
      systemContext: [initialSystemPromptSnapshot] + currentPromptContext.renderedBlocks,
      currentPromptContext: currentPromptContext.consumedContext
    ) {
      transcriptMutator.appendModelContextEntry(entry, to: &chatSession)
    }
    transcriptMutator.appendAssistantPlaceholder(
      id: assistantMessageID,
      turnID: turnID,
      to: &chatSession
    )
    isGenerating = true
    notifySessionDidChange()

    chatTurnCoordinator.startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }

      do {
        try await awaitPendingRuntimeContextClear()
        refreshContextUsage(toolPromptMode: initialToolPromptMode)
        let generationResult = try await streamAssistantReply(
          to: assistantMessageID,
          interactionMode: interactionMode,
          toolPromptMode: initialToolPromptMode,
          turnID: turnID,
          attachments: sentAttachments
        )
        guard isCurrentTurn(turnID) else {
          return
        }
        if toolsAvailable && interactionMode.allowsToolLoop {
          try await runToolLoop(
            workspace: workspace,
            sessionID: sessionID,
            lastAssistantMessageID: assistantMessageID,
            turnID: turnID,
            interactionMode: interactionMode,
            lastNativeToolCalls: generationResult.nativeToolCalls
          )
        }
      } catch is CancellationError {
        guard isCurrentTurn(turnID) else {
          return
        }
        markTurnCancelled(turnID)
        isGenerating = false
        chatTurnCoordinator.finishTurn(turnID)
        flushPendingContextUsageRefresh(defaultMode: .disabled)
        notifySessionDidChange()
        return
      } catch {
        guard isCurrentTurn(turnID) else {
          return
        }
        applyWorkflowEvents([
          .turnStatusChanged(
            turnID: turnID,
            status: .failed,
            modelContextPolicy: .excluded
          ),
          .streamingAssistantMessagesCancelled(turnID: turnID),
          .transientAssistantPlaceholdersRemoved,
        ])
        errorMessage = error.localizedDescription
        isGenerating = false
        chatTurnCoordinator.finishTurn(turnID)
        flushPendingContextUsageRefresh(defaultMode: .disabled)
        notifySessionDidChange()
        return
      }

      guard isCurrentTurn(turnID) else {
        return
      }
      applyWorkflowEvents([
        .turnStatusChanged(
          turnID: turnID,
          status: .completed,
          modelContextPolicy: nil
        )
      ])
      isGenerating = false
      chatTurnCoordinator.finishTurn(turnID)
      flushPendingContextUsageRefresh(defaultMode: .disabled)
      notifySessionDidChange()
    }
  }

  public func cancelGeneration() {
    cancelGeneration(notify: true)
  }

  private func cancelGeneration(notify: Bool) {
    if let turnID = chatTurnCoordinator.cancelActiveTurn() {
      markTurnCancelled(turnID)
    }
    isGenerating = false
    flushPendingContextUsageRefresh(defaultMode: .disabled)
    if notify {
      notifySessionDidChange()
    }
  }

  public func clearChatHistory() {
    transcriptMutator.clearTranscript(in: &chatSession)
    invalidateContextUsage()
    notifySessionDidChange()

    clearRuntimeContextForReuse()
    refreshContextUsage()
  }

  public func refreshContextUsage(toolPromptMode: ToolPromptMode = .disabled) {
    let snapshot = contextUsageSnapshot(toolPromptMode: toolPromptMode)
    contextUsageCoordinator.refreshDebounced(
      snapshot: snapshot,
      onEvent: handleContextUsageEvent(_:))
  }

  public func updateContextUsage() async {
    let snapshot = contextUsageSnapshot()
    contextUsageCoordinator.refreshDebounced(
      snapshot: snapshot,
      onEvent: handleContextUsageEvent(_:))
  }

  private func invalidateContextUsage() {
    contextUsageCoordinator.invalidate(onEvent: handleContextUsageEvent(_:))
  }

  private func clearRuntimeContextForReuse() {
    let operationID = modelRuntime.currentOperationID()
    let modelLifecycleCoordinator = modelLifecycleCoordinator
    let previousTask = pendingRuntimeContextClear?.task
    let clearID = UUID()
    let clearTask = Task {
      if let previousTask {
        try await previousTask.value
      }
      try await modelLifecycleCoordinator.clearContext(operationID: operationID)
    }
    pendingRuntimeContextClear = PendingRuntimeContextClear(id: clearID, task: clearTask)

    Task { [weak self, clearID, clearTask] in
      do {
        try await clearTask.value
        self?.completeRuntimeContextClear(id: clearID, error: nil)
      } catch is CancellationError {
        self?.completeRuntimeContextClear(id: clearID, error: nil)
      } catch {
        self?.completeRuntimeContextClear(id: clearID, error: error)
      }
    }
  }

  private func awaitPendingRuntimeContextClear() async throws {
    guard let pendingRuntimeContextClear else {
      return
    }

    try await pendingRuntimeContextClear.task.value
    if self.pendingRuntimeContextClear?.id == pendingRuntimeContextClear.id {
      self.pendingRuntimeContextClear = nil
    }
  }

  private func completeRuntimeContextClear(id: UUID, error: Error?) {
    guard pendingRuntimeContextClear?.id == id else {
      return
    }

    pendingRuntimeContextClear = nil
    if let error {
      errorMessage = error.localizedDescription
    } else {
      flushPendingContextUsageRefresh(defaultMode: .disabled)
    }
  }

  private struct PendingRuntimeContextClear {
    let id: UUID
    let task: Task<Void, Error>
  }

  private func flushPendingContextUsageRefresh(defaultMode: ToolPromptMode) {
    refreshContextUsage(toolPromptMode: defaultMode)
  }

  private func contextUsageSnapshot(toolPromptMode: ToolPromptMode = .disabled)
    -> ContextUsageSnapshot
  {
    let turnID = chatTurnCoordinator.activeTurnID
    let contextBuildStartedAt = Date()
    let transcript = modelContextBuilder.transcript(
      from: chatSession,
      includingTurnID: turnID
    )
    traceTurnPhase(
      .contextBuild,
      startedAt: contextBuildStartedAt,
      turnID: turnID,
      generationID: nil,
      messageCount: transcript.entries.count,
      interactionMode: chatSession.interactionMode
    )

    let systemPromptStartedAt = Date()
    let renderedSystemPrompt = systemPrompt(toolPromptMode: toolPromptMode)
    traceTurnPhase(
      .renderSystemPrompt,
      startedAt: systemPromptStartedAt,
      turnID: turnID,
      generationID: nil,
      promptBytes: renderedSystemPrompt.utf8.count,
      messageCount: transcript.entries.count,
      interactionMode: chatSession.interactionMode
    )

    return ContextUsageSnapshot(
      modelState: modelRuntime.modelState,
      operationID: modelRuntime.currentOperationID(),
      turnID: turnID,
      transcript: transcript,
      attachments: attachmentsForCurrentTurn(),
      systemPrompt: renderedSystemPrompt,
      contextTokenLimit: modelRuntime.modelContextTokenLimit,
      runtimeIsBusy: isGenerating || pendingRuntimeContextClear != nil,
      interactionMode: chatSession.interactionMode
    )
  }

  private func handleContextUsageEvent(_ event: ContextUsageEvent) {
    switch event {
    case .reset, .failed:
      contextUsage = nil
    case .updated(let usage):
      contextUsage = usage
    case .error(let message):
      errorMessage = message
    }
  }

  public func addAttachments(from urls: [URL]) {
    attachmentCoordinator.addAttachments(
      from: urls,
      existingAttachments: chatSession.pendingAttachments,
      onEvent: handleAttachmentEvent(_:))
  }

  public func convertDroppedFilePathsInDraft() {
    attachmentCoordinator.convertDroppedFilePaths(
      in: draft,
      isGenerating: isGenerating,
      existingAttachments: chatSession.pendingAttachments,
      onEvent: handleAttachmentEvent(_:))
  }

  public func removeAttachment(id: ChatAttachment.ID) {
    attachmentCoordinator.removeAttachment(id: id, onEvent: handleAttachmentEvent(_:))
  }

  private func handleAttachmentEvent(_ event: ChatAttachmentEvent) {
    switch event {
    case .appendAttachments(let attachments):
      chatSession.pendingAttachments.append(contentsOf: attachments)
      errorMessage = nil
      refreshContextUsage()
    case .replaceDraft(let cleanedDraft):
      draft = cleanedDraft
    case .removeAttachment(let id):
      chatSession.pendingAttachments.removeAll { $0.id == id }
      chatSession.activeAttachmentContext.remove(id)
      chatSession.focusedFileState.focusedAttachments =
        chatSession.activeAttachmentContext.attachmentIDs
      refreshContextUsage()
    case .error(let message):
      errorMessage = message
    }
  }

  public var activeAttachmentContextAttachments: [ChatAttachment] {
    []
  }

  private func notifySessionDidChange() {
    onSessionDidChange?()
  }

  private func traceTurnPhase(
    _ phase: TurnTracePhase,
    startedAt: Date,
    turnID: ChatTurn.ID?,
    generationID: UUID?,
    promptBytes: Int? = nil,
    promptTokens: Int? = nil,
    messageCount: Int? = nil,
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

  private func isCurrentTurn(_ turnID: ChatTurn.ID) -> Bool {
    chatTurnCoordinator.isActive(turnID)
  }

  private func markTurnCancelled(_ turnID: ChatTurn.ID) {
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .cancelled,
        modelContextPolicy: .excluded
      ),
      .streamingAssistantMessagesCancelled(turnID: turnID),
      .transientAssistantPlaceholdersRemoved,
    ])
  }

  public func approveToolCall(id toolCallID: ToolCallRecord.ID, in workspace: Workspace) {
    guard !isGenerating else {
      return
    }
    guard let existingRecord = chatSession.toolCalls.first(where: { $0.id == toolCallID }) else {
      return
    }
    guard existingRecord.status == .awaitingApproval else {
      return
    }
    guard let turnID = chatSession.turnID(containingToolCall: toolCallID)
    else {
      return
    }

    isGenerating = true
    errorMessage = nil
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      )
    ])
    notifySessionDidChange()

    chatTurnCoordinator.startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }
      await runApprovedToolCall(existingRecord, in: workspace, turnID: turnID)
    }
  }

  private func runApprovedToolCall(
    _ existingRecord: ToolCallRecord,
    in workspace: Workspace,
    turnID: ChatTurn.ID
  ) async {
    do {
      let approvedRecord = await toolOrchestrator.executeApproved(
        request: existingRecord.request,
        workspace: workspace
      )
      guard isCurrentTurn(turnID) else {
        return
      }

      let mergedRecord = mergedToolCallRecord(existing: existingRecord, updated: approvedRecord)
      var events = approvedToolCompletionEvents(
        record: mergedRecord,
        focusedFileState: chatSession.focusedFileState,
        turnID: turnID
      )

      guard mergedRecord.status == .completed else {
        applyWorkflowEvents(events)
        finishApprovedToolFailure(turnID)
        return
      }

      let nextAssistantMessageID = UUID()
      events.append(
        .assistantPlaceholderAppended(
          messageID: nextAssistantMessageID,
          turnID: turnID
        )
      )
      applyWorkflowEvents(events)
      notifySessionDidChange()
      let promptMode = followUpPromptMode(afterApprovedTool: mergedRecord.request.toolName)
      appendFinalToolFollowUpBoundaryIfNeeded(
        toolPromptMode: promptMode,
        turnID: turnID
      )
      let generationResult = try await streamAssistantReply(
        to: nextAssistantMessageID,
        interactionMode: chatSession.interactionMode,
        toolPromptMode: promptMode,
        turnID: turnID,
        toolLoopIteration: 1
      )
      if isFinalApprovedToolFollowUp(mergedRecord.request.toolName) {
        try await recordFinalModeToolAttemptIfNeeded(
          workspaceID: workspace.id,
          sessionID: existingRecord.request.sessionID,
          assistantMessageID: nextAssistantMessageID,
          turnID: turnID,
          interactionMode: chatSession.interactionMode
        )
      } else {
        try await runToolLoop(
          workspace: workspace,
          sessionID: existingRecord.request.sessionID,
          lastAssistantMessageID: nextAssistantMessageID,
          turnID: turnID,
          interactionMode: chatSession.interactionMode,
          remainingIterations: maxToolLoopIterations - 1,
          lastNativeToolCalls: generationResult.nativeToolCalls
        )
      }
    } catch is CancellationError {
      finishCancelledApprovedToolTurn(turnID)
      return
    } catch {
      finishFailedApprovedToolTurn(turnID, error: error)
      return
    }

    finishCompletedApprovedToolTurn(turnID)
  }

  private func approvedToolCompletionEvents(
    record: ToolCallRecord,
    focusedFileState: FocusedFileState,
    turnID: ChatTurn.ID
  ) -> [ChatWorkflowEvent] {
    var events: [ChatWorkflowEvent] = [
      .toolCallReplaced(record),
      .toolResultAppended(
        toolResultMessage(for: record),
        turnID: turnID
      ),
    ]
    events.append(contentsOf: focusEventsForToolRecord(record, from: focusedFileState))
    return events
  }

  private func toolResultMessage(for record: ToolCallRecord) -> ToolResultModelMessage {
    return ToolResultModelMessage(
      callID: record.id,
      toolName: record.request.toolName,
      payload: record.resultPayload
        ?? .failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: nil,
            reason: .executionError(
              "Tool result unavailable for \(record.request.toolName.rawValue)."
            )
          ))
    )
  }

  private func finishApprovedToolFailure(_ turnID: ChatTurn.ID) {
    guard isCurrentTurn(turnID) else {
      return
    }
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .failed,
        modelContextPolicy: .excluded
      )
    ])
    isGenerating = false
    chatTurnCoordinator.finishTurn(turnID)
    flushPendingContextUsageRefresh(defaultMode: .disabled)
    notifySessionDidChange()
  }

  private func finishCancelledApprovedToolTurn(_ turnID: ChatTurn.ID) {
    guard isCurrentTurn(turnID) else {
      return
    }
    markTurnCancelled(turnID)
    isGenerating = false
    chatTurnCoordinator.finishTurn(turnID)
    flushPendingContextUsageRefresh(defaultMode: .disabled)
    notifySessionDidChange()
  }

  private func finishFailedApprovedToolTurn(_ turnID: ChatTurn.ID, error: Error) {
    guard isCurrentTurn(turnID) else {
      return
    }
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .failed,
        modelContextPolicy: .excluded
      ),
      .streamingAssistantMessagesCancelled(turnID: turnID),
      .transientAssistantPlaceholdersRemoved,
    ])
    errorMessage = error.localizedDescription
    isGenerating = false
    chatTurnCoordinator.finishTurn(turnID)
    flushPendingContextUsageRefresh(defaultMode: .disabled)
    notifySessionDidChange()
  }

  private func finishCompletedApprovedToolTurn(_ turnID: ChatTurn.ID) {
    guard isCurrentTurn(turnID) else {
      return
    }
    applyWorkflowEvents([
      .turnStatusChanged(
        turnID: turnID,
        status: .completed,
        modelContextPolicy: nil
      )
    ])
    isGenerating = false
    chatTurnCoordinator.finishTurn(turnID)
    flushPendingContextUsageRefresh(defaultMode: .disabled)
    notifySessionDidChange()
  }

  public func answerAskUserToolCall(
    id toolCallID: ToolCallRecord.ID,
    answer rawAnswer: String,
    in workspace: Workspace
  ) {
    guard !isGenerating else {
      return
    }
    guard let existingRecord = chatSession.toolCalls.first(where: { $0.id == toolCallID }) else {
      return
    }
    guard existingRecord.status == .awaitingUserAnswer else {
      return
    }
    guard let turnID = chatSession.turnID(containingToolCall: toolCallID) else {
      return
    }
    guard case .askUser(let input) = existingRecord.request.payload else {
      return
    }

    let answer = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else {
      return
    }
    if !input.options.contains(answer) {
      errorMessage = "Choose one of the provided answers."
      return
    }

    var answeredRecord = existingRecord
    answeredRecord.state = .completed(.askUser(AskUserResult(answer: answer)))
    answeredRecord.events.append(
      ToolCallEvent(actor: .user, kind: .answered, message: "Answered: \(answer)"))
    let nextAssistantMessageID = UUID()
    applyWorkflowEvents([
      .toolCallReplaced(answeredRecord),
      .toolResultAppended(
        toolResultMessage(for: answeredRecord),
        turnID: turnID
      ),
      .assistantPlaceholderAppended(messageID: nextAssistantMessageID, turnID: turnID),
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      ),
    ])
    isGenerating = true
    errorMessage = nil
    refreshContextUsage(toolPromptMode: .afterToolResultCanContinue)
    notifySessionDidChange()

    chatTurnCoordinator.startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }
      do {
        let generationResult = try await streamAssistantReply(
          to: nextAssistantMessageID,
          interactionMode: chatSession.interactionMode,
          toolPromptMode: .afterToolResultCanContinue,
          turnID: turnID,
          toolLoopIteration: 1
        )
        try await runToolLoop(
          workspace: workspace,
          sessionID: existingRecord.request.sessionID,
          lastAssistantMessageID: nextAssistantMessageID,
          turnID: turnID,
          interactionMode: chatSession.interactionMode,
          remainingIterations: maxToolLoopIterations - 1,
          lastNativeToolCalls: generationResult.nativeToolCalls
        )
      } catch is CancellationError {
        finishCancelledApprovedToolTurn(turnID)
        return
      } catch {
        finishFailedApprovedToolTurn(turnID, error: error)
        return
      }

      finishCompletedApprovedToolTurn(turnID)
    }
  }

  public func denyToolCall(id toolCallID: ToolCallRecord.ID) {
    guard !isGenerating else {
      return
    }
    guard let existingRecord = chatSession.toolCalls.first(where: { $0.id == toolCallID }) else {
      return
    }
    guard existingRecord.status == .awaitingApproval else {
      return
    }
    guard let turnID = chatSession.turnID(containingToolCall: toolCallID)
    else {
      return
    }

    let message = "Tool call denied by user."
    var deniedRecord = existingRecord
    deniedRecord.state = .denied(
      .failure(
        ToolFailure(
          toolName: deniedRecord.request.toolName,
          path: deniedRecord.evaluation.firstModelFacingPath,
          reason: .permissionDenied,
          recovery: .askUser(message: message)
        ))
    )
    deniedRecord.events.append(ToolCallEvent(actor: .user, kind: .denied, message: message))
    let nextAssistantMessageID = UUID()
    applyWorkflowEvents([
      .toolCallReplaced(deniedRecord),
      .toolResultAppended(
        deniedToolResultMessage(for: deniedRecord, message: message),
        turnID: turnID
      ),
      .assistantPlaceholderAppended(messageID: nextAssistantMessageID, turnID: turnID),
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      ),
    ])
    isGenerating = true
    errorMessage = nil
    appendFinalToolFollowUpBoundaryIfNeeded(
      toolPromptMode: .afterToolResultFinal,
      turnID: turnID
    )
    refreshContextUsage(toolPromptMode: .afterToolResultFinal)
    notifySessionDidChange()

    chatTurnCoordinator.startTurn(id: turnID) { [weak self] turnID in
      guard let self else {
        return
      }
      do {
        _ = try await streamAssistantReply(
          to: nextAssistantMessageID,
          interactionMode: chatSession.interactionMode,
          toolPromptMode: .afterToolResultFinal,
          turnID: turnID,
          toolLoopIteration: 1
        )
        try await recordFinalModeToolAttemptIfNeeded(
          workspaceID: deniedRecord.request.workspaceID,
          sessionID: deniedRecord.request.sessionID,
          assistantMessageID: nextAssistantMessageID,
          turnID: turnID,
          interactionMode: chatSession.interactionMode
        )
      } catch is CancellationError {
        finishCancelledApprovedToolTurn(turnID)
        return
      } catch {
        finishFailedApprovedToolTurn(turnID, error: error)
        return
      }

      finishCompletedApprovedToolTurn(turnID)
    }
  }

  private func applyWorkflowEvents(_ events: [ChatWorkflowEvent]) {
    workflowEventApplier.apply(events, to: &chatSession)
  }

  private func focusEventsForToolRecord(
    _ record: ToolCallRecord,
    from focusedFileState: FocusedFileState
  ) -> [ChatWorkflowEvent] {
    let updatedState = focusedFileReducer.applyingToolResult(
      record.resultPayload,
      request: record.request,
      to: focusedFileState
    )
    guard updatedState != focusedFileState else {
      return []
    }
    return [.focusedFileStateChanged(updatedState)]
  }

  private func focusEventsForAttachments(
    _ attachments: [ChatAttachment],
    workspace: Workspace?
  ) -> [ChatWorkflowEvent] {
    let updatedState = focusedFileReducer.applyingAttachments(
      attachments,
      workspace: workspace,
      to: chatSession.focusedFileState
    )
    guard updatedState != chatSession.focusedFileState else {
      return []
    }
    return [.focusedFileStateChanged(updatedState)]
  }

  private func attachmentsForCurrentTurn() -> [ChatAttachment] {
    uniqueAttachments(chatSession.pendingAttachments)
  }

  private func uniqueAttachments(_ attachments: [ChatAttachment]) -> [ChatAttachment] {
    var seen: Set<AttachmentID> = []
    var unique: [ChatAttachment] = []
    for attachment in attachments where !seen.contains(attachment.id) {
      seen.insert(attachment.id)
      unique.append(attachment)
    }
    return unique
  }

  private func deniedToolResultMessage(
    for deniedRecord: ToolCallRecord,
    message: String
  ) -> ToolResultModelMessage {
    ToolResultModelMessage(
      callID: deniedRecord.id,
      toolName: deniedRecord.request.toolName,
      payload: deniedRecord.resultPayload
        ?? .failure(
          ToolFailure(
            toolName: deniedRecord.request.toolName,
            path: deniedRecord.evaluation.firstModelFacingPath,
            reason: .permissionDenied,
            recovery: .askUser(message: message)
          ))
    )
  }

  private func mergedToolCallRecord(
    existing: ToolCallRecord,
    updated: ToolCallRecord
  ) -> ToolCallRecord {
    var merged = updated
    if merged.turnID == nil {
      merged.turnID = existing.turnID
    }
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

  private func followUpPromptMode(afterApprovedTool toolName: ToolName) -> ToolPromptMode {
    isFinalApprovedToolFollowUp(toolName) ? .afterToolResultFinal : .afterToolResultCanContinue
  }

  private func isFinalApprovedToolFollowUp(_ toolName: ToolName) -> Bool {
    toolName == .writeFile || toolName == .editFile
  }

  private func appendFinalToolFollowUpBoundaryIfNeeded(
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurn.ID
  ) {
    guard toolPromptMode == .afterToolResultFinal else {
      return
    }

    transcriptMutator.appendFinalToolResultFollowUpBoundary(
      "Use the preceding tool result to answer the user's request.",
      turnID: turnID,
      systemPromptSnapshot: systemPrompt(toolPromptMode: toolPromptMode),
      to: &chatSession
    )
  }

}

extension ChatSessionController {
  fileprivate func streamAssistantReply(
    to assistantMessageID: UUID,
    interactionMode: WorkspaceInteractionMode,
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurn.ID,
    toolLoopIteration: Int? = nil,
    attachments: [ChatAttachment] = []
  )
    async throws
    -> ChatGenerationResult
  {
    let toolCallingPolicy = modelRuntime.selectedModel.toolCallingPolicy
    let systemPromptStartedAt = Date()
    let renderedSystemPrompt = systemPrompt(toolPromptMode: toolPromptMode)
    transcriptMutator.updateLastUserModelContextSystemPromptSnapshot(
      renderedSystemPrompt,
      turnID: turnID,
      in: &chatSession
    )
    traceTurnPhase(
      .renderSystemPrompt,
      startedAt: systemPromptStartedAt,
      turnID: turnID,
      generationID: nil,
      promptBytes: renderedSystemPrompt.utf8.count,
      messageCount: chatSession.modelContextSnapshot.entries.count,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode
    )
    let contextBuildStartedAt = Date()
    let modelContextSnapshot = modelContextBuilder.transcript(
      from: chatSession,
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
      operationID: modelRuntime.currentOperationID(),
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode,
      transcript: modelContextSnapshot,
      attachments: attachments,
      systemPrompt: renderedSystemPrompt,
      settings: chatSession.generationSettings,
      stopAfterCompleteToolAction: toolPromptMode.shouldStopAfterCompleteToolAction(
        strategy: toolCallingPolicy.strategy),
      toolContext: runtimeToolContext(
        for: toolPromptMode,
        policy: toolCallingPolicy
      ),
      appendChunk: { chunk in
        guard isCurrentTurn(turnID) else {
          return
        }
        transcriptMutator.appendChunk(chunk, to: assistantMessageID, in: &chatSession)
      },
      updateGenerationMetrics: { metrics in
        guard isCurrentTurn(turnID) else {
          return
        }
        transcriptMutator.updateGenerationMetrics(
          metrics, for: assistantMessageID, in: &chatSession)
        transcriptMutator.updateDeliveryStatus(.complete, for: assistantMessageID, in: &chatSession)
      },
      updateContextUsage: {
        await MainActor.run {}
      }
    )
    guard isCurrentTurn(turnID) else {
      return ChatGenerationResult(assistantContent: "")
    }
    if !generationResult.assistantContent.isEmpty {
      if let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: assistantMessageID,
        content: generationResult.assistantContent
      ) {
        transcriptMutator.appendModelContextEntry(entry, to: &chatSession)
      }
    }
    refreshContextUsage(toolPromptMode: toolPromptMode)
    return generationResult
  }

  fileprivate func runToolLoop(
    workspace: Workspace?,
    sessionID: ChatSession.ID?,
    lastAssistantMessageID: UUID,
    turnID: ChatTurn.ID,
    interactionMode: WorkspaceInteractionMode,
    remainingIterations initialRemainingIterations: Int? = nil,
    lastNativeToolCalls: [ChatRuntimeToolCall] = []
  ) async throws {
    guard interactionMode.allowsToolLoop, let workspace, let sessionID else {
      return
    }

    var currentAssistantMessageID = lastAssistantMessageID
    var currentNativeToolCalls = lastNativeToolCalls
    var remainingIterations = initialRemainingIterations ?? maxToolLoopIterations
    let toolCallingPolicy = modelRuntime.selectedModel.toolCallingPolicy

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
            items: chatSession.turns.flatMap(\.items),
            focusedFileState: chatSession.focusedFileState,
            interactionMode: interactionMode,
            followUpPromptMode: followUpPromptMode,
            toolLoopIteration: toolLoopIteration,
            toolCallingPolicy: toolCallingPolicy,
            nativeToolCalls: currentNativeToolCalls
          )
        )
      else {
        return
      }
      currentNativeToolCalls = []
      remainingIterations -= 1
      try Task.checkCancellation()
      guard isCurrentTurn(turnID) else {
        return
      }

      applyWorkflowEvents(step.events)
      notifySessionDidChange()

      switch step.continuation {
      case .awaitingApproval:
        isGenerating = false
        chatTurnCoordinator.finishTurn(turnID)
        flushPendingContextUsageRefresh(defaultMode: .disabled)
        notifySessionDidChange()
        return
      case .awaitingUserAnswer:
        isGenerating = false
        chatTurnCoordinator.finishTurn(turnID)
        flushPendingContextUsageRefresh(defaultMode: .disabled)
        notifySessionDidChange()
        return
      case .resumeGeneration(let nextAssistantMessageID, let promptMode):
        let generationResult = try await streamAssistantReply(
          to: nextAssistantMessageID,
          interactionMode: interactionMode,
          toolPromptMode: promptMode,
          turnID: turnID,
          toolLoopIteration: toolLoopIteration
        )
        currentNativeToolCalls = generationResult.nativeToolCalls
        guard promptMode != .afterToolResultFinal else {
          try await recordFinalModeToolAttemptIfNeeded(
            workspaceID: workspace.id,
            sessionID: sessionID,
            assistantMessageID: nextAssistantMessageID,
            turnID: turnID,
            interactionMode: interactionMode,
            reason: finalActionDetectionReason(remainingIterations: remainingIterations)
          )
          return
        }
        currentAssistantMessageID = nextAssistantMessageID
      case .none, .stopTurn:
        return
      }
    }

    try await recordFinalModeToolAttemptIfNeeded(
      workspaceID: workspace.id,
      sessionID: sessionID,
      assistantMessageID: currentAssistantMessageID,
      turnID: turnID,
      interactionMode: interactionMode,
      reason: .toolBudgetExceeded(iterationLimit: maxToolLoopIterations)
    )
  }

  private func recordFinalModeToolAttemptIfNeeded(
    workspaceID: Workspace.ID?,
    sessionID: ChatSession.ID,
    assistantMessageID: UUID,
    turnID: ChatTurn.ID,
    interactionMode: WorkspaceInteractionMode,
    reason: FinalModeActionDetectionReason = .finalMode
  ) async throws {
    guard isCurrentTurn(turnID) else {
      return
    }
    guard
      let step = try await finalModeActionDetector.detect(
        FinalModeActionDetectionRequest(
          workspaceID: workspaceID,
          sessionID: sessionID,
          turnID: turnID,
          assistantMessageID: assistantMessageID,
          items: chatSession.turns.flatMap(\.items),
          interactionMode: interactionMode,
          reason: reason,
          toolLoopIteration: maxToolLoopIterations + 1
        )
      )
    else {
      return
    }
    applyWorkflowEvents(step.events)
    notifySessionDidChange()
  }

  private func finalActionDetectionReason(
    remainingIterations: Int
  ) -> FinalModeActionDetectionReason {
    remainingIterations == 0
      ? .toolBudgetExceeded(iterationLimit: maxToolLoopIterations)
      : .finalMode
  }

  fileprivate func systemPrompt(toolPromptMode: ToolPromptMode) -> String {
    let renderedPrompt = toolPromptPolicy.systemPrompt(
      basePrompt: chatSession.systemPrompt,
      mode: toolPromptMode,
      toolRegistry: toolRegistry(for: toolPromptMode),
      toolPromptRenderer: toolPromptRenderer,
      toolCallingPolicy: modelRuntime.selectedModel.toolCallingPolicy
    )
    guard chatSession.interactionMode == .agent,
      let planBlock = TodoPromptRenderer.compactPlanBlock(for: chatSession.todoState)
    else {
      return renderedPrompt
    }
    return [renderedPrompt, planBlock].joined(separator: "\n\n")
  }

  fileprivate func runtimeToolContext(
    for toolPromptMode: ToolPromptMode,
    policy: ToolCallingPolicy
  ) -> ChatRuntimeToolContext? {
    guard policy.strategy == .nativeGemma4 else {
      return nil
    }
    let registry = toolRegistry(for: toolPromptMode)
    guard !registry.tools.isEmpty else {
      return nil
    }
    return ChatRuntimeToolContext(strategy: policy.strategy, registry: registry)
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

  private func toolRegistry(for toolPromptMode: ToolPromptMode) -> ToolRegistry {
    switch toolPromptMode {
    case .inspect, .afterInspectToolResultCanContinue:
      return ToolExecutorRegistry.readOnly.toolRegistry
    case .enabled(true), .afterToolResultCanContinue:
      return ToolExecutorRegistry.codingAgent.toolRegistry
    case .disabled, .enabled(false), .afterToolResultFinal:
      return ToolRegistry(tools: [])
    }
  }

  private func disableUnsupportedInteractionModeIfNeeded() {
    let selectedModel = modelRuntime.selectedModel
    guard !selectedModel.supports(interactionMode: chatSession.interactionMode) else {
      return
    }

    chatSession.interactionMode = .chat
    errorMessage = unsupportedInteractionModeMessage(for: selectedModel)
  }

  private func unsupportedInteractionModeMessage(for model: ManagedModel) -> String {
    "\(model.displayName) supports plain chat only. Select a model with workspace tool support to use Agent tools."
  }

  private func unsupportedImageInputMessage(for model: ManagedModel) -> String {
    "\(model.displayName) cannot analyze images. Select a Gemma 4 vision-capable model or remove the image attachment."
  }
}

extension ManagedModel {
  fileprivate func supports(interactionMode: WorkspaceInteractionMode) -> Bool {
    interactionMode == .chat || supportsWorkspaceTools
  }
}

extension Array where Element == ChatAttachment {
  fileprivate var hasImages: Bool {
    contains { $0.kind == .image }
  }
}

extension ToolPromptMode {
  fileprivate func shouldStopAfterCompleteToolAction(strategy: ToolCallingStrategy) -> Bool {
    guard strategy == .taggedAction else {
      return false
    }
    switch self {
    case .enabled(true), .inspect, .afterInspectToolResultCanContinue,
      .afterToolResultCanContinue:
      return true
    case .disabled, .enabled(false), .afterToolResultFinal:
      return false
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
