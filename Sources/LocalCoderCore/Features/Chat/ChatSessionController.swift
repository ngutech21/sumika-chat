import Foundation
import Observation

@MainActor
@Observable
public final class ChatSessionController {
  public var chatSession = ChatSessionState.codingDefault
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
  @ObservationIgnored private let chatTurnCoordinator = ChatTurnCoordinator()
  @ObservationIgnored private let modelContextBuilder = ChatModelContextBuilder()
  @ObservationIgnored private let attachmentCoordinator: ChatAttachmentCoordinator
  @ObservationIgnored private let transcriptMutator = ChatTranscriptMutator()
  @ObservationIgnored private let workflowEventApplier = ChatWorkflowEventApplier()
  @ObservationIgnored private let focusedFileReducer = FocusedFileStateReducer()
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private let streamingFlushInterval: TimeInterval = 0.05
  @ObservationIgnored private let streamingFlushCharacterLimit = 240
  @ObservationIgnored private let maxToolLoopIterations = 6

  public var canSend: Bool {
    modelRuntime.modelState == .ready
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
      && !hasPendingApproval
  }

  public var hasPendingApproval: Bool {
    chatSession.toolCalls.contains { $0.status == .awaitingApproval }
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
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader()
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
      chatSession: ChatSessionState(
        messages: [],
        toolCalls: [],
        attachments: [],
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
      chatAttachmentLoader: chatAttachmentLoader
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
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader()
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
      chatAttachmentLoader: chatAttachmentLoader
    )
  }

