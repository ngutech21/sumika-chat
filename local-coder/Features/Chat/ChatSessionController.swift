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
  @ObservationIgnored private let attachmentCoordinator: ChatAttachmentCoordinator
  @ObservationIgnored private let transcriptMutator = ChatTranscriptMutator()
  @ObservationIgnored private var generationTask: Task<Void, Never>?
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private let streamingFlushInterval: TimeInterval = 0.05
  @ObservationIgnored private let streamingFlushCharacterLimit = 240

  var canSend: Bool {
    modelRuntime.modelState == .ready
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
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
    toolOrchestrator: ToolOrchestrator = ToolOrchestrator(),
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader()
  ) {
    let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
    let selectedModelID = settingsStore.selectedModelID(availableModelIDs: availableModelIDs)
    let selectedModel =
      ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
    let storedSettings = settingsStore.settings(for: selectedModel)
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
  }

  convenience init(
    runtime: any ChatModelRuntime,
    resourceMonitor: any ProcessResourceMonitoring = ProcessResourceMonitor(),
    modelPath: String,
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    modelDownloader: any ModelDownloading = HuggingFaceModelDownloader(),
    toolCallParser: any ToolCallParsing = TaggedToolCallParser(),
    toolPromptRenderer: any ToolPromptRendering = TaggedToolPromptRenderer(),
    toolOrchestrator: ToolOrchestrator = ToolOrchestrator(),
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

  deinit {
    generationTask?.cancel()
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

  func selectModel(_ model: ManagedModel) {
    guard !isGenerating, modelRuntime.canChangeModel else {
      return
    }

    errorMessage = nil
    modelRuntime.selectModel(model)
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
    snapshot.systemPrompt = chatSession.systemPrompt
    snapshot.generationSettings = chatSession.generationSettings
    snapshot.updatedAt = Date()
    return snapshot
  }

  func downloadSelectedModel() {
    errorMessage = nil
    modelRuntime.downloadSelectedModel()
  }

  func saveSelectedModelSettings() {
    modelRuntime.saveSelectedModelSettings(
      systemPrompt: chatSession.systemPrompt,
      generationSettings: chatSession.generationSettings
    )
  }

  func loadSelectedModel() {
    errorMessage = nil
    invalidateContextUsage()
    modelRuntime.loadSelectedModel()
  }

  func loadModel() {
    errorMessage = nil
    invalidateContextUsage()
    modelRuntime.loadModel()
  }

  func unloadModel() {
    cancelGeneration()
    errorMessage = nil
    invalidateContextUsage()
    modelRuntime.unloadModel()
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
    draft = ""
    errorMessage = nil
    chatSession.attachments.removeAll()
    transcriptMutator.appendUserMessage(prompt, attachments: sentAttachments, to: &chatSession)
    let assistantMessageID = UUID()
    transcriptMutator.appendAssistantPlaceholder(id: assistantMessageID, to: &chatSession)
    isGenerating = true
    notifySessionDidChange()

    generationTask = Task {
      do {
        let allowsToolCalls = toolPromptPolicy.shouldAllowToolCalls(
          workspace: workspace,
          prompt: prompt,
          attachments: sentAttachments
        )
        await updateContextUsage()
        try await streamAssistantReply(
          to: assistantMessageID, toolPromptMode: .enabled(allowsToolCalls))
        if allowsToolCalls {
          try await runReadOnlyToolLoop(
            workspace: workspace,
            sessionID: sessionID,
            lastAssistantMessageID: assistantMessageID
          )
        }
      } catch is CancellationError {
        transcriptMutator.removeTransientAssistantPlaceholders(from: &chatSession)
        await updateContextUsage()
      } catch {
        transcriptMutator.removeTransientAssistantPlaceholders(from: &chatSession)
        errorMessage = error.localizedDescription
        await updateContextUsage()
      }

      isGenerating = false
      generationTask = nil
      notifySessionDidChange()
    }
  }

  func cancelGeneration() {
    cancelGeneration(notify: true)
  }

  private func cancelGeneration(notify: Bool) {
    generationTask?.cancel()
    generationTask = nil
    isGenerating = false
    transcriptMutator.removeTransientAssistantPlaceholders(from: &chatSession)
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
      messages: chatSession.messages,
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

}

extension ChatSessionController {
  fileprivate func streamAssistantReply(to assistantMessageID: UUID, toolPromptMode: ToolPromptMode)
    async throws
  {
    try await chatGenerationCoordinator.streamAssistantReply(
      messages: chatSession.messages,
      systemPrompt: systemPrompt(toolPromptMode: toolPromptMode),
      settings: chatSession.generationSettings,
      appendChunk: { chunk in
        transcriptMutator.appendChunk(chunk, to: assistantMessageID, in: &chatSession)
      },
      updateGenerationMetrics: { metrics in
        transcriptMutator.updateGenerationMetrics(
          metrics, for: assistantMessageID, in: &chatSession)
      },
      updateContextUsage: {
        await updateContextUsage()
      }
    )
  }

  fileprivate func runReadOnlyToolLoop(
    workspace: Workspace?,
    sessionID: CodingSession.ID?,
    lastAssistantMessageID: UUID
  ) async throws {
    guard let workspace, let sessionID else {
      return
    }

    guard
      let result = try await toolLoopCoordinator.run(
        ToolLoopRequest(
          workspace: workspace,
          sessionID: sessionID,
          assistantMessageID: lastAssistantMessageID,
          messages: chatSession.messages
        )
      )
    else {
      return
    }

    transcriptMutator.annotateToolCall(
      result.toolCall,
      for: result.assistantMessageID,
      in: &chatSession
    )
    chatSession.toolCalls.append(result.toolCallRecord)
    notifySessionDidChange()
    transcriptMutator.appendToolResult(result.toolResult, to: &chatSession)
    transcriptMutator.appendAssistantPlaceholder(
      id: result.nextAssistantMessageID, to: &chatSession)
    notifySessionDidChange()
    try await streamAssistantReply(
      to: result.nextAssistantMessageID,
      toolPromptMode: .afterToolResult
    )
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
