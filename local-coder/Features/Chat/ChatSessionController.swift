import Foundation
import Observation

@MainActor
@Observable
final class ChatSessionController {
  var chatSession = ChatSessionState.codingDefault
  var contextUsage: ChatContextUsage?
  var draft = ""
  var isGenerating = false
  var errorMessage: String?

  let modelRuntime: ModelRuntimeController
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
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private let streamingFlushInterval: TimeInterval = 0.05
  @ObservationIgnored private let streamingFlushCharacterLimit = 240
  @ObservationIgnored private let maxToolLoopIterations = 6

  var canSend: Bool {
    modelRuntime.modelState == .ready
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
      && !hasPendingApproval
  }

  var hasPendingApproval: Bool {
    chatSession.toolCalls.contains { $0.status == .awaitingApproval }
  }

  convenience init() {
    self.init(modelSettingsStore: ModelSettingsStore())
  }

  convenience init(
    modelSettingsStore settingsStore: any ModelSettingsStoring,
    modelDownloader downloader: any ModelDownloading = HuggingFaceModelDownloader(),
    runtime: any ChatModelRuntime = GemmaMLXRuntime(),
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
    modelDownloader: any ModelDownloading = HuggingFaceModelDownloader(),
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

  func setSessionChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
    onSessionDidChange = handler
  }

  func loadSession(_ session: CodingSession) {
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
      systemPrompt: session.systemPrompt,
      generationSettings: session.generationSettings
    )