  private init(
    selectedModelID: ManagedModel.ID,
    modelPath: String,
    modelContextTokenLimit: Int,
    chatSession: ChatSessionState,
    modelSettingsStore: any ModelSettingsStoring,
    modelDownloader: any ModelDownloading,
    runtime: any ChatModelRuntime,
    resourceMonitor: any ProcessResourceMonitoring,
    toolCallParser: any ToolCallParsing,
    toolPromptRenderer: any ToolPromptRendering,
    toolOrchestrator: ToolOrchestrator,
    chatAttachmentLoader: any ChatAttachmentLoading
  ) {
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
      modelLifecycleCoordinator: modelLifecycleCoordinator)
    self.chatGenerationCoordinator = ChatGenerationCoordinator(
      runtime: runtime,
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
      toolOrchestrator: toolOrchestrator
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

  public func loadSession(_ session: CodingSession) {
    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel

    cancelGeneration(notify: false)
    let didResetRuntime = modelRuntime.applySessionModel(model)
    errorMessage = nil
    contextUsage = nil
    chatSession = ChatSessionState(
      messages: session.messages,
      toolCalls: session.toolCalls,
      turns: session.turns,
      attachments: [],
      focusedFileState: session.focusedFileState,
      systemPrompt: session.systemPrompt,
      generationSettings: session.generationSettings
    )

    if didResetRuntime {
      invalidateContextUsage()
    } else {
      refreshContextUsage()
    }
  }

  public func sessionSnapshot(updating session: CodingSession) -> CodingSession {
    var snapshot = session
    snapshot.selectedModelID = modelRuntime.selectedModelID
    snapshot.messages = chatSession.messages
    snapshot.toolCalls = chatSession.toolCalls
    snapshot.turns = chatSession.turns
    snapshot.focusedFileState = chatSession.focusedFileState
    snapshot.systemPrompt = chatSession.systemPrompt
    snapshot.generationSettings = chatSession.generationSettings
    snapshot.updatedAt = Date()
    return snapshot
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

  public func sendMessage(in workspace: Workspace, sessionID: CodingSession.ID) {
    sendMessage(workspace: workspace, sessionID: sessionID)
  }

  public func sendMessage(in workspace: Workspace) {
    sendMessage(workspace: workspace, sessionID: workspace.sessions.first?.id)
  }

  private func sendMessage(workspace: Workspace?, sessionID: CodingSession.ID?) {
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend else { return }

    let sentAttachments = chatSession.attachments
    let turnID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()
    draft = ""
    errorMessage = nil
    chatSession.attachments.removeAll()
    applyWorkflowEvents(focusEventsForAttachments(sentAttachments, workspace: workspace))
    transcriptMutator.appendTurn(
      ChatTurnRecord(
        id: turnID,
        status: .running,
        messageIDs: [userMessageID, assistantMessageID]
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
        let toolAvailability = toolPromptPolicy.toolAvailability(
          workspace: workspace,
          sessionID: sessionID
        )
        let toolsAvailable = toolAvailability == .availableForWorkspace
        refreshContextUsage(toolPromptMode: .enabled(toolsAvailable))
        try await streamAssistantReply(
          to: assistantMessageID,
          toolPromptMode: .enabled(toolsAvailable),
          turnID: turnID
        )
        guard isCurrentTurn(turnID) else {
          return
        }
        if toolsAvailable {
          try await runToolLoop(
            workspace: workspace,
            sessionID: sessionID,
            lastAssistantMessageID: assistantMessageID,
            turnID: turnID
          )
        }
      } catch is CancellationError {
        guard isCurrentTurn(turnID) else {
          return
        }
        markTurnCancelled(turnID)
        isGenerating = false
        chatTurnCoordinator.finishTurn(turnID)
        refreshContextUsage()
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
        refreshContextUsage()
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
    refreshContextUsage()
    if notify {
      notifySessionDidChange()
    }
  }

  public func clearChatHistory() {
    transcriptMutator.clearTranscript(in: &chatSession)
    invalidateContextUsage()
    notifySessionDidChange()

    contextUsageCoordinator.clearRuntimeContext(
      operationID: modelRuntime.currentOperationID(),
      snapshot: contextUsageSnapshot(),
      onEvent: handleContextUsageEvent(_:))
  }

  public func refreshContextUsage(toolPromptMode: ToolPromptMode = .disabled) {
    contextUsageCoordinator.refresh(
      snapshot: contextUsageSnapshot(toolPromptMode: toolPromptMode),
      onEvent: handleContextUsageEvent(_:))
  }

  public func updateContextUsage() async {
    await contextUsageCoordinator.refreshNow(
      snapshot: contextUsageSnapshot(),
      onEvent: handleContextUsageEvent(_:))
  }

  private func invalidateContextUsage() {
    contextUsageCoordinator.invalidate(onEvent: handleContextUsageEvent(_:))
  }

  private func contextUsageSnapshot(toolPromptMode: ToolPromptMode = .disabled)
    -> ContextUsageSnapshot
  {
    ContextUsageSnapshot(
      modelState: modelRuntime.modelState,
      operationID: modelRuntime.currentOperationID(),
      messages: modelContextBuilder.messages(
        from: chatSession,
        includingTurnID: chatTurnCoordinator.activeTurnID
      ),
      attachments: chatSession.attachments,
      systemPrompt: systemPrompt(toolPromptMode: toolPromptMode)
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
      existingAttachments: chatSession.attachments,
      onEvent: handleAttachmentEvent(_:))
  }

  public func convertDroppedFilePathsInDraft() {
    attachmentCoordinator.convertDroppedFilePaths(
      in: draft,
      isGenerating: isGenerating,
      existingAttachments: chatSession.attachments,
      onEvent: handleAttachmentEvent(_:))
  }

  public func removeAttachment(id: ChatAttachment.ID) {
    attachmentCoordinator.removeAttachment(id: id, onEvent: handleAttachmentEvent(_:))
  }

  private func handleAttachmentEvent(_ event: ChatAttachmentEvent) {
    switch event {
    case .appendAttachments(let attachments):
      chatSession.attachments.append(contentsOf: attachments)
      errorMessage = nil
      refreshContextUsage()
    case .replaceDraft(let cleanedDraft):
      draft = cleanedDraft
    case .removeAttachment(let id):
      chatSession.attachments.removeAll { $0.id == id }
      refreshContextUsage()
    case .error(let message):
      errorMessage = message
    }
  }

  private func notifySessionDidChange() {
    onSessionDidChange?()
  }

  private func isCurrentTurn(_ turnID: ChatTurnRecord.ID) -> Bool {
    chatTurnCoordinator.isActive(turnID)
  }

  private func markTurnCancelled(_ turnID: ChatTurnRecord.ID) {
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
    guard let turnID = chatSession.turns.first(where: { $0.toolCallIDs.contains(toolCallID) })?.id
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
    turnID: ChatTurnRecord.ID
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

      guard !Self.completesApprovedTurnWithoutFollowUp(mergedRecord.request.toolName) else {
        applyWorkflowEvents(events)
        finishCompletedApprovedToolTurn(turnID)
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
      try await streamAssistantReply(
        to: nextAssistantMessageID,
        toolPromptMode: .afterToolResultCanContinue,
        turnID: turnID
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

  private func approvedToolCompletionEvents(
    record: ToolCallRecord,
    focusedFileState: FocusedFileState,
    turnID: ChatTurnRecord.ID
  ) -> [ChatWorkflowEvent] {
    var events: [ChatWorkflowEvent] = [
      .toolCallReplaced(record),
      .toolResultAppended(
        toolResultMessage(for: record),
        messageID: UUID(),
        turnID: turnID
      ),
    ]
    events.append(contentsOf: focusEventsForToolRecord(record, from: focusedFileState))
    return events
  }

  private func toolResultMessage(for record: ToolCallRecord) -> ToolResultModelMessage {
    let resultPreview =
      record.resultPreview
      ?? ToolResultPreview(
        status: .failed,
        text: "Tool result unavailable for \(record.request.toolName.rawValue)."
      )
    return ToolResultModelMessage(
      callID: record.id,
      toolName: record.request.toolName,
      payload: record.resultPayload,
      preview: resultPreview
    )
  }

  private func finishApprovedToolFailure(_ turnID: ChatTurnRecord.ID) {
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
    refreshContextUsage()
    notifySessionDidChange()
  }

  private func finishCancelledApprovedToolTurn(_ turnID: ChatTurnRecord.ID) {
    guard isCurrentTurn(turnID) else {
      return
    }
    markTurnCancelled(turnID)
    isGenerating = false
    chatTurnCoordinator.finishTurn(turnID)
    refreshContextUsage()
    notifySessionDidChange()
  }

  private func finishFailedApprovedToolTurn(_ turnID: ChatTurnRecord.ID, error: Error) {
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
    refreshContextUsage()
    notifySessionDidChange()
  }

  private func finishCompletedApprovedToolTurn(_ turnID: ChatTurnRecord.ID) {
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
    refreshContextUsage()
    notifySessionDidChange()
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
    guard let turnID = chatSession.turns.first(where: { $0.toolCallIDs.contains(toolCallID) })?.id
    else {
      return
    }

    let message = "Tool call denied by user."
    var deniedRecord = existingRecord
    deniedRecord.status = .denied
    deniedRecord.resultPayload = .failure(
      ToolFailure(
        toolName: deniedRecord.request.toolName,
        path: deniedRecord.evaluation.firstModelFacingPath,
        reason: .permissionDenied
      )
    )
    deniedRecord.resultPreview = ToolResultPreview(
      status: .denied,
      text: message,
      affectedPaths: existingRecord.evaluation.modelFacingPaths
    )
    deniedRecord.events.append(ToolCallEvent(actor: .user, kind: .denied, message: message))
    applyWorkflowEvents([
      .toolCallReplaced(deniedRecord),
      .toolResultAppended(
        deniedToolResultMessage(for: deniedRecord, message: message),
        messageID: UUID(),
        turnID: turnID
      ),
      .turnStatusChanged(
        turnID: turnID,
        status: .completed,
        modelContextPolicy: nil
      ),
    ])
    refreshContextUsage()
    notifySessionDidChange()
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

  private func deniedToolResultMessage(
    for deniedRecord: ToolCallRecord,
    message: String
  ) -> ToolResultModelMessage {
    ToolResultModelMessage(
      callID: deniedRecord.id,
      toolName: deniedRecord.request.toolName,
      payload: deniedRecord.resultPayload,
      preview: deniedRecord.resultPreview ?? ToolResultPreview(status: .denied, text: message)
    )
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

  private static func completesApprovedTurnWithoutFollowUp(_ toolName: ToolName) -> Bool {
    toolName == .writeFile || toolName == .editFile
  }

}

extension ChatSessionController {
  fileprivate func streamAssistantReply(
    to assistantMessageID: UUID,
    toolPromptMode: ToolPromptMode,
    turnID: ChatTurnRecord.ID
  )
    async throws
  {
    let contextMessages = modelContextBuilder.messages(from: chatSession, includingTurnID: turnID)
    try await chatGenerationCoordinator.streamAssistantReply(
      messages: contextMessages,
      systemPrompt: systemPrompt(toolPromptMode: toolPromptMode),
      settings: chatSession.generationSettings,
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
        refreshContextUsage(toolPromptMode: toolPromptMode)
      }
    )
  }

  fileprivate func runToolLoop(
    workspace: Workspace?,
    sessionID: CodingSession.ID?,
    lastAssistantMessageID: UUID,
    turnID: ChatTurnRecord.ID
  ) async throws {
    guard let workspace, let sessionID else {
      return
    }

    var currentAssistantMessageID = lastAssistantMessageID
    var remainingIterations = maxToolLoopIterations

    while remainingIterations > 0 {
      let followUpPromptMode: ToolPromptMode =
        remainingIterations > 1
        ? .afterToolResultCanContinue
        : .afterToolResultFinal
      guard
        let step = try await toolLoopCoordinator.run(
          ToolLoopRequest(
            workspace: workspace,
            sessionID: sessionID,
            turnID: turnID,
            assistantMessageID: currentAssistantMessageID,
            messages: chatSession.messages,
            focusedFileState: chatSession.focusedFileState,
            followUpPromptMode: followUpPromptMode
          )
        )
      else {
        return
      }
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
        refreshContextUsage()
        notifySessionDidChange()
        return
      case .resumeGeneration(let nextAssistantMessageID, let promptMode):
        try await streamAssistantReply(
          to: nextAssistantMessageID,
          toolPromptMode: promptMode,
          turnID: turnID
        )
        currentAssistantMessageID = nextAssistantMessageID
      case .none, .stopTurn:
        return
      }
    }

    replaceOverBudgetToolMarkup(
      assistantMessageID: currentAssistantMessageID,
      inTurn: turnID
    )
  }

  private func replaceOverBudgetToolMarkup(
    assistantMessageID: ChatMessage.ID,
    inTurn turnID: ChatTurnRecord.ID
  ) {
    guard isCurrentTurn(turnID) else {
      return
    }
    guard
      chatSession.messages.contains(where: { message in
        message.id == assistantMessageID && containsOverBudgetToolAttempt(message)
      })
    else {
      return
    }

    transcriptMutator.replaceAssistantContent(
      "Tool limit reached for this request. Send another message to continue.",
      for: assistantMessageID,
      in: &chatSession
    )
    notifySessionDidChange()
  }

  private func containsOverBudgetToolAttempt(_ message: ChatMessage) -> Bool {
    message.containsStreamingToolCallMarkup
      || (message.kind == .assistant
        && ToolIntentHeuristics.looksLikeNonTaggedToolIntent(message.content))
  }

  fileprivate func systemPrompt(toolPromptMode: ToolPromptMode) -> String {
    toolPromptPolicy.systemPrompt(
      basePrompt: chatSession.systemPrompt,
      mode: toolPromptMode,
      toolRegistry: toolOrchestrator.toolRegistry,
      toolPromptRenderer: toolPromptRenderer
    )
  }
}
