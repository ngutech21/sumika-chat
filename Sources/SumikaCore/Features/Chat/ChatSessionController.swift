import Foundation
import Observation

#if canImport(OSLog)
  import OSLog
#endif

@MainActor
@Observable
public final class ChatSessionController {
  public var chatSession = ChatSession.codingDefault
  public var contextUsage: ChatContextUsage?
  public var runtimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot?
  public private(set) var modelContextDebugRevision = 0
  public var draft = ""
  public var isGenerating = false
  public var errorMessage: String?

  public let modelRuntime: ModelRuntimeController
  @ObservationIgnored private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  @ObservationIgnored private let runtimeContextClearCoordinator: RuntimeContextClearCoordinator
  @ObservationIgnored private let contextUsageCoordinator: ContextUsageCoordinator
  @ObservationIgnored private let chatGenerationCoordinator: ChatGenerationCoordinator
  @ObservationIgnored private var toolOrchestrator: ToolOrchestrator
  @ObservationIgnored private var toolLoopCoordinator: ToolLoopCoordinator
  @ObservationIgnored private let turnTracer: any TurnTracing
  @ObservationIgnored private let chatTurnCoordinator: ChatTurnCoordinator
  @ObservationIgnored private let modelContextBuilder = ChatModelContextBuilder()
  @ObservationIgnored private let attachmentCoordinator: ChatAttachmentCoordinator
  @ObservationIgnored private let transcriptMutator = ChatTranscriptMutator()
  @ObservationIgnored private let workflowEventApplier = ChatWorkflowEventApplier()
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private var pendingAgentToolExecutorRegistry: ToolExecutorRegistry?
  @ObservationIgnored private var activeModelContextDebugToolPromptMode: ToolPromptMode?
  @ObservationIgnored private let streamingFlushInterval: TimeInterval = 0.05
  @ObservationIgnored private let streamingFlushCharacterLimit = 240

  #if canImport(OSLog)
    nonisolated private static let logger = Logger(
      subsystem: "sumika-chat",
      category: "ChatSessionController"
    )
  #endif

  public var canSend: Bool {
    modelRuntime.modelState == .ready
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
      && !hasPendingApproval
      && !hasPendingUserAnswer
  }

  public var hasPendingApproval: Bool {
    chatSession.containsToolCall { $0.status == .awaitingApproval }
  }

