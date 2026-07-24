import Foundation
import Observation

#if canImport(OSLog)
  import OSLog
#endif

@MainActor
@Observable
final class ConversationEngine {
  private struct ActiveConversation {
    var workspace: Workspace
    var session: ChatSession
  }

  private var activeConversation: ActiveConversation?
  var chatSession: ChatSession {
    get {
      guard let session = activeConversation?.session else {
        preconditionFailure("ConversationEngine requires an active conversation")
      }
      return session
    }
    set {
      guard activeConversation != nil else {
        preconditionFailure("ConversationEngine requires an active conversation")
      }
      activeConversation?.session = newValue
      syncComposerSessionState()
    }
  }
  private(set) var composerSessionState = ChatComposerSessionState()
  private(set) var modelContextDebugState = ModelContextDebugState()
  var contextUsage: ChatContextUsage?
  var isGenerating = false
  private(set) var isLoadingAttachments = false
  private(set) var errorMessage: String?

  @ObservationIgnored private let conversationModel: @MainActor () -> ConversationModelState
  @ObservationIgnored private let runtimeContextClearCoordinator: RuntimeContextClearCoordinator
  @ObservationIgnored private let chatGenerationCoordinator: ChatGenerationCoordinator
  @ObservationIgnored private var toolOrchestrator: ToolOrchestrator
  @ObservationIgnored private let toolLoopCoordinator: ToolLoopCoordinator
  @ObservationIgnored private let turnTracer: any TurnTracing
  @ObservationIgnored var activeTurnID: ChatTurn.ID?
  @ObservationIgnored var activeTurnTask: Task<Void, Never>?
  @ObservationIgnored var turnToolOrchestrators: [ChatTurn.ID: ToolOrchestrator] = [:]
  @ObservationIgnored let turnExecutionCoordinator: ChatTurnExecutionCoordinator
  @ObservationIgnored var workspaceInstructionsLoader: any WorkspaceInstructionsLoading
  @ObservationIgnored let toolResumeCoordinator = ToolResumeCoordinator()
  @ObservationIgnored private let modelContextBuilder = ChatModelContextBuilder()
  @ObservationIgnored private let attachmentCoordinator: ChatAttachmentCoordinator
  @ObservationIgnored private let transcriptMutator = ChatTranscriptMutator()
  @ObservationIgnored private let workflowEventApplier = ChatWorkflowEventApplier()
  @ObservationIgnored private var onSessionDidChange:
    (@MainActor @Sendable (Workspace.ID, ChatSession) -> Void)?
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

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func canSend(prompt: String) -> Bool {
    hasActiveConversation
      && conversationModelState.loadState == .ready
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
      && !isInputBlocked
      && !isLoadingAttachments
  }

  var hasPendingApproval: Bool {
    guard hasActiveConversation else {
      return false
    }
    return chatSession.containsToolCall { $0.status == .awaitingApproval }
  }

  var hasPendingUserAnswer: Bool {
    guard hasActiveConversation else {
      return false
    }
    return chatSession.containsToolCall { $0.status == .awaitingUserAnswer }
  }

  var isInputBlocked: Bool {
    hasPendingApproval || hasPendingUserAnswer
  }

  var canChangeInteractionMode: Bool {
    hasActiveConversation && !activity.isBusy
  }

  var canChangeMCPServerSelection: Bool {
    hasActiveConversation && chatSession.interactionMode == .agent && canChangeInteractionMode
  }

  var canEnableAutomaticToolApproval: Bool {
    hasActiveConversation
      && chatSession.interactionMode == .agent
      && chatSession.toolApprovalPolicy == .manual
      && !isGenerating
      && !hasPendingUserAnswer
  }

  init(
    conversationModel: @escaping @MainActor () -> ConversationModelState,
    runtimeContextClearCoordinator: RuntimeContextClearCoordinator,
    chatGenerationCoordinator: ChatGenerationCoordinator,
    toolOrchestrator: ToolOrchestrator = ToolOrchestrator.agent(todoWriteEnabled: true),
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader(),
    workspaceInstructionsLoader: any WorkspaceInstructionsLoading =
      WorkspaceInstructionsLoader(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.conversationModel = conversationModel
    self.runtimeContextClearCoordinator = runtimeContextClearCoordinator
    self.chatGenerationCoordinator = chatGenerationCoordinator
    self.turnTracer = turnTracer
    self.turnExecutionCoordinator = ChatTurnExecutionCoordinator(
      turnTracer: turnTracer
    )
    self.workspaceInstructionsLoader = workspaceInstructionsLoader
    self.toolOrchestrator = toolOrchestrator
    self.toolLoopCoordinator = ToolLoopCoordinator(
      turnTracer: turnTracer
    )
    self.attachmentCoordinator = ChatAttachmentCoordinator(loader: chatAttachmentLoader)
  }

  deinit {
    activeTurnTask?.cancel()
  }
}

extension ConversationEngine {
  private var conversationModelState: ConversationModelState {
    conversationModel()
  }

