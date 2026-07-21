import Foundation
import Observation

#if canImport(OSLog)
  import OSLog
#endif

@MainActor
@Observable
package final class ConversationEngine {
  private(set) var chatSession: ChatSession {
    didSet {
      syncComposerSessionState()
    }
  }
  package private(set) var composerSessionState = ChatComposerSessionState()
  package private(set) var modelContextDebugState = ModelContextDebugState()
  package internal(set) var contextUsage: ChatContextUsage?
  package internal(set) var isGenerating = false
  package private(set) var errorMessage: String?

  @ObservationIgnored private let conversationModel: @MainActor () -> ConversationModelState
  @ObservationIgnored private let runtimeContextClearCoordinator: RuntimeContextClearCoordinator
  @ObservationIgnored private let chatGenerationCoordinator: ChatGenerationCoordinator
  @ObservationIgnored private var toolOrchestrator: ToolOrchestrator
  @ObservationIgnored private var chatWebToolOrchestrator: ToolOrchestrator
  @ObservationIgnored private var toolLoopCoordinator: ToolLoopCoordinator
  @ObservationIgnored private let turnTracer: any TurnTracing
  @ObservationIgnored var activeTurnID: ChatTurn.ID?
  @ObservationIgnored var activeTurnTask: Task<Void, Never>?
  @ObservationIgnored var turnToolRegistries: [ChatTurn.ID: ToolRegistry] = [:]
  @ObservationIgnored let turnExecutionCoordinator: ChatTurnExecutionCoordinator
  @ObservationIgnored var workspaceInstructionsLoader: any WorkspaceInstructionsLoading
  @ObservationIgnored let toolResumeCoordinator = ToolResumeCoordinator()
  @ObservationIgnored let maxToolLoopIterations: Int
  @ObservationIgnored private let modelContextBuilder = ChatModelContextBuilder()
  @ObservationIgnored private let attachmentCoordinator: ChatAttachmentCoordinator
  @ObservationIgnored private let transcriptMutator = ChatTranscriptMutator()
  @ObservationIgnored private let workflowEventApplier = ChatWorkflowEventApplier()
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private var agentToolConfiguration: AgentToolConfiguration?
  @ObservationIgnored private var pendingAgentToolExecutorRegistry: ToolExecutorRegistry?
  @ObservationIgnored private var pendingSelectedMCPServerIDs: [UUID]?
  @ObservationIgnored private var activeModelContextDebugToolPromptMode: ToolPromptMode?
  #if canImport(OSLog)
    nonisolated private static let logger = Logger(
      subsystem: SumikaTelemetry.subsystem,
      category: "ConversationEngine"
    )
  #endif

  func canSend(prompt: String) -> Bool {
    conversationModelState.loadState == .ready
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
  }

  var hasPendingApproval: Bool {
    chatSession.containsToolCall { $0.status == .awaitingApproval }
  }

  var hasPendingUserAnswer: Bool {
    chatSession.containsToolCall { $0.status == .awaitingUserAnswer }
  }

  var isInputBlocked: Bool {
    hasPendingApproval || hasPendingUserAnswer
  }

  package var canChangeInteractionMode: Bool {
    !isGenerating && !isInputBlocked
  }

  package var canChangeMCPServerSelection: Bool {
    chatSession.interactionMode == .agent && canChangeInteractionMode
  }

  package var canEnableAutomaticToolApproval: Bool {
    chatSession.interactionMode == .agent
      && chatSession.toolApprovalPolicy == .manual
      && !isGenerating
      && !hasPendingUserAnswer
  }

  package init(
    conversationModel: @escaping @MainActor () -> ConversationModelState,
    runtimeContextClearCoordinator: RuntimeContextClearCoordinator,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    chatSession: ChatSession = ChatSession(),
    toolOrchestrator: ToolOrchestrator = ToolOrchestrator.agent(todoWriteEnabled: true),
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.conversationModel = conversationModel
    self.runtimeContextClearCoordinator = runtimeContextClearCoordinator
    self.chatGenerationCoordinator = chatGenerationCoordinator
    self.turnTracer = turnTracer
    self.turnExecutionCoordinator = ChatTurnExecutionCoordinator(
      turnTracer: turnTracer
    )
    self.workspaceInstructionsLoader = WorkspaceInstructionsLoader()
    self.maxToolLoopIterations = ChatToolLoopLimits.defaultMaxToolLoopIterations
    self.toolOrchestrator = toolOrchestrator
    self.chatWebToolOrchestrator = toolOrchestrator.replacingExecutorRegistry(.chatWeb)
    self.toolLoopCoordinator = ToolLoopCoordinator(
      chatWebToolOrchestrator: chatWebToolOrchestrator,
      agentToolOrchestrator: toolOrchestrator,
      turnTracer: turnTracer
    )
    self.attachmentCoordinator = ChatAttachmentCoordinator(loader: chatAttachmentLoader)
    self.chatSession = chatSession
    self.composerSessionState = Self.composerSessionState(for: chatSession)
  }

  deinit {
    activeTurnTask?.cancel()
  }
}