  public var hasPendingUserAnswer: Bool {
    chatSession.containsToolCall { $0.status == .awaitingUserAnswer }
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
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool =
      ModelLifecycleCoordinator.defaultModelAvailability,
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
        turns: [],
        pendingAttachments: [],
        systemPrompt: storedSettings.systemPrompt,
        generationSettings: storedSettings.generationSettings
      ),
      modelSettingsStore: settingsStore,
      modelDownloader: downloader,
      runtime: runtime,
      resourceMonitor: resourceMonitor,
      modelAvailability: modelAvailability,
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
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool =
      ModelLifecycleCoordinator.defaultModelAvailability,
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
      modelAvailability: modelAvailability,
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
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool,
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
      runtimeOperations: runtimeOperations,
      modelAvailability: modelAvailability
    )
    self.modelLifecycleCoordinator = modelLifecycleCoordinator
    self.chatTurnCoordinator = ChatTurnCoordinator(turnTracer: turnTracer)
    self.runtimeContextClearCoordinator = RuntimeContextClearCoordinator(
      modelLifecycleCoordinator: modelLifecycleCoordinator)
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
    self.toolOrchestrator = toolOrchestrator
    self.toolLoopCoordinator = ToolLoopCoordinator(
      agentToolOrchestrator: toolOrchestrator,
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
      self.invalidateModelContextDebugDocument()
      self.notifySessionDidChange()
    }
    modelRuntime.onRuntimeDidReset = { [weak self] in
      guard let self else {
        return
      }

      self.runtimeCacheDebugSnapshot = nil
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
    runtimeCacheDebugSnapshot = nil
    chatSession = session
    chatSession.pendingAttachments = []
    disableUnsupportedInteractionModeIfNeeded()
    invalidateModelContextDebugDocument()

    if didResetRuntime {
      invalidateContextUsage()
    } else if modelRuntime.modelState == .loading {
      invalidateContextUsage()
    } else {
      clearRuntimeContextForReuse()
      refreshContextUsage()
    }
  }

  public func sessionSnapshot(updating session: ChatSession) -> ChatSession {
    var snapshot = session
    snapshot.title = chatSession.title
    snapshot.selectedModelID = modelRuntime.selectedModelID
    snapshot.modelContextSnapshot = chatSession.modelContextSnapshot
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
    invalidateModelContextDebugDocument()
    clearRuntimeContextForReuse()
    refreshContextUsage(toolPromptMode: mode == .chat ? .disabled : .enabled(true))
    notifySessionDidChange()
  }

  public func configureAgentTools(todoWriteEnabled: Bool) {
    setAgentToolExecutorRegistry(
      ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: todoWriteEnabled)
    )
  }

  public func setAgentToolExecutorRegistry(_ executorRegistry: ToolExecutorRegistry) {
    guard !isGenerating else {
      pendingAgentToolExecutorRegistry = executorRegistry
      return
    }
    applyAgentToolExecutorRegistry(executorRegistry, shouldRefreshContext: true)
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

  private func applyAgentToolExecutorRegistry(
    _ executorRegistry: ToolExecutorRegistry,
    shouldRefreshContext: Bool
  ) {
    toolOrchestrator = toolOrchestrator.replacingExecutorRegistry(executorRegistry)
    toolLoopCoordinator = ToolLoopCoordinator(
      agentToolOrchestrator: toolOrchestrator,
      turnTracer: turnTracer
    )
    invalidateModelContextDebugDocument()
    if shouldRefreshContext {
      clearRuntimeContextForReuse()
      refreshContextUsage()
    }
  }

  private func finishGeneratingTurn(
    _ turnID: ChatTurn.ID,
    contextRefreshMode: ToolPromptMode = .disabled
  ) {
    isGenerating = false
    flushPendingContextUsageRefresh(defaultMode: contextRefreshMode)
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

    let sentAttachments = attachmentsForTurn
    updateDefaultSessionTitleIfNeeded(fromFirstPrompt: prompt)
    draft = ""
    errorMessage = nil
    chatSession.pendingAttachments.removeAll()
    chatSession.activeAttachmentContext = .empty
    chatSession.focusedFileState.focusedAttachments = []
    isGenerating = true

    chatTurnCoordinator.startUserTurn(
      prompt: prompt,
      workspace: workspace,
      sessionID: sessionID,
      attachments: sentAttachments,
      runtime: turnRuntimeContext(),
      runtimeContextClearCoordinator: runtimeContextClearCoordinator,
      callbacks: turnCallbacks()
    )
  }

  private func updateDefaultSessionTitleIfNeeded(fromFirstPrompt prompt: String) {
    guard chatSession.title == ChatSession.defaultTitle,
      chatSession.turns.flatMap(\.items).allSatisfy({ $0.userContent == nil })
    else {
      return
    }

    chatSession.title = ChatSessionTitleDeriver.title(fromFirstPrompt: prompt)
  }

  public func cancelGeneration() {
    cancelGeneration(notify: true)
  }

  private func cancelGeneration(notify: Bool) {
    let didCancel = chatTurnCoordinator.cancelActiveTurn(
      emitEvents: { [weak self] events in self?.applyWorkflowEvents(events) },
      turnDidFinish: { [weak self] turnID, mode in
        self?.finishGeneratingTurn(turnID, contextRefreshMode: mode)
      },
      notifySessionDidChange: {}
    )
    if !didCancel {
      isGenerating = false
      flushPendingContextUsageRefresh(defaultMode: .disabled)
    }
    if notify {
      notifySessionDidChange()
    }
  }

  public func clearChatHistory() {
    transcriptMutator.clearTranscript(in: &chatSession)
    runtimeCacheDebugSnapshot = nil
    invalidateModelContextDebugDocument()
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

  public func modelContextDebugDocument(
    workspace: Workspace? = nil,
    sessionID: ChatSession.ID? = nil
  ) throws -> ModelContextDebugDocument {
    let transcript = modelContextBuilder.transcript(
      from: chatSession,
      includingTurnID: chatTurnCoordinator.activeTurnID
    )
    return try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: systemPrompt(
        toolPromptMode: modelContextDebugToolPromptMode(
          workspace: workspace,
          sessionID: sessionID
        ))
    )
  }

  private func invalidateContextUsage() {
    contextUsageCoordinator.invalidate(onEvent: handleContextUsageEvent(_:))
  }

  private func invalidateModelContextDebugDocument() {
    modelContextDebugRevision &+= 1
  }

  private func clearRuntimeContextForReuse() {
    runtimeCacheDebugSnapshot = nil
    let operationID = modelRuntime.currentOperationID()
    runtimeContextClearCoordinator.clear(operationID: operationID) { [weak self] error in
      if let error {
        self?.errorMessage = error.localizedDescription
      } else {
        self?.flushPendingContextUsageRefresh(defaultMode: .disabled)
      }
    }
  }

  private func flushPendingContextUsageRefresh(defaultMode: ToolPromptMode) {
    if activeModelContextDebugToolPromptMode != nil {
      activeModelContextDebugToolPromptMode = nil
      invalidateModelContextDebugDocument()
    }
    if let pendingAgentToolExecutorRegistry {
      self.pendingAgentToolExecutorRegistry = nil
      applyAgentToolExecutorRegistry(
        pendingAgentToolExecutorRegistry,
        shouldRefreshContext: false
      )
    }
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
      runtimeIsBusy: isGenerating || runtimeContextClearCoordinator.hasPendingClear,
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

  public func removeAttachment(id: ChatAttachment.ID) {
    attachmentCoordinator.removeAttachment(id: id, onEvent: handleAttachmentEvent(_:))
  }

  private func handleAttachmentEvent(_ event: ChatAttachmentEvent) {
    switch event {
    case .appendAttachments(let attachments):
      chatSession.pendingAttachments.append(contentsOf: attachments)
      errorMessage = nil
      refreshContextUsage()
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
    chatTurnCoordinator.approveToolCall(
      existingRecord,
      in: workspace,
      turnID: turnID,
      toolOrchestrator: toolOrchestrator,
      runtime: turnRuntimeContext(),
      callbacks: turnCallbacks()
    )
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

    isGenerating = true
    errorMessage = nil
    chatTurnCoordinator.answerAskUserToolCall(
      existingRecord,
      answer: answer,
      in: workspace,
      turnID: turnID,
      runtime: turnRuntimeContext(),
      callbacks: turnCallbacks()
    )
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
    isGenerating = true
    errorMessage = nil
    chatTurnCoordinator.denyToolCall(
      existingRecord,
      message: message,
      turnID: turnID,
      runtime: turnRuntimeContext(),
      callbacks: turnCallbacks()
    )
  }

  private func turnRuntimeContext() -> ChatTurnRuntimeContext {
    ChatTurnRuntimeContext(
      selectedModel: modelRuntime.selectedModel,
      operationID: modelRuntime.currentOperationID(),
      chatGenerationCoordinator: chatGenerationCoordinator,
      toolLoopCoordinator: toolLoopCoordinator
    )
  }

  private func turnCallbacks() -> ChatTurnCallbacks {
    ChatTurnCallbacks(
      session: { [weak self] in self?.chatSession ?? .codingDefault },
      emitEvents: { [weak self] events in self?.applyWorkflowEvents(events) },
      setActiveToolPromptMode: { [weak self] mode in
        guard let self else {
          return
        }
        guard self.activeModelContextDebugToolPromptMode != mode else {
          return
        }
        self.activeModelContextDebugToolPromptMode = mode
        self.invalidateModelContextDebugDocument()
      },
      updateRuntimeCacheDebugSnapshot: { [weak self] snapshot in
        self?.runtimeCacheDebugSnapshot = snapshot
      },
      refreshContextUsage: { [weak self] mode in
        self?.refreshContextUsage(toolPromptMode: mode)
      },
      setErrorMessage: { [weak self] message in
        self?.errorMessage = message
      },
      turnDidFinish: { [weak self] turnID, mode in
        self?.finishGeneratingTurn(turnID, contextRefreshMode: mode)
      },
      notifySessionDidChange: { [weak self] in
        self?.notifySessionDidChange()
      }
    )
  }

  private func applyWorkflowEvents(_ events: [ChatWorkflowEvent]) {
    let diagnostics = workflowEventApplier.apply(events, to: &chatSession)
    if events.contains(where: \.affectsModelContextDebugDocument) {
      invalidateModelContextDebugDocument()
    }
    guard !diagnostics.isEmpty else {
      return
    }
    // In an append-only, event-sourced transcript a missing turn/message/tool-call
    // target means a misordered or dropped event would otherwise corrupt the
    // materialized projection in silence. Surface it loudly instead of discarding.
    #if canImport(OSLog)
      for diagnostic in diagnostics {
        Self.logger.error(
          "Workflow event applied with missing \(diagnostic.missingTargetKind.rawValue, privacy: .public) target id=\(diagnostic.missingTargetID.uuidString, privacy: .public)"
        )
      }
    #endif
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

}

extension ChatSessionController {
  fileprivate func systemPrompt(toolPromptMode: ToolPromptMode) -> String {
    chatTurnCoordinator.systemPrompt(
      session: chatSession,
      selectedModel: modelRuntime.selectedModel,
      toolLoopCoordinator: toolLoopCoordinator,
      toolPromptMode: toolPromptMode
    )
  }

  private func modelContextDebugToolPromptMode(
    workspace: Workspace?,
    sessionID: ChatSession.ID?
  ) -> ToolPromptMode {
    if chatTurnCoordinator.activeTurnID != nil,
      let activeModelContextDebugToolPromptMode
    {
      return activeModelContextDebugToolPromptMode
    }

    return chatTurnCoordinator.currentToolPromptMode(
      session: chatSession,
      workspace: workspace,
      sessionID: sessionID,
      selectedModel: modelRuntime.selectedModel
    )
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

extension ChatWorkflowEvent {
  fileprivate var affectsModelContextDebugDocument: Bool {
    switch self {
    case .modelContextEntryAppended,
      .nativeAssistantBoundaryAppended,
      .toolResultAppended,
      .assistantMessageAppended,
      .todoStateChanged,
      .finalToolResultFollowUpBoundaryAppended:
      return true
    case .turnStatusChanged(_, _, let modelContextPolicy):
      return modelContextPolicy != nil
    case .turnAppended,
      .userMessageAppended,
      .assistantMessageAnnotatedAsToolCall,
      .assistantAnnotatedAsNativeToolCall,
      .toolCallAppended,
      .toolCallUpdated,
      .assistantPlaceholderAppended,
      .assistantChunkAppended,
      .assistantGenerationCompleted,
      .focusedFileStateChanged,
      .streamingAssistantMessagesCancelled,
      .transientAssistantPlaceholdersRemoved:
      return false
    }
  }
}

extension ManagedModel {
  fileprivate func supports(interactionMode: WorkspaceInteractionMode) -> Bool {
    interactionMode == .chat || supportsWorkspaceTools
  }
}

extension ChatSession {
  fileprivate func containsToolCall(_ predicate: (ToolCallRecord) -> Bool) -> Bool {
    turns.contains { turn in
      turn.items.contains { item in
        guard case .tool(let record) = item else {
          return false
        }
        return predicate(record)
      }
    }
  }
}

extension Array where Element == ChatAttachment {
  fileprivate var hasImages: Bool {
    contains { $0.kind == .image }
  }
}