  var hasActiveConversation: Bool {
    activeConversation != nil
  }

  var activeWorkspaceID: Workspace.ID? {
    activeConversation?.workspace.id
  }

  var activeSessionID: ChatSession.ID? {
    activeConversation?.session.id
  }

  var activeWorkspace: Workspace? {
    activeConversation?.workspace
  }

  var activity: ConversationActivity {
    if hasPendingApproval {
      return .awaitingApproval
    }
    if hasPendingUserAnswer {
      return .awaitingUserAnswer
    }
    if isGenerating || isLoadingAttachments {
      return .working
    }
    return .idle
  }

  var busyError: ConversationIntentError {
    guard let workspaceID = activeWorkspaceID,
      let sessionID = activeSessionID
    else {
      return .inactive
    }
    return .busy(workspaceID: workspaceID, sessionID: sessionID)
  }

  func matches(workspaceID: Workspace.ID, sessionID: ChatSession.ID) -> Bool {
    activeWorkspaceID == workspaceID && activeSessionID == sessionID
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func updateActiveWorkspace(_ workspace: Workspace) {
    guard let sessionID = activeSessionID,
      workspace.sessions.contains(where: { $0.id == sessionID })
    else {
      return
    }
    activeConversation?.workspace = workspace
  }

  func modelManagementEventHandlers(
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
    if hasActiveConversation {
      chatSession.modeSettings = settings.modeSettings
    }
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateModelContextDebugDocument()
    invalidateContextUsage()
    if hasActiveConversation {
      notifySessionDidChange()
    }

    clearRuntimeContextForReuse()
    refreshContextUsage()
  }

  private func handleModelRuntimeDidReset() {
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateContextUsage()
  }

  private func syncComposerSessionState() {
    let nextState =
      activeConversation.map { Self.composerSessionState(for: $0.session) }
      ?? ChatComposerSessionState()
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

  func setSessionChangeHandler(
    _ handler: (@MainActor @Sendable (Workspace.ID, ChatSession) -> Void)?
  ) {
    onSessionDidChange = handler
  }

  // Test-only convenience overload; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func setSessionChangeHandler(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) {
    onSessionDidChange = { _, _ in handler() }
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var sessionID: ChatSession.ID {
    chatSession.id
  }

  var turns: [ChatTurn] {
    chatSession.turns
  }

  var activeModeSettings: ChatModeSettingsSet? {
    activeConversation?.session.modeSettings
  }

  @discardableResult
  func updateModeSettings(_ modeSettings: ChatModeSettingsSet) -> Bool {
    guard hasActiveConversation, chatSession.modeSettings != modeSettings else {
      return false
    }

    chatSession.modeSettings = modeSettings
    refreshContextUsage()
    notifySessionDidChange()
    return true
  }

  @discardableResult
  func renameSession(to title: String) -> Bool {
    guard hasActiveConversation else {
      return false
    }
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      return false
    }

    chatSession.title = trimmedTitle
    notifySessionDidChange()
    return true
  }

  func installConversation(
    _ session: ChatSession,
    in workspace: Workspace,
    modelRuntimeWasReset: Bool,
    prepareRuntimeContext: Bool = true
  ) {
    errorMessage = nil
    contextUsage = nil
    updateRuntimeCacheDebugSnapshot(nil)
    activeConversation = ActiveConversation(workspace: workspace, session: session)
    syncComposerSessionState()
    applyConfiguredAgentToolsForActiveSession()
    disableUnsupportedInteractionModeIfNeeded()
    invalidateModelContextDebugDocument()

    guard prepareRuntimeContext else {
      return
    }

    if modelRuntimeWasReset {
      invalidateContextUsage()
    } else if conversationModelState.loadState == .loading {
      invalidateContextUsage()
    } else {
      clearRuntimeContextForReuse()
      refreshContextUsage()
    }
  }

  func sessionSnapshot() -> ChatSession {
    var snapshot = chatSession
    snapshot.selectedModelID = conversationModelState.selectedModel.id
    snapshot.pendingAttachments = []
    snapshot.updatedAt = Date()
    return snapshot
  }

  func activeSessionSnapshot() -> ChatSession? {
    guard hasActiveConversation else {
      return nil
    }
    return sessionSnapshot()
  }

  func publishSessionSnapshot() {
    guard let workspaceID = activeWorkspaceID,
      let snapshot = activeSessionSnapshot()
    else {
      return
    }
    onSessionDidChange?(workspaceID, snapshot)
  }

  func deactivate() {
    guard hasActiveConversation else {
      return
    }
    cancelGeneration(notify: false)
    attachmentCoordinator.cancelLoading()
    isLoadingAttachments = false
    publishSessionSnapshot()
    activeConversation = nil
    composerSessionState = ChatComposerSessionState()
    contextUsage = nil
    errorMessage = nil
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateModelContextDebugDocument()
    clearRuntimeContextForReuse()
  }

  func setInteractionMode(_ mode: WorkspaceInteractionMode) {
    guard hasActiveConversation, canChangeInteractionMode, chatSession.interactionMode != mode
    else {
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

  func setReasoningEnabled(_ isEnabled: Bool) {
    guard hasActiveConversation, canChangeInteractionMode,
      chatSession.generationSettings.reasoningEnabled != isEnabled
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

  func enableAutomaticToolApproval() {
    guard canEnableAutomaticToolApproval else {
      return
    }

    chatSession.toolApprovalPolicy = .automatic
    errorMessage = nil
    notifySessionDidChange()

    guard let batchAnchorID = latestPendingApprovalBatchAnchorID else {
      return
    }
    resumeAutomaticApprovalBatch(containing: batchAnchorID)
  }

  // Test-only workspace adapter; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func enableAutomaticToolApproval(in workspace: Workspace) {
    activeConversation?.workspace = workspace
    enableAutomaticToolApproval()
  }

  func disableAutomaticToolApproval() {
    guard hasActiveConversation, chatSession.toolApprovalPolicy != .manual else {
      return
    }

    chatSession.toolApprovalPolicy = .manual
    errorMessage = nil
    notifySessionDidChange()
  }

  func configureAgentTools(
    todoWriteEnabled: Bool,
    mcpExecutorGroups: [MCPAgentToolExecutorGroup] = []
  ) {
    updateAgentToolConfiguration(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: mcpExecutorGroups
    )
    guard hasActiveConversation else {
      return
    }
    let selectedServerIDs = pendingSelectedMCPServerIDs ?? chatSession.selectedMCPServerIDs
    setAgentToolExecutorRegistry(
      configuredAgentToolExecutorRegistry(selectedMCPServerIDs: selectedServerIDs)
    )
  }

  /// Reconciles connected MCP contributions and persisted selection as one
  /// Core operation so the matching registry is installed or deferred with
  /// the selection that produced it.
  func reconcileAgentTools(
    todoWriteEnabled: Bool,
    mcpExecutorGroups: [MCPAgentToolExecutorGroup],
    selectedMCPServerIDs: [UUID]
  ) {
    updateAgentToolConfiguration(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: mcpExecutorGroups
    )
    guard hasActiveConversation else {
      return
    }
    reconcileSelectedMCPServerIDs(selectedMCPServerIDs)
  }

  private func applyConfiguredAgentToolsForActiveSession() {
    guard hasActiveConversation else {
      return
    }
    let selectedServerIDs = chatSession.selectedMCPServerIDs
    applyAgentToolExecutorRegistry(
      configuredAgentToolExecutorRegistry(selectedMCPServerIDs: selectedServerIDs),
      shouldRefreshContext: false
    )
  }

  private func setAgentToolExecutorRegistry(_ executorRegistry: ToolExecutorRegistry) {
    guard !isGenerating, !isInputBlocked else {
      pendingAgentToolExecutorRegistry = executorRegistry
      return
    }
    applyAgentToolExecutorRegistry(executorRegistry, shouldRefreshContext: true)
  }

  func setSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    guard canChangeMCPServerSelection else {
      return
    }
    applySelectedMCPServerIDs(serverIDs)
  }

  /// Reconciles persisted selection with global MCP configuration. Unlike a
  /// user action this may run in Chat mode, but it is deferred across an
  /// active generation or unresolved interaction so validated calls keep the
  /// registry that created them.
  func reconcileSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    guard hasActiveConversation else {
      return
    }
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

  func prepareForModelRuntimeAction(
    cancelGeneration shouldCancelGeneration: Bool,
    invalidateContext shouldInvalidateContext: Bool
  ) {
    if shouldCancelGeneration {
      cancelGeneration()
    }
    if hasActiveConversation {
      errorMessage = nil
    }
    if shouldInvalidateContext, hasActiveConversation {
      invalidateContextUsage()
    }
  }

  private func applyAgentToolExecutorRegistry(
    _ executorRegistry: ToolExecutorRegistry,
    shouldRefreshContext: Bool
  ) {
    toolOrchestrator = toolOrchestrator.replacingExecutorRegistry(executorRegistry)
    invalidateModelContextDebugDocument()
    if shouldRefreshContext {
      clearRuntimeContextForReuse()
      refreshContextUsage()
    }
  }

  private func applySelectedMCPServerIDs(
    _ serverIDs: [UUID]
  ) {
    guard hasActiveConversation else {
      return
    }
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

  func sendMessage(prompt rawPrompt: String) throws {
    guard let workspace = activeWorkspace,
      let sessionID = activeSessionID
    else {
      throw ConversationIntentError.inactive
    }
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      throw ConversationIntentError.emptyPrompt
    }
    guard conversationModelState.loadState == .ready else {
      throw ConversationIntentError.modelNotReady
    }
    guard !activity.isBusy else {
      throw busyError
    }
    let selectedModel = conversationModelState.selectedModel
    guard selectedModel.supports(interactionMode: chatSession.interactionMode) else {
      errorMessage = unsupportedInteractionModeMessage(for: selectedModel)
      throw ConversationIntentError.unsupportedInteractionMode
    }
    let attachmentsForTurn = attachmentsForCurrentTurn()
    guard selectedModel.supportsImageInput || !attachmentsForTurn.hasImages
    else {
      errorMessage = unsupportedImageInputMessage(for: selectedModel)
      throw ConversationIntentError.unsupportedImageInput
    }

    let sentAttachments = attachmentsForTurn
    updateDefaultSessionTitleIfNeeded(fromFirstPrompt: prompt)
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
  }

  /// Internal compatibility seam for focused engine tests. Package callers use
  /// `ConversationFeature.activate` followed by `sendMessage(prompt:)`.
  @discardableResult
  // swiftlint:disable:next unused_declaration
  func sendMessage(
    prompt: String,
    in workspace: Workspace,
    sessionID: ChatSession.ID
  ) -> Bool {
    guard activeSessionID == sessionID,
      workspace.sessions.contains(where: { $0.id == sessionID })
    else {
      errorMessage = "The active chat session does not belong to the workspace."
      return false
    }
    activeConversation?.workspace = workspace
    do {
      try sendMessage(prompt: prompt)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func updateDefaultSessionTitleIfNeeded(fromFirstPrompt prompt: String) {
    guard chatSession.title == ChatSession.defaultTitle,
      chatSession.turns.flatMap(\.items).allSatisfy({ $0.userContent == nil })
    else {
      return
    }

    chatSession.title = ChatSessionTitleGenerator.title(fromFirstPrompt: prompt)
  }

  func cancelGeneration() {
    guard hasActiveConversation else {
      return
    }
    cancelGeneration(notify: true)
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

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func clearChatHistory() {
    guard hasActiveConversation else {
      return
    }
    transcriptMutator.clearTranscript(in: &chatSession)
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateModelContextDebugDocument()
    invalidateContextUsage()
    notifySessionDidChange()

    clearRuntimeContextForReuse()
    refreshContextUsage()
  }

  func refreshContextUsage() {
    guard hasActiveConversation else {
      contextUsage = nil
      return
    }
    refreshContextUsage(toolPromptMode: .disabled)
  }

  func refreshContextUsage(toolPromptMode: ToolPromptMode) {
    guard hasActiveConversation else {
      contextUsage = nil
      return
    }
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

  func modelContextDebugDocument(
    workspace: Workspace? = nil,
    sessionID: ChatSession.ID? = nil
  ) throws -> ModelContextDebugDocument {
    guard hasActiveConversation else {
      throw ConversationIntentError.inactive
    }
    let workspace = workspace ?? activeWorkspace
    let sessionID = sessionID ?? activeSessionID
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

  func addAttachments(from urls: [URL]) {
    guard hasActiveConversation, !isGenerating, !isInputBlocked else {
      return
    }
    isLoadingAttachments = true
    attachmentCoordinator.addAttachments(
      from: urls,
      existingAttachments: chatSession.pendingAttachments,
      onEvent: handleAttachmentEvent(_:))
  }

  func removeAttachment(id: ChatAttachment.ID) {
    guard hasActiveConversation, !activity.isBusy else {
      return
    }
    attachmentCoordinator.removeAttachment(id: id, onEvent: handleAttachmentEvent(_:))
  }

  private func handleAttachmentEvent(_ event: ChatAttachmentEvent) {
    guard hasActiveConversation else {
      return
    }
    isLoadingAttachments = false
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
    notifySessionDidChange()
  }

  func notifySessionDidChange() {
    publishSessionSnapshot()
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

  func approveToolCall(id toolCallID: ToolCallRecord.ID) {
    guard let workspace = activeWorkspace else {
      return
    }
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
      toolOrchestrator: toolOrchestrator(for: existingRecord, turnID: turnID),
      runtime: turnRuntimeContext()
    )
  }

  // Test-only workspace adapter; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func approveToolCall(id toolCallID: ToolCallRecord.ID, in workspace: Workspace) {
    activeConversation?.workspace = workspace
    approveToolCall(id: toolCallID)
  }

  func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID
  ) {
    guard let workspace = activeWorkspace else {
      return
    }
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
      toolOrchestrator: toolOrchestrator(for: firstRecord, turnID: turnID),
      runtime: turnRuntimeContext()
    )
  }

  // Test-only workspace adapter; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func approveToolCallBatch(
    containing batchAnchorID: ToolCallRecord.ID,
    in workspace: Workspace
  ) {
    activeConversation?.workspace = workspace
    approveToolCallBatch(containing: batchAnchorID)
  }

  func resumeAutomaticApprovalBatch(
    containing batchAnchorID: ToolCallRecord.ID
  ) {
    guard let workspace = activeWorkspace else {
      return
    }
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
      toolOrchestrator: toolOrchestrator(for: firstRecord, turnID: turnID),
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

  private func toolOrchestrator(
    for record: ToolCallRecord,
    turnID: ChatTurn.ID
  ) -> ToolOrchestrator {
    if let frozenOrchestrator = turnToolOrchestrators[turnID] {
      return frozenOrchestrator
    }
    let profile: ToolExecutionProfile =
      if chatSession.interactionMode == .chat,
        record.request.toolName == .webSearch || record.request.toolName == .webFetch
      {
        .chatWeb
      } else {
        .agent
      }
    let selectedOrchestrator = effectiveToolOrchestrator(for: profile) ?? toolOrchestrator
    turnToolOrchestrators[turnID] = selectedOrchestrator
    return selectedOrchestrator
  }

  func effectiveToolOrchestrator(
    for profile: ToolExecutionProfile
  ) -> ToolOrchestrator? {
    switch profile {
    case .disabled:
      return nil
    case .chatWeb:
      return toolOrchestrator.replacingExecutorRegistry(.chatWeb)
    case .agent:
      return toolOrchestrator
    }
  }

  func answerAskUserToolCall(
    id toolCallID: ToolCallRecord.ID,
    answer rawAnswer: String
  ) {
    guard let workspace = activeWorkspace else {
      return
    }
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

  // Test-only workspace adapter; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func answerAskUserToolCall(
    id toolCallID: ToolCallRecord.ID,
    answer: String,
    in workspace: Workspace
  ) {
    activeConversation?.workspace = workspace
    answerAskUserToolCall(id: toolCallID, answer: answer)
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
      toolLoopCoordinator: toolLoopCoordinator
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
      toolPromptMode: toolPromptMode,
      toolRegistry: effectiveToolRegistry(for: toolPromptMode)
    )
  }

  private func effectiveToolRegistry(for promptMode: ToolPromptMode) -> ToolRegistry {
    let profile: ToolExecutionProfile
    switch promptMode {
    case .chatWeb, .afterChatWebToolResultCanContinue, .afterChatWebToolResultFinal:
      profile = .chatWeb
    case .enabled(true), .afterToolResultCanContinue, .afterToolResultFinal:
      profile = .agent
    case .disabled, .enabled(false):
      profile = .disabled
    }
    return effectiveToolOrchestrator(for: profile)?.toolRegistry ?? ToolRegistry(tools: [])
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
    guard hasActiveConversation else {
      return
    }
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