extension ConversationEngine {
  private var conversationModelState: ConversationModelState {
    conversationModel()
  }

  package func modelManagementEventHandlers(
    errorDidOccur: @escaping @MainActor (String) -> Void
  ) -> ModelManagementEventHandlers {
    ModelManagementEventHandlers(
      modelDidChange: { [weak self] settings in
        self?.handleModelDidChange(settings)
      },
      runtimeDidReset: { [weak self] in
        self?.handleModelRuntimeDidReset()
      },
      contextUsageShouldRefresh: { [weak self] in
        await self?.updateContextUsage()
      },
      errorDidOccur: errorDidOccur
    )
  }

  private func handleModelDidChange(_ settings: StoredModelSettings) {
    disableUnsupportedInteractionModeIfNeeded()
    chatSession.modeSettings = settings.modeSettings
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateModelContextDebugDocument()
    invalidateContextUsage()
    notifySessionDidChange()

    clearRuntimeContextForReuse()
    refreshContextUsage()
  }

  private func handleModelRuntimeDidReset() {
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateContextUsage()
  }

  private func syncComposerSessionState() {
    let nextState = Self.composerSessionState(for: chatSession)
    guard composerSessionState != nextState else {
      return
    }
    composerSessionState = nextState
  }

  private static func composerSessionState(for session: ChatSession) -> ChatComposerSessionState {
    ChatComposerSessionState(
      pendingAttachments: session.pendingAttachments,
      activeAttachments: activeAttachments(in: session),
      interactionMode: session.interactionMode,
      toolApprovalPolicy: session.toolApprovalPolicy,
      selectedMCPServerIDs: session.selectedMCPServerIDs,
      reasoningEnabled: session.generationSettings.reasoningEnabled,
      todoState: visibleTodoState(in: session)
    )
  }

  private static func activeAttachments(in session: ChatSession) -> [ChatAttachment] {
    let activeIDs = Set(session.activeAttachmentContext.attachmentIDs)
    guard !activeIDs.isEmpty else {
      return []
    }
    return session.pendingAttachments.filter { activeIDs.contains($0.id) }
  }

  private static func visibleTodoState(in session: ChatSession) -> TodoState? {
    guard session.interactionMode == .agent,
      let todoState = session.todoState,
      !todoState.items.isEmpty
    else {
      return nil
    }
    return todoState
  }

