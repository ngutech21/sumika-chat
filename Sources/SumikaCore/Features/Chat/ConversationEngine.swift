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
    var pendingAttachments: [ChatAttachment] = []
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
  private var pendingAttachments: [ChatAttachment] {
    get {
      guard let attachments = activeConversation?.pendingAttachments else {
        preconditionFailure("ConversationEngine requires an active conversation")
      }
      return attachments
    }
    set {
      guard activeConversation != nil else {
        preconditionFailure("ConversationEngine requires an active conversation")
      }
      activeConversation?.pendingAttachments = newValue
      syncComposerSessionState()
    }
  }
  private(set) var composerSessionState = ChatComposerSessionState()
  private(set) var modelContextDebugState = ModelContextDebugState()
  var isGenerating = false
  private(set) var isLoadingAttachments = false
  private(set) var isPreparingTurn = false
  private(set) var errorMessage: String?
  private(set) var skillCatalogSnapshot = SkillCatalogSnapshot.empty

  @ObservationIgnored private let conversationModel: @MainActor () -> ConversationModelState
  @ObservationIgnored private let runtimeContextClearCoordinator: RuntimeContextClearCoordinator
  @ObservationIgnored private let chatGenerationCoordinator: ChatGenerationCoordinator
  @ObservationIgnored private var toolOrchestrator: ToolOrchestrator
  @ObservationIgnored private let toolLoopCoordinator: ToolLoopCoordinator
  @ObservationIgnored var activeTurnID: ChatTurn.ID?
  @ObservationIgnored var activeTurnTask: Task<Void, Never>?
  @ObservationIgnored var turnToolOrchestrators: [ChatTurn.ID: ToolOrchestrator] = [:]
  @ObservationIgnored let turnExecutionCoordinator: ChatTurnExecutionCoordinator
  @ObservationIgnored var workspaceInstructionsLoader: any WorkspaceInstructionsLoading
  @ObservationIgnored let skillCatalog: SkillCatalog
  @ObservationIgnored private var skillCatalogRefreshTask: Task<Void, Never>?
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
      && !isPreparingTurn
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
    skillCatalog: SkillCatalog = SkillCatalog(),
    turnTracer: any TurnTracing = NoopTurnTracer()
  ) {
    self.conversationModel = conversationModel
    self.runtimeContextClearCoordinator = runtimeContextClearCoordinator
    self.chatGenerationCoordinator = chatGenerationCoordinator
    self.turnExecutionCoordinator = ChatTurnExecutionCoordinator(
      turnTracer: turnTracer
    )
    self.workspaceInstructionsLoader = workspaceInstructionsLoader
    self.skillCatalog = skillCatalog
    self.toolOrchestrator = toolOrchestrator
    self.toolLoopCoordinator = ToolLoopCoordinator(
      turnTracer: turnTracer
    )
    self.attachmentCoordinator = ChatAttachmentCoordinator(loader: chatAttachmentLoader)
  }

  deinit {
    activeTurnTask?.cancel()
    skillCatalogRefreshTask?.cancel()
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
    if isGenerating || isLoadingAttachments || isPreparingTurn {
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
    if hasActiveConversation {
      notifySessionDidChange()
    }

    clearRuntimeContextForReuse()
  }

  private func handleModelRuntimeDidReset() {
    updateRuntimeCacheDebugSnapshot(nil)
  }

  private func syncComposerSessionState() {
    let nextState =
      activeConversation.map {
        ChatComposerSessionState(
          session: $0.session,
          pendingAttachments: $0.pendingAttachments
        )
      }
      ?? ChatComposerSessionState()
    guard composerSessionState != nextState else {
      return
    }
    composerSessionState = nextState
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
    updateRuntimeCacheDebugSnapshot(nil)
    activeConversation = ActiveConversation(workspace: workspace, session: session)
    skillCatalogSnapshot = .empty
    syncComposerSessionState()
    applyConfiguredAgentToolsForActiveSession()
    disableUnsupportedInteractionModeIfNeeded()
    invalidateModelContextDebugDocument()
    scheduleSkillCatalogRefreshIfNeeded()

    guard prepareRuntimeContext else {
      return
    }

    guard !modelRuntimeWasReset, conversationModelState.loadState != .loading else {
      return
    }
    clearRuntimeContextForReuse()
  }

  func sessionSnapshot() -> ChatSession {
    var snapshot = chatSession
    snapshot.selectedModelID = conversationModelState.selectedModel.id
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
    skillCatalogRefreshTask?.cancel()
    skillCatalogRefreshTask = nil
    skillCatalogSnapshot = .empty
    composerSessionState = ChatComposerSessionState()
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
    if mode == .agent {
      scheduleSkillCatalogRefreshIfNeeded()
    } else {
      skillCatalogRefreshTask?.cancel()
      skillCatalogRefreshTask = nil
      skillCatalogSnapshot = .empty
    }
    errorMessage = nil
    invalidateModelContextDebugDocument()
    clearRuntimeContextForReuse()
    notifySessionDidChange()
  }

  func setReasoningSelection(_ selection: ReasoningSelection) {
    let resolvedSelection = conversationModelState.selectedModel.reasoningCapability.resolving(
      selection
    )
    guard hasActiveConversation, canChangeInteractionMode,
      chatSession.generationSettings.reasoningSelection != resolvedSelection
    else {
      return
    }

    chatSession.generationSettings.reasoningSelection = resolvedSelection
    errorMessage = nil
    invalidateModelContextDebugDocument()
    clearRuntimeContextForReuse()
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
      configuredAgentToolExecutorRegistry(selectedMCPServerIDs: selectedServerIDs)
    )
  }

  private func setAgentToolExecutorRegistry(_ executorRegistry: ToolExecutorRegistry) {
    guard !isGenerating, !isInputBlocked else {
      pendingAgentToolExecutorRegistry = executorRegistry
      return
    }
    applyAgentToolExecutorRegistry(executorRegistry)
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
    cancelGeneration shouldCancelGeneration: Bool
  ) {
    if shouldCancelGeneration {
      cancelGeneration()
    }
    if hasActiveConversation {
      errorMessage = nil
    }
  }

  private func applyAgentToolExecutorRegistry(_ executorRegistry: ToolExecutorRegistry) {
    toolOrchestrator = toolOrchestrator.replacingExecutorRegistry(executorRegistry)
    invalidateModelContextDebugDocument()
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
      configuredAgentToolExecutorRegistry(selectedMCPServerIDs: serverIDs)
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

  func finishGeneratingTurn() {
    isGenerating = false
    applyPendingConversationUpdates()
  }

  func refreshSkillCatalog() async throws -> SkillCatalogSnapshot {
    guard let workspace = activeWorkspace else {
      throw ConversationIntentError.inactive
    }
    guard chatSession.interactionMode == .agent else {
      skillCatalogSnapshot = .empty
      return .empty
    }
    let workspaceID = workspace.id
    let sessionID = chatSession.id
    let snapshot = await skillCatalog.refresh(for: workspace)
    guard matches(workspaceID: workspaceID, sessionID: sessionID),
      chatSession.interactionMode == .agent
    else {
      return skillCatalogSnapshot
    }
    skillCatalogSnapshot = snapshot
    return snapshot
  }

  private func scheduleSkillCatalogRefreshIfNeeded() {
    guard let workspace = activeWorkspace, chatSession.interactionMode == .agent else {
      return
    }
    let workspaceID = workspace.id
    let sessionID = chatSession.id
    skillCatalogRefreshTask?.cancel()
    skillCatalogRefreshTask = Task { [weak self] in
      guard let self else { return }
      let snapshot = await skillCatalog.refresh(for: workspace)
      guard !Task.isCancelled,
        matches(workspaceID: workspaceID, sessionID: sessionID),
        chatSession.interactionMode == .agent
      else {
        return
      }
      skillCatalogSnapshot = snapshot
    }
  }

  func sendMessage(_ submission: MessageSubmission) async throws {
    guard let workspace = activeWorkspace,
      let sessionID = activeSessionID
    else {
      throw ConversationIntentError.inactive
    }
    let prompt = submission.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let attachmentsForTurn = pendingAttachments
    do {
      try ChatAttachmentLimits.validateContent(of: attachmentsForTurn)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
    guard selectedModel.supportsImageInput || !attachmentsForTurn.hasImages
    else {
      errorMessage = unsupportedImageInputMessage(for: selectedModel)
      throw ConversationIntentError.unsupportedImageInput
    }

    isPreparingTurn = true
    defer { isPreparingTurn = false }
    let interactionMode = chatSession.interactionMode
    let preparedSkills: PreparedSkillSubmission
    do {
      preparedSkills = try await skillCatalog.prepareSubmission(
        submission,
        mode: interactionMode,
        workspace: workspace
      )
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
    guard matches(workspaceID: workspace.id, sessionID: sessionID),
      chatSession.interactionMode == interactionMode,
      conversationModelState.loadState == .ready
    else {
      throw ConversationIntentError.busy(workspaceID: workspace.id, sessionID: sessionID)
    }

    updateDefaultSessionTitleIfNeeded(fromFirstPrompt: prompt)
    applyPendingAgentToolExecutorRegistry()
    errorMessage = nil
    pendingAttachments.removeAll()
    isGenerating = true

    startUserTurn(
      prompt: prompt,
      workspace: workspace,
      sessionID: sessionID,
      attachments: attachmentsForTurn,
      preparedSkills: preparedSkills,
      runtime: turnRuntimeContext(),
      runtimeContextClearCoordinator: runtimeContextClearCoordinator
    )
  }

  // Test-only convenience that still enters the canonical asynchronous submission path.
  // swiftlint:disable:next unused_declaration
  func sendMessage(prompt: String) async throws {
    try await sendMessage(MessageSubmission(text: prompt))
  }

  /// Internal compatibility seam for focused engine tests. Package callers use
  /// `ConversationFeature.activate` followed by `sendMessage(_:)`.
  @discardableResult
  // swiftlint:disable:next unused_declaration
  func sendMessage(
    prompt: String,
    in workspace: Workspace,
    sessionID: ChatSession.ID
  ) async -> Bool {
    guard activeSessionID == sessionID,
      workspace.sessions.contains(where: { $0.id == sessionID })
    else {
      errorMessage = "The active chat session does not belong to the workspace."
      return false
    }
    activeConversation?.workspace = workspace
    do {
      try await sendMessage(MessageSubmission(text: prompt))
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
      applyPendingConversationUpdates()
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
    pendingAttachments.removeAll()
    transcriptMutator.clearTranscript(in: &chatSession)
    updateRuntimeCacheDebugSnapshot(nil)
    invalidateModelContextDebugDocument()
    notifySessionDidChange()

    clearRuntimeContextForReuse()
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
      includingTurnID: activeTurnID,
      supportsHistoricalReasoningPreservation:
        conversationModelState.selectedModel.supportsHistoricalReasoningPreservation
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
        self?.applyPendingConversationUpdates()
      }
    }
  }

  private func applyPendingConversationUpdates() {
    if activeModelContextDebugToolPromptMode != nil {
      activeModelContextDebugToolPromptMode = nil
      invalidateModelContextDebugDocument()
    }
    applyPendingAgentToolExecutorRegistry()
  }

  private func applyPendingAgentToolExecutorRegistry() {
    guard let pendingAgentToolExecutorRegistry else {
      return
    }
    self.pendingAgentToolExecutorRegistry = nil
    if let pendingSelectedMCPServerIDs {
      self.pendingSelectedMCPServerIDs = nil
      chatSession.setSelectedMCPServerIDs(pendingSelectedMCPServerIDs)
      notifySessionDidChange()
    }
    applyAgentToolExecutorRegistry(pendingAgentToolExecutorRegistry)
  }

  func addAttachments(from urls: [URL]) {
    guard hasActiveConversation, !isGenerating, !isInputBlocked else {
      return
    }
    isLoadingAttachments = true
    attachmentCoordinator.addAttachments(
      from: urls,
      existingAttachments: pendingAttachments,
      onEvent: handleAttachmentEvent(_:))
  }

  func removeAttachment(id: ChatAttachment.ID) {
    guard hasActiveConversation, !activity.isBusy else {
      return
    }
    pendingAttachments.removeAll { $0.id == id }
  }

  private func handleAttachmentEvent(_ event: ChatAttachmentEvent) {
    guard hasActiveConversation else {
      return
    }
    isLoadingAttachments = false
    switch event {
    case .appendAttachments(let attachments):
      pendingAttachments.append(contentsOf: attachments)
      errorMessage = nil
    case .error(let message):
      errorMessage = message
    }
  }

  func notifySessionDidChange() {
    publishSessionSnapshot()
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
    guard let turnID = chatSession.turnID(containingToolCall: toolCallID),
      let turn = chatSession.turns.first(where: { $0.id == turnID }),
      let batch = turn.toolCallBatch(containing: toolCallID),
      let approvalGroup = batch.pendingApprovalGroup(containing: toolCallID)
    else {
      return
    }

    isGenerating = true
    errorMessage = nil
    if approvalGroup.isAtomicSameFileEdit {
      approveToolCallBatch(
        approvalGroup.records,
        batchAnchorID: approvalGroup.anchorID,
        in: workspace,
        turnID: turnID,
        runtime: turnRuntimeContext()
      )
    } else {
      approveToolCall(
        existingRecord,
        in: workspace,
        turnID: turnID,
        runtime: turnRuntimeContext()
      )
    }
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
    guard pendingRecords.count >= 2 else {
      return
    }

    isGenerating = true
    errorMessage = nil
    approveToolCallBatch(
      pendingRecords,
      batchAnchorID: batch.anchorID,
      in: workspace,
      turnID: turnID,
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
      !batch.pendingApprovalRecords.isEmpty
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
    guard let turnID = chatSession.turnID(containingToolCall: toolCallID),
      let turn = chatSession.turns.first(where: { $0.id == turnID }),
      let batch = turn.toolCallBatch(containing: toolCallID),
      let approvalGroup = batch.pendingApprovalGroup(containing: toolCallID)
    else {
      return
    }

    isGenerating = true
    errorMessage = nil
    denyToolCalls(
      approvalGroup.records,
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
    if promptMode == .afterToolBudgetExhausted {
      return ToolRegistry(tools: [.finishTask])
    }

    let profile: ToolExecutionProfile
    switch promptMode {
    case .chatWeb, .afterChatWebToolResultCanContinue, .afterChatWebToolResultFinal:
      profile = .chatWeb
    case .agent, .afterToolResultCanContinue, .afterToolBudgetExhausted,
      .afterToolResultFinal:
      profile = .agent
    case .disabled:
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
      .assistantThinkingCancelled,
      .assistantGenerationCompleted,
      .assistantGenerationOutputLimitReached,
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