    if didResetRuntime {
      invalidateContextUsage()
    } else {
      refreshContextUsage()
    }
  }

  func sessionSnapshot(updating session: CodingSession) -> CodingSession {
    var snapshot = session
    snapshot.selectedModelID = modelRuntime.selectedModelID
    snapshot.messages = chatSession.messages
    snapshot.toolCalls = chatSession.toolCalls
    snapshot.turns = chatSession.turns
    snapshot.systemPrompt = chatSession.systemPrompt
    snapshot.generationSettings = chatSession.generationSettings
    snapshot.updatedAt = Date()
    return snapshot
  }

  func prepareForModelRuntimeAction(
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

  func sendMessage() {
    sendMessage(workspace: nil, sessionID: nil)
  }

  func sendMessage(in workspace: Workspace, sessionID: CodingSession.ID) {
    sendMessage(workspace: workspace, sessionID: sessionID)
  }

  func sendMessage(in workspace: Workspace) {
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
        let allowsToolCalls = toolPromptPolicy.shouldAllowToolCalls(
          workspace: workspace,
          prompt: prompt,
          attachments: sentAttachments
        )
        refreshContextUsage()
        try await streamAssistantReply(
          to: assistantMessageID,
          toolPromptMode: .enabled(allowsToolCalls),
          turnID: turnID
        )
        guard isCurrentTurn(turnID) else {
          return
        }
        if allowsToolCalls {
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
        transcriptMutator.updateTurnStatus(
          .failed,
          modelContextPolicy: .excluded,
          for: turnID,
          in: &chatSession
        )
        transcriptMutator.markStreamingAssistantMessagesCancelled(inTurn: turnID, in: &chatSession)
        transcriptMutator.removeTransientAssistantPlaceholders(from: &chatSession)
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
      transcriptMutator.updateTurnStatus(.completed, for: turnID, in: &chatSession)
      isGenerating = false
      chatTurnCoordinator.finishTurn(turnID)
      notifySessionDidChange()
    }
  }

  func cancelGeneration() {
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

  func clearChatHistory() {
    transcriptMutator.clearTranscript(in: &chatSession)
    invalidateContextUsage()
    notifySessionDidChange()

    contextUsageCoordinator.clearRuntimeContext(
      operationID: modelRuntime.currentOperationID(),
      snapshot: contextUsageSnapshot(),
      onEvent: handleContextUsageEvent(_:))
  }

  func refreshContextUsage() {
    contextUsageCoordinator.refresh(
      snapshot: contextUsageSnapshot(),
      onEvent: handleContextUsageEvent(_:))
  }

  func updateContextUsage() async {
    await contextUsageCoordinator.refreshNow(
      snapshot: contextUsageSnapshot(),
      onEvent: handleContextUsageEvent(_:))
  }

  private func invalidateContextUsage() {
    contextUsageCoordinator.invalidate(onEvent: handleContextUsageEvent(_:))
  }

  private func contextUsageSnapshot() -> ContextUsageSnapshot {
    ContextUsageSnapshot(
      modelState: modelRuntime.modelState,
      operationID: modelRuntime.currentOperationID(),
      messages: modelContextBuilder.messages(
        from: chatSession,
        includingTurnID: chatTurnCoordinator.activeTurnID
      ),
      attachments: chatSession.attachments,
      systemPrompt: systemPrompt(toolPromptMode: .disabled)
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

  func addAttachments(from urls: [URL]) {
    attachmentCoordinator.addAttachments(
      from: urls,
      existingAttachments: chatSession.attachments,
      onEvent: handleAttachmentEvent(_:))
  }

  func convertDroppedFilePathsInDraft() {
    attachmentCoordinator.convertDroppedFilePaths(
      in: draft,
      isGenerating: isGenerating,
      existingAttachments: chatSession.attachments,
      onEvent: handleAttachmentEvent(_:))
  }

  func removeAttachment(id: ChatAttachment.ID) {
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
    transcriptMutator.updateTurnStatus(
      .cancelled,
      modelContextPolicy: .excluded,
      for: turnID,
      in: &chatSession
    )
    transcriptMutator.markStreamingAssistantMessagesCancelled(inTurn: turnID, in: &chatSession)
    transcriptMutator.removeTransientAssistantPlaceholders(from: &chatSession)
  }

  func approveToolCall(id toolCallID: ToolCallRecord.ID, in workspace: Workspace) {
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
    transcriptMutator.updateTurnStatus(.running, for: turnID, in: &chatSession)
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
      replaceToolCallRecord(mergedRecord)
      appendToolResult(for: mergedRecord, turnID: turnID)

      guard mergedRecord.status == .completed else {
        finishApprovedToolFailure(turnID)
        return
      }

      guard !Self.completesApprovedTurnWithoutFollowUp(mergedRecord.request.toolName) else {
        finishCompletedApprovedToolTurn(turnID)
        return
      }

      let nextAssistantMessageID = appendFollowUpPlaceholder(turnID: turnID)
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

  private func appendToolResult(for record: ToolCallRecord, turnID: ChatTurnRecord.ID) {
    let resultPreview =
      record.resultPreview
      ?? ToolResultPreview(
        status: .failed,
        text: "Tool result unavailable for \(record.request.toolName.rawValue)."
      )
    let toolResultMessageID = UUID()
    transcriptMutator.appendToolResult(
      ToolResultModelMessage(
        callID: record.id,
        toolName: record.request.toolName,
        preview: resultPreview
      ),
      id: toolResultMessageID,
      turnID: turnID,
      to: &chatSession
    )
    transcriptMutator.appendMessageID(toolResultMessageID, toTurn: turnID, in: &chatSession)
  }

  private func appendFollowUpPlaceholder(turnID: ChatTurnRecord.ID) -> ChatMessage.ID {
    let nextAssistantMessageID = UUID()
    transcriptMutator.appendAssistantPlaceholder(
      id: nextAssistantMessageID,
      turnID: turnID,
      to: &chatSession
    )
    transcriptMutator.appendMessageID(nextAssistantMessageID, toTurn: turnID, in: &chatSession)
    return nextAssistantMessageID
  }

  private func finishApprovedToolFailure(_ turnID: ChatTurnRecord.ID) {
    guard isCurrentTurn(turnID) else {
      return
    }
    transcriptMutator.updateTurnStatus(
      .failed,
      modelContextPolicy: .excluded,
      for: turnID,
      in: &chatSession
    )
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
    transcriptMutator.updateTurnStatus(
      .failed,
      modelContextPolicy: .excluded,
      for: turnID,
      in: &chatSession
    )
    transcriptMutator.markStreamingAssistantMessagesCancelled(inTurn: turnID, in: &chatSession)
    transcriptMutator.removeTransientAssistantPlaceholders(from: &chatSession)
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
    transcriptMutator.updateTurnStatus(.completed, for: turnID, in: &chatSession)
    isGenerating = false
    chatTurnCoordinator.finishTurn(turnID)
    refreshContextUsage()
    notifySessionDidChange()
  }

  func denyToolCall(id toolCallID: ToolCallRecord.ID) {
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
    deniedRecord.resultPreview = ToolResultPreview(
      status: .denied,
      text: message,
      affectedPaths: existingRecord.evaluation.normalizedPaths
    )
    deniedRecord.events.append(ToolCallEvent(actor: .user, kind: .denied, message: message))
    replaceToolCallRecord(deniedRecord)

    let toolResultMessageID = UUID()
    transcriptMutator.appendToolResult(
      ToolResultModelMessage(
        callID: deniedRecord.id,
        toolName: deniedRecord.request.toolName,
        preview: deniedRecord.resultPreview ?? ToolResultPreview(status: .denied, text: message)
      ),
      id: toolResultMessageID,
      turnID: turnID,
      to: &chatSession
    )
    transcriptMutator.appendMessageID(toolResultMessageID, toTurn: turnID, in: &chatSession)
    transcriptMutator.updateTurnStatus(.completed, for: turnID, in: &chatSession)
    refreshContextUsage()
    notifySessionDidChange()
  }

  private func replaceToolCallRecord(_ record: ToolCallRecord) {
    guard let index = chatSession.toolCalls.firstIndex(where: { $0.id == record.id }) else {
      return
    }
    chatSession.toolCalls[index] = record
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
        refreshContextUsage()
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
      guard
        let result = try await toolLoopCoordinator.run(
          ToolLoopRequest(
            workspace: workspace,
            sessionID: sessionID,
            assistantMessageID: currentAssistantMessageID,
            messages: chatSession.messages
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

      transcriptMutator.annotateToolCall(
        result.toolCall,
        for: result.assistantMessageID,
        in: &chatSession
      )
      chatSession.toolCalls.append(result.toolCallRecord)
      transcriptMutator.appendToolCallID(result.toolCallRecord.id, toTurn: turnID, in: &chatSession)
      notifySessionDidChange()

      switch result.outcome {
      case .awaitingApproval:
        transcriptMutator.updateTurnStatus(.awaitingApproval, for: turnID, in: &chatSession)
        isGenerating = false
        chatTurnCoordinator.finishTurn(turnID)
        refreshContextUsage()
        notifySessionDidChange()
        return
      case .completed(let toolResult, let nextAssistantMessageID):
        appendToolResult(toolResult, turnID: turnID)
        transcriptMutator.appendAssistantPlaceholder(
          id: nextAssistantMessageID,
          turnID: turnID,
          to: &chatSession
        )
        transcriptMutator.appendMessageID(
          nextAssistantMessageID,
          toTurn: turnID,
          in: &chatSession
        )
        notifySessionDidChange()
        try await streamAssistantReply(
          to: nextAssistantMessageID,
          toolPromptMode: remainingIterations > 0
            ? .afterToolResultCanContinue
            : .afterToolResultFinal,
          turnID: turnID
        )
        currentAssistantMessageID = nextAssistantMessageID
      case .completedWithoutFollowUp(let toolResult):
        appendToolResult(toolResult, turnID: turnID)
        notifySessionDidChange()
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

  private func appendToolResult(_ toolResult: ToolResultModelMessage, turnID: ChatTurnRecord.ID) {
    let toolResultMessageID = UUID()
    transcriptMutator.appendToolResult(
      toolResult,
      id: toolResultMessageID,
      turnID: turnID,
      to: &chatSession
    )
    transcriptMutator.appendMessageID(toolResultMessageID, toTurn: turnID, in: &chatSession)
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