  package func setSessionChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
    onSessionDidChange = handler
  }

  package var sessionID: ChatSession.ID {
    chatSession.id
  }

  package var turns: [ChatTurn] {
    chatSession.turns
  }

  package var modeSettings: ChatModeSettingsSet {
    chatSession.modeSettings
  }

  @discardableResult
  package func updateModeSettings(_ modeSettings: ChatModeSettingsSet) -> Bool {
    guard chatSession.modeSettings != modeSettings else {
      return false
    }

    chatSession.modeSettings = modeSettings
    refreshContextUsage()
    notifySessionDidChange()
    return true
  }

  @discardableResult
  package func renameSession(to title: String) -> Bool {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      return false
    }

    chatSession.title = trimmedTitle
    notifySessionDidChange()
    return true
  }

  func installSession(
    _ session: ChatSession,
    modelRuntimeWasReset: Bool
  ) {
    errorMessage = nil
    contextUsage = nil
    updateRuntimeCacheDebugSnapshot(nil)
    chatSession = session
    chatSession.pendingAttachments = []
    disableUnsupportedInteractionModeIfNeeded()
    invalidateModelContextDebugDocument()

    if modelRuntimeWasReset {
      invalidateContextUsage()
    } else if conversationModelState.loadState == .loading {
      invalidateContextUsage()
    } else {
      clearRuntimeContextForReuse()
      refreshContextUsage()
    }
  }

  package func sessionSnapshot() -> ChatSession {
    var snapshot = chatSession
    snapshot.selectedModelID = conversationModelState.selectedModel.id
    snapshot.pendingAttachments = []
    snapshot.updatedAt = Date()
    return snapshot
  }

  package func setInteractionMode(_ mode: WorkspaceInteractionMode) {
    guard canChangeInteractionMode, chatSession.interactionMode != mode else {
      return
    }
    let selectedModel = conversationModelState.selectedModel
    guard selectedModel.supports(interactionMode: mode) else {
      errorMessage = unsupportedInteractionModeMessage(for: selectedModel)
      return
    }

    chatSession.interactionMode = mode
    errorMessage = nil
    invalidateModelContextDebugDocument()
    clearRuntimeContextForReuse()
    refreshContextUsage(toolPromptMode: mode == .chat ? .disabled : .enabled(true))
    notifySessionDidChange()
  }

  package func setReasoningEnabled(_ isEnabled: Bool) {
    guard canChangeInteractionMode, chatSession.generationSettings.reasoningEnabled != isEnabled
    else {
      return
    }

    chatSession.generationSettings.reasoningEnabled = isEnabled
    errorMessage = nil
    invalidateModelContextDebugDocument()
    clearRuntimeContextForReuse()
    refreshContextUsage(
      toolPromptMode: chatSession.interactionMode == .chat ? .disabled : .enabled(true))
    notifySessionDidChange()
  }

  package func enableAutomaticToolApproval(in workspace: Workspace) {
    guard canEnableAutomaticToolApproval else {
      return
    }

    chatSession.toolApprovalPolicy = .automatic
    errorMessage = nil
    notifySessionDidChange()

    guard let batchAnchorID = latestPendingApprovalBatchAnchorID else {
      return
    }
    resumeAutomaticApprovalBatch(containing: batchAnchorID, in: workspace)
  }

  package func disableAutomaticToolApproval() {
    guard chatSession.toolApprovalPolicy != .manual else {
      return
    }

    chatSession.toolApprovalPolicy = .manual
    errorMessage = nil
    notifySessionDidChange()
  }

  package func configureAgentTools(
    todoWriteEnabled: Bool,
    mcpExecutorGroups: [MCPAgentToolExecutorGroup] = []
  ) {
    updateAgentToolConfiguration(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: mcpExecutorGroups
    )
    let selectedServerIDs = pendingSelectedMCPServerIDs ?? chatSession.selectedMCPServerIDs
    setAgentToolExecutorRegistry(
      configuredAgentToolExecutorRegistry(selectedMCPServerIDs: selectedServerIDs)
    )
  }

  /// Reconciles connected MCP contributions and persisted selection as one
  /// Core operation so the matching registry is installed or deferred with
  /// the selection that produced it.
  package func reconcileAgentTools(
    todoWriteEnabled: Bool,
    mcpExecutorGroups: [MCPAgentToolExecutorGroup],
    selectedMCPServerIDs: [UUID]
  ) {
    updateAgentToolConfiguration(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: mcpExecutorGroups
    )
    reconcileSelectedMCPServerIDs(selectedMCPServerIDs)
  }

  private func setAgentToolExecutorRegistry(_ executorRegistry: ToolExecutorRegistry) {
    guard !isGenerating, !isInputBlocked else {
      pendingAgentToolExecutorRegistry = executorRegistry
      return
    }
    applyAgentToolExecutorRegistry(executorRegistry, shouldRefreshContext: true)
  }

  package func setSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    guard canChangeMCPServerSelection else {
      return
    }
    applySelectedMCPServerIDs(serverIDs)
  }

  /// Reconciles persisted selection with global MCP configuration. Unlike a
  /// user action this may run in Chat mode, but it is deferred across an
  /// active generation or unresolved interaction so validated calls keep the
  /// registry that created them.
  package func reconcileSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    let executorRegistry = configuredAgentToolExecutorRegistry(
      selectedMCPServerIDs: serverIDs
    )
    guard !isGenerating, !isInputBlocked else {
      pendingSelectedMCPServerIDs = serverIDs
      pendingAgentToolExecutorRegistry = executorRegistry
      return
    }
    applySelectedMCPServerIDs(serverIDs)
  }

  package func prepareForModelRuntimeAction(
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
    chatWebToolOrchestrator = toolOrchestrator.replacingExecutorRegistry(.chatWeb)
    toolLoopCoordinator = ToolLoopCoordinator(
      chatWebToolOrchestrator: chatWebToolOrchestrator,
      agentToolOrchestrator: toolOrchestrator,
      turnTracer: turnTracer
    )
    invalidateModelContextDebugDocument()
    if shouldRefreshContext {
      clearRuntimeContextForReuse()
      refreshContextUsage()
    }
  }

  private func applySelectedMCPServerIDs(
    _ serverIDs: [UUID]
  ) {
    let selectionChanged = chatSession.selectedMCPServerIDs != serverIDs
    chatSession.setSelectedMCPServerIDs(serverIDs)
    applyAgentToolExecutorRegistry(
      configuredAgentToolExecutorRegistry(selectedMCPServerIDs: serverIDs),
      shouldRefreshContext: true
    )
    if selectionChanged {
      notifySessionDidChange()
    }
  }

  private func configuredAgentToolExecutorRegistry(
    selectedMCPServerIDs: [UUID]
  ) -> ToolExecutorRegistry {
    agentToolConfiguration?.executorRegistry(
      selectedMCPServerIDs: selectedMCPServerIDs
    ) ?? toolOrchestrator.executorRegistry
  }

  private func updateAgentToolConfiguration(
    todoWriteEnabled: Bool,
    mcpExecutorGroups: [MCPAgentToolExecutorGroup]
  ) {
    agentToolConfiguration = AgentToolConfiguration(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: mcpExecutorGroups
    )
  }

  func finishGeneratingTurn(contextRefreshMode: ToolPromptMode = .disabled) {
    isGenerating = false
    flushPendingContextUsageRefresh(defaultMode: contextRefreshMode)
  }

  @discardableResult
  package func sendMessage(prompt: String) -> Bool {
    sendMessage(prompt: prompt, workspace: nil, sessionID: nil)
  }

  @discardableResult
  package func sendMessage(
    prompt: String,
    in workspace: Workspace,
    sessionID: ChatSession.ID
  ) -> Bool {
    sendMessage(prompt: prompt, workspace: workspace, sessionID: sessionID)
  }

  private func sendMessage(
    prompt rawPrompt: String,
    workspace: Workspace?,
    sessionID: ChatSession.ID?
  ) -> Bool {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend(prompt: rawPrompt) else { return false }
    let selectedModel = conversationModelState.selectedModel
    guard selectedModel.supports(interactionMode: chatSession.interactionMode) else {
      errorMessage = unsupportedInteractionModeMessage(for: selectedModel)
      return false
    }
    let attachmentsForTurn = attachmentsForCurrentTurn()
    guard selectedModel.supportsImageInput || !attachmentsForTurn.hasImages
    else {
      errorMessage = unsupportedImageInputMessage(for: selectedModel)
      return false
    }

    let sentAttachments = attachmentsForTurn
    updateDefaultSessionTitleIfNeeded(fromFirstPrompt: prompt)
    interruptPendingToolInteractionsForNewUserMessage()
    applyPendingAgentToolExecutorRegistry(shouldRefreshContext: false)
    errorMessage = nil
    chatSession.pendingAttachments.removeAll()
    chatSession.activeAttachmentContext = .empty
    chatSession.focusedFileState.focusedAttachments = []
    isGenerating = true

    startUserTurn(
      prompt: prompt,
      workspace: workspace,
      sessionID: sessionID,
      attachments: sentAttachments,
      runtime: turnRuntimeContext(),
      runtimeContextClearCoordinator: runtimeContextClearCoordinator
    )
    return true
  }

  private func interruptPendingToolInteractionsForNewUserMessage() {
    var events: [ChatWorkflowEvent] = []
    var interruptedTurnIDs: [ChatTurn.ID] = []

    for turn in chatSession.turns {
      var didInterruptTurn = false
      for item in turn.items {
        guard case .tool(let record) = item else {
          continue
        }

        switch record.status {
        case .awaitingApproval:
          let deniedRecord = deniedInterruptedToolCall(record)
          events.append(.toolCallUpdated(deniedRecord))
          events.append(.toolResultAppended(toolResultMessage(for: deniedRecord), turnID: turn.id))
          didInterruptTurn = true
        case .awaitingUserAnswer:
          var cancelledRecord = record
          cancelledRecord.state = .cancelled
          events.append(.toolCallUpdated(cancelledRecord))
          didInterruptTurn = true
        case .pending, .running, .completed, .denied, .failed, .cancelled:
          continue
        }
      }

      guard didInterruptTurn else {
        continue
      }
      interruptedTurnIDs.append(turn.id)
      events.append(
        .turnStatusChanged(
          turnID: turn.id,
          status: .cancelled,
          modelContextPolicy: .excluded
        ))
      events.append(.streamingAssistantMessagesCancelled(turnID: turn.id))
    }

    guard !interruptedTurnIDs.isEmpty else {
      return
    }

    events.append(.transientAssistantPlaceholdersRemoved)
    applyWorkflowEvents(events)
  }

  private func deniedInterruptedToolCall(_ record: ToolCallRecord) -> ToolCallRecord {
    var deniedRecord = record
    deniedRecord.state = .denied(interruptedToolFailurePayload(for: record))
    return deniedRecord
  }

  private func toolResultMessage(for record: ToolCallRecord) -> ToolResultModelMessage {
    ToolResultModelMessage(
      callID: record.id,
      toolName: record.request.toolName,
      payload: record.resultPayload ?? interruptedToolFailurePayload(for: record)
    )
  }

  private func interruptedToolFailurePayload(for record: ToolCallRecord) -> ToolResultPayload {
    .failure(
      ToolFailure(
        toolName: record.request.toolName,
        path: record.evaluation.firstModelFacingPath,
        reason: .permissionDenied,
        recovery: .askUser(message: "Tool call interrupted by a new user message.")
      ))
  }

  private func updateDefaultSessionTitleIfNeeded(fromFirstPrompt prompt: String) {
    guard chatSession.title == ChatSession.defaultTitle,
      chatSession.turns.flatMap(\.items).allSatisfy({ $0.userContent == nil })
    else {
      return
    }

    chatSession.title = ChatSessionTitleGenerator.title(fromFirstPrompt: prompt)
  }

  package func cancelGeneration() {
    cancelGeneration(notify: true)
  }

  func cancelGenerationForSessionSwitch() {
    cancelGeneration(notify: false)
  }

  private func cancelGeneration(notify: Bool) {
    let didCancel = cancelActiveTurn()
    if !didCancel {
      isGenerating = false
      flushPendingContextUsageRefresh(defaultMode: .disabled)
    }
    if notify {
      notifySessionDidChange()
    }
  }

  func clearChatHistory() {
    transcriptMutator.clearTranscript(in: &chatSession)
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateModelContextDebugDocument()
    invalidateContextUsage()
    notifySessionDidChange()

    clearRuntimeContextForReuse()
    refreshContextUsage()
  }

  package func refreshContextUsage() {
    refreshContextUsage(toolPromptMode: .disabled)
  }

  func refreshContextUsage(toolPromptMode: ToolPromptMode) {
    let snapshot = contextUsageSnapshot(toolPromptMode: toolPromptMode)
    guard snapshot.modelState == .ready else {
      contextUsage = nil
      return
    }
    contextUsage = snapshot.estimatedUsage(isStale: false)
  }

  private func updateContextUsage() async {
    refreshContextUsage()
  }

  package func modelContextDebugDocument(
    workspace: Workspace? = nil,
    sessionID: ChatSession.ID? = nil
  ) throws -> ModelContextDebugDocument {
    let transcript = modelContextBuilder.transcript(
      from: chatSession,
      includingTurnID: activeTurnID
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
    contextUsage = nil
  }

  func updateRuntimeCacheDebugSnapshot(_ snapshot: RuntimeCacheDebugSnapshot?) {
    let nextState = ModelContextDebugState(
      runtimeCacheDebugSnapshot: snapshot,
      documentRevision: modelContextDebugState.documentRevision
    )
    updateModelContextDebugState(nextState)
  }

  private func invalidateModelContextDebugDocument() {
    let nextState = ModelContextDebugState(
      runtimeCacheDebugSnapshot: modelContextDebugState.runtimeCacheDebugSnapshot,
      documentRevision: modelContextDebugState.documentRevision &+ 1
    )
    updateModelContextDebugState(nextState)
  }

  private func updateModelContextDebugState(_ nextState: ModelContextDebugState) {
    guard modelContextDebugState != nextState else {
      return
    }
    modelContextDebugState = nextState
  }

  private func clearRuntimeContextForReuse() {
    updateRuntimeCacheDebugSnapshot(nil)
    let operationID = conversationModelState.operationID
    runtimeContextClearCoordinator.clear(operationID: operationID) { [weak self] error in
      if error is CancellationError {
        return
      }
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
    applyPendingAgentToolExecutorRegistry(shouldRefreshContext: false)
    refreshContextUsage(toolPromptMode: defaultMode)
  }

  private func applyPendingAgentToolExecutorRegistry(shouldRefreshContext: Bool) {
    guard let pendingAgentToolExecutorRegistry else {
      return
    }
    self.pendingAgentToolExecutorRegistry = nil
    if let pendingSelectedMCPServerIDs {
      self.pendingSelectedMCPServerIDs = nil
      chatSession.setSelectedMCPServerIDs(pendingSelectedMCPServerIDs)
      notifySessionDidChange()
    }
    applyAgentToolExecutorRegistry(
      pendingAgentToolExecutorRegistry,
      shouldRefreshContext: shouldRefreshContext
    )
  }

  private func contextUsageSnapshot(toolPromptMode: ToolPromptMode = .disabled)
    -> ContextUsageSnapshot
  {
    let turnID = activeTurnID
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

    let modelState = conversationModelState
    return ContextUsageSnapshot(
      modelState: modelState.loadState,
      transcript: transcript,
      attachments: attachmentsForCurrentTurn(),
      systemPrompt: renderedSystemPrompt,
      contextTokenLimit: modelState.contextTokenLimit
    )
  }

  package func addAttachments(from urls: [URL]) {
    attachmentCoordinator.addAttachments(
      from: urls,
      existingAttachments: chatSession.pendingAttachments,
      onEvent: handleAttachmentEvent(_:))
  }

  package func removeAttachment(id: ChatAttachment.ID) {
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

  func notifySessionDidChange() {
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

  package func approveToolCall(id toolCallID: ToolCallRecord.ID, in workspace: Workspace) {
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
    approveToolCall(
      existingRecord,
      in: workspace,
      turnID: turnID,
      toolOrchestrator: toolOrchestrator(for: existingRecord),
      runtime: turnRuntimeContext()
    )
  }

  package func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace
  ) {
    guard !isGenerating else {
      return
    }
    guard let turnID = chatSession.turnID(containingToolCall: batchAnchorID),
      let turn = chatSession.turns.first(where: { $0.id == turnID }),
      let batch = turn.toolCallBatch(containing: batchAnchorID),
      batch.anchorID == batchAnchorID
    else {
      return
    }
    let pendingRecords = batch.pendingApprovalRecords
    guard pendingRecords.count >= 2, let firstRecord = pendingRecords.first else {
      return
    }

    isGenerating = true
    errorMessage = nil
    approveToolCallBatch(
      pendingRecords,
      batchAnchorID: batch.anchorID,
      in: workspace,
      turnID: turnID,
      toolOrchestrator: toolOrchestrator(for: firstRecord),
      runtime: turnRuntimeContext()
    )
  }

  package func resumeAutomaticApprovalBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace
  ) {
    guard !isGenerating,
      chatSession.interactionMode == .agent,
      chatSession.toolApprovalPolicy == .automatic,
      let turnID = chatSession.turnID(containingToolCall: batchAnchorID),
      let turn = chatSession.turns.first(where: { $0.id == turnID }),
      let batch = turn.toolCallBatch(containing: batchAnchorID),
      batch.anchorID == batchAnchorID,
      let firstRecord = batch.pendingApprovalRecords.first
    else {
      return
    }

    isGenerating = true
    errorMessage = nil
    approveToolCallBatch(
      batch.pendingApprovalRecords,
      batchAnchorID: batch.anchorID,
      in: workspace,
      turnID: turnID,
      toolOrchestrator: toolOrchestrator(for: firstRecord),
      approvalSource: .automatic,
      runtime: turnRuntimeContext()
    )
  }

  private var latestPendingApprovalBatchAnchorID: ToolCallRecord.ID? {
    for turn in chatSession.turns.reversed() {
      if let batch = turn.toolCallBatches.last(where: { !$0.pendingApprovalRecords.isEmpty }) {
        return batch.anchorID
      }
    }
    return nil
  }

  private func toolOrchestrator(for record: ToolCallRecord) -> ToolOrchestrator {
    guard chatSession.interactionMode == .chat else {
      return toolOrchestrator
    }
    switch record.request.toolName {
    case .webSearch, .webFetch:
      return chatWebToolOrchestrator
    default:
      return toolOrchestrator
    }
  }

  package func answerAskUserToolCall(
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
    answerAskUserToolCall(
      existingRecord,
      answer: answer,
      in: workspace,
      turnID: turnID,
      runtime: turnRuntimeContext()
    )
  }

  package func denyToolCall(id toolCallID: ToolCallRecord.ID) {
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
    denyToolCall(
      existingRecord,
      turnID: turnID,
      runtime: turnRuntimeContext()
    )
  }

  private func turnRuntimeContext() -> ChatTurnRuntimeContext {
    let modelState = conversationModelState
    return ChatTurnRuntimeContext(
      selectedModel: modelState.selectedModel,
      operationID: modelState.operationID,
      chatGenerationCoordinator: chatGenerationCoordinator,
      toolLoopCoordinator: toolLoopCoordinator,
      agentToolOrchestrator: toolOrchestrator
    )
  }

  func setActiveToolPromptMode(_ mode: ToolPromptMode?) {
    guard activeModelContextDebugToolPromptMode != mode else {
      return
    }
    activeModelContextDebugToolPromptMode = mode
    invalidateModelContextDebugDocument()
  }

  func setConversationErrorMessage(_ message: String) {
    errorMessage = message
  }

  func applyWorkflowEvents(_ events: [ChatWorkflowEvent]) {
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

extension ConversationEngine {
  fileprivate func systemPrompt(toolPromptMode: ToolPromptMode) -> String {
    turnExecutionCoordinator.systemPrompt(
      session: chatSession,
      selectedModel: conversationModelState.selectedModel,
      toolLoopCoordinator: toolLoopCoordinator,
      toolPromptMode: toolPromptMode
    )
  }

  private func modelContextDebugToolPromptMode(
    workspace: Workspace?,
    sessionID: ChatSession.ID?
  ) -> ToolPromptMode {
    if activeTurnID != nil,
      let activeModelContextDebugToolPromptMode
    {
      return activeModelContextDebugToolPromptMode
    }

    return turnExecutionCoordinator.currentToolPromptMode(
      session: chatSession,
      workspace: workspace,
      sessionID: sessionID,
      selectedModel: conversationModelState.selectedModel
    )
  }

  private func disableUnsupportedInteractionModeIfNeeded() {
    let selectedModel = conversationModelState.selectedModel
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
    case .userMessageAppended,
      .userMessagePromptContextUpdated,
      .toolResultAppended,
      .assistantMessageAppended,
      .todoStateChanged:
      return true
    case .turnStatusChanged(_, _, let modelContextPolicy):
      return modelContextPolicy != nil
    case .turnAppended,
      .assistantAnnotatedAsNativeToolCall,
      .toolCallAppended,
      .toolCallUpdated,
      .assistantPlaceholderAppended,
      .assistantThinkingPlaceholderAppended,
      .assistantChunkAppended,
      .assistantThinkingChunkAppended,
      .assistantThinkingCompleted,
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
