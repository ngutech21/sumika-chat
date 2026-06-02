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
  @ObservationIgnored private let chatAttachmentLoader: any ChatAttachmentLoading
  @ObservationIgnored private var isHandlingDroppedDraftPath = false
  @ObservationIgnored private var generationTask: Task<Void, Never>?
  @ObservationIgnored private var attachmentLoadTask: Task<Void, Never>?
  @ObservationIgnored private var attachmentLoadRequestID = UUID()
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
    self.chatAttachmentLoader = chatAttachmentLoader
    self.chatSession = chatSession
    configureModelRuntimeCallbacks()
  }

  deinit {
    generationTask?.cancel()
    attachmentLoadTask?.cancel()
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
    chatSession.messages.append(
      ChatMessage(kind: .user, content: prompt, attachments: sentAttachments))
    let assistantMessageID = UUID()
    chatSession.messages.append(ChatMessage(id: assistantMessageID, kind: .assistant, content: ""))
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
        removeTransientAssistantPlaceholders()
        await updateContextUsage()
      } catch {
        removeTransientAssistantPlaceholders()
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
    removeTransientAssistantPlaceholders()
    if notify {
      notifySessionDidChange()
    }
  }

  func clearChatHistory() {
    chatSession.messages.removeAll()
    chatSession.attachments.removeAll()
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
    let requestID = UUID()
    attachmentLoadRequestID = requestID
    attachmentLoadTask?.cancel()
    let existingAttachments = chatSession.attachments
    let loader = chatAttachmentLoader

    attachmentLoadTask = Task {
      do {
        let attachments = try await Task.detached {
          try loader.loadAttachments(
            from: urls,
            existingAttachments: existingAttachments
          )
        }.value
        guard requestID == attachmentLoadRequestID else {
          return
        }
        chatSession.attachments.append(contentsOf: attachments)
        errorMessage = nil
        refreshContextUsage()
      } catch is CancellationError {
      } catch {
        guard requestID == attachmentLoadRequestID else {
          return
        }
        errorMessage = error.localizedDescription
      }

      if requestID == attachmentLoadRequestID {
        attachmentLoadTask = nil
      }
    }
  }

  func convertDroppedFilePathsInDraft() {
    guard !isHandlingDroppedDraftPath, !isGenerating else {
      return
    }

    let droppedFiles = chatAttachmentLoader.extractDroppedAttachments(from: draft)
    guard !droppedFiles.urls.isEmpty else {
      return
    }

    isHandlingDroppedDraftPath = true
    draft = droppedFiles.cleanedDraft
    addAttachments(from: droppedFiles.urls)
    isHandlingDroppedDraftPath = false
  }

  func removeAttachment(id: ChatAttachment.ID) {
    chatSession.attachments.removeAll { $0.id == id }
    refreshContextUsage()
  }

  private func appendChunk(_ chunk: String, to messageID: UUID) {
    guard let index = chatSession.messages.firstIndex(where: { $0.id == messageID }) else {
      return
    }

    let message = chatSession.messages[index]
    chatSession.messages[index] = ChatMessage(
      id: message.id,
      kind: message.kind,
      content: message.content + chunk,
      attachments: message.attachments,
      generationMetrics: message.generationMetrics,
      toolCall: message.toolCall,
      toolResult: message.toolResult
    )
  }

  private func updateGenerationMetrics(_ metrics: ChatGenerationMetrics?, for messageID: UUID) {
    guard let index = chatSession.messages.firstIndex(where: { $0.id == messageID }) else {
      return
    }

    let message = chatSession.messages[index]
    chatSession.messages[index] = ChatMessage(
      id: message.id,
      kind: message.kind,
      content: message.content,
      attachments: message.attachments,
      generationMetrics: metrics,
      toolCall: message.toolCall,
      toolResult: message.toolResult
    )
  }

  private func notifySessionDidChange() {
    onSessionDidChange?()
  }

  private func removeMessage(id: UUID) {
    chatSession.messages.removeAll { $0.id == id }
  }

  private func removeTransientAssistantPlaceholders() {
    chatSession.messages.removeAll { message in
      message.kind == .assistant
        && message.content.isEmpty
    }
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
        appendChunk(chunk, to: assistantMessageID)
      },
      updateGenerationMetrics: { metrics in
        updateGenerationMetrics(metrics, for: assistantMessageID)
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

    annotateToolCall(result.toolCall, for: result.assistantMessageID)
    chatSession.toolCalls.append(result.toolCallRecord)
    notifySessionDidChange()
    chatSession.messages.append(
      ChatMessage(kind: .toolResult, content: "", toolResult: result.toolResult))
    chatSession.messages.append(
      ChatMessage(id: result.nextAssistantMessageID, kind: .assistant, content: ""))
    notifySessionDidChange()
    try await streamAssistantReply(
      to: result.nextAssistantMessageID,
      toolPromptMode: .afterToolResult
    )
  }

  fileprivate func annotateToolCall(_ toolCall: ToolCallModelMessage, for messageID: UUID) {
    guard let index = chatSession.messages.firstIndex(where: { $0.id == messageID }) else {
      return
    }

    let message = chatSession.messages[index]
    chatSession.messages[index] = ChatMessage(
      id: message.id,
      kind: .toolCall,
      content: "",
      attachments: message.attachments,
      generationMetrics: message.generationMetrics,
      toolCall: toolCall,
      toolResult: nil
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
