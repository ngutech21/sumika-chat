import Foundation
import Observation

@MainActor
@Observable
final class ChatSessionController {
  var availableModels = ManagedModelCatalog.models
  var selectedModelID: ManagedModel.ID
  var downloadState: ModelDownloadState = .idle
  var downloadProgress: Double?
  var modelPath: String
  var modelState: ModelLoadState = .notLoaded
  var chatSession = ChatSessionState.codingDefault
  var modelContextTokenLimit = ManagedModelCatalog.defaultContextTokenLimit
  var contextUsage: ChatContextUsage?
  var processUsage: ProcessResourceUsage?
  var modelAvailabilitySnapshot: [ManagedModel.ID: Bool] = [:]
  var draft = ""
  var isGenerating = false
  var errorMessage: String?

  @ObservationIgnored private let runtimeOperations: RuntimeOperationCoordinator
  @ObservationIgnored private let modelLifecycleCoordinator: ModelLifecycleCoordinator
  @ObservationIgnored private let chatGenerationCoordinator: ChatGenerationCoordinator
  @ObservationIgnored private let resourceMonitor: any ProcessResourceMonitoring
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private let toolPromptRenderer: any ToolPromptRendering
  @ObservationIgnored private let toolOrchestrator: ToolOrchestrator
  @ObservationIgnored private let toolPromptPolicy: ToolPromptPolicy
  @ObservationIgnored private let toolLoopCoordinator: ToolLoopCoordinator
  @ObservationIgnored private let chatAttachmentLoader: any ChatAttachmentLoading
  @ObservationIgnored private var isHandlingDroppedDraftPath = false
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var modelOperationID = UUID()
  @ObservationIgnored private var generationTask: Task<Void, Never>?
  @ObservationIgnored private var contextUsageTask: Task<Void, Never>?
  @ObservationIgnored private var contextUsageRequestID = UUID()
  @ObservationIgnored private var attachmentLoadTask: Task<Void, Never>?
  @ObservationIgnored private var attachmentLoadRequestID = UUID()
  @ObservationIgnored private var resourceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private let streamingFlushInterval: TimeInterval = 0.05
  @ObservationIgnored private let streamingFlushCharacterLimit = 240

  var canSend: Bool {
    modelState == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isGenerating
  }

  var selectedModel: ManagedModel {
    availableModels.first { $0.id == selectedModelID } ?? ManagedModelCatalog.defaultModel
  }

  var canChangeModel: Bool {
    !isGenerating && modelState != .loading && !downloadState.isDownloading
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
    self.runtimeOperations = runtimeOperations
    self.modelLifecycleCoordinator = ModelLifecycleCoordinator(
      modelDownloader: modelDownloader,
      runtimeOperations: runtimeOperations
    )
    self.chatGenerationCoordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: streamingFlushInterval,
      streamingFlushCharacterLimit: streamingFlushCharacterLimit
    )
    self.resourceMonitor = resourceMonitor
    self.modelSettingsStore = modelSettingsStore
    self.toolPromptRenderer = toolPromptRenderer
    self.toolOrchestrator = toolOrchestrator
    self.toolPromptPolicy = ToolPromptPolicy()
    self.toolLoopCoordinator = ToolLoopCoordinator(
      toolCallParser: toolCallParser,
      toolOrchestrator: toolOrchestrator
    )
    self.chatAttachmentLoader = chatAttachmentLoader
    self.selectedModelID = selectedModelID
    self.modelPath = modelPath
    self.modelContextTokenLimit = modelContextTokenLimit
    self.chatSession = chatSession
    self.modelOperationID = modelOperationID
    refreshModelAvailability()
  }

  deinit {
    loadTask?.cancel()
    downloadTask?.cancel()
    generationTask?.cancel()
    contextUsageTask?.cancel()
    attachmentLoadTask?.cancel()
    resourceMonitorTask?.cancel()
  }
}

extension ChatSessionController {
  func prepareDefaultModelDirectory() {
    let lifecycleCoordinator = modelLifecycleCoordinator
    Task {
      do {
        let baseURL = try await Task.detached {
          try lifecycleCoordinator.ensureDefaultModelDirectoryExists()
        }.value
        if modelPath.isEmpty {
          modelPath = selectedModel.localPath
        } else if !modelPath.hasPrefix(baseURL.path(percentEncoded: false)) {
          modelPath = selectedModel.localPath
        }
        refreshModelAvailability()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func startResourceMonitoring() {
    guard resourceMonitorTask == nil else {
      return
    }

    resourceMonitorTask = Task {
      while !Task.isCancelled {
        processUsage = await resourceMonitor.currentUsage()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func setModelDirectory(_ url: URL) {
    modelPath = url.path(percentEncoded: false)
    modelState = .notLoaded
    errorMessage = nil
    clearChatHistory()
  }

  func selectModel(_ model: ManagedModel) {
    guard canChangeModel, selectedModelID != model.id else {
      return
    }

    unloadModel()
    selectedModelID = model.id
    modelSettingsStore.setSelectedModelID(model.id)
    modelPath = model.localPath
    downloadState = .idle
    downloadProgress = nil
    errorMessage = nil
    clearChatHistory()

    let settings = modelSettingsStore.settings(for: model)
    chatSession.systemPrompt = settings.systemPrompt
    chatSession.generationSettings = settings.generationSettings
    modelContextTokenLimit = settings.contextTokenLimit
    notifySessionDidChange()
  }

  func setSessionChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
    onSessionDidChange = handler
  }

  func loadSession(_ session: CodingSession) {
    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel
    let shouldUnloadRuntime = selectedModelID != model.id && modelState != .notLoaded

    loadTask?.cancel()
    loadTask = nil
    cancelGeneration(notify: false)
    selectedModelID = model.id
    modelPath = model.localPath
    downloadState = .idle
    downloadProgress = nil
    errorMessage = nil
    contextUsage = nil
    chatSession = ChatSessionState(
      messages: session.messages,
      toolCalls: session.toolCalls,
      attachments: [],
      systemPrompt: session.systemPrompt,
      generationSettings: session.generationSettings
    )
    modelContextTokenLimit = modelSettingsStore.settings(for: model).contextTokenLimit

    if shouldUnloadRuntime {
      let operationID = UUID()
      modelOperationID = operationID
      contextUsageRequestID = UUID()
      modelState = .notLoaded
      contextUsage = nil
      Task {
        await runtimeOperations.setCurrentOperation(operationID)
        do {
          try await modelLifecycleCoordinator.unloadModel(operationID: operationID)
        } catch is CancellationError {
        } catch {
          guard await runtimeOperations.isCurrent(operationID) else {
            return
          }
          errorMessage = error.localizedDescription
        }
      }
    } else {
      refreshContextUsage()
    }
  }

  func sessionSnapshot(updating session: CodingSession) -> CodingSession {
    var snapshot = session
    snapshot.selectedModelID = selectedModelID
    snapshot.messages = chatSession.messages
    snapshot.toolCalls = chatSession.toolCalls
    snapshot.systemPrompt = chatSession.systemPrompt
    snapshot.generationSettings = chatSession.generationSettings
    snapshot.updatedAt = Date()
    return snapshot
  }

  func isModelDownloaded(_ model: ManagedModel) -> Bool {
    modelAvailabilitySnapshot[model.id] ?? false
  }

  func refreshModelAvailability() {
    let models = availableModels
    let lifecycleCoordinator = modelLifecycleCoordinator
    Task {
      let snapshot = await Task.detached {
        lifecycleCoordinator.modelAvailabilitySnapshot(for: models)
      }.value
      modelAvailabilitySnapshot = snapshot
    }
  }

  func downloadSelectedModel() {
    guard !downloadState.isDownloading else {
      return
    }

    let model = selectedModel
    let lifecycleCoordinator = modelLifecycleCoordinator
    downloadTask?.cancel()
    downloadProgress = nil
    downloadState = .downloading(progress: nil)
    errorMessage = nil

    downloadTask = Task {
      do {
        let result = try await lifecycleCoordinator.download(model: model) { progress in
          let fraction = Self.normalizedDownloadProgress(progress)
          self.downloadProgress = fraction
          self.downloadState = .downloading(progress: self.downloadProgress)
        }
        try Task.checkCancellation()
        downloadState = .downloaded
        downloadProgress = 1
        modelPath = result.localPath
        modelAvailabilitySnapshot[model.id] = true
      } catch is CancellationError {
        downloadState = .idle
        downloadProgress = nil
      } catch {
        downloadState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
        downloadProgress = nil
      }

      downloadTask = nil
    }
  }

  func saveSelectedModelSettings() {
    let settings = StoredModelSettings(
      systemPrompt: chatSession.systemPrompt,
      generationSettings: chatSession.generationSettings,
      contextTokenLimit: modelContextTokenLimit
    )

    do {
      try modelSettingsStore.save(settings: settings, for: selectedModel)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadSelectedModel() {
    modelPath = selectedModel.localPath
    loadModel()
  }

  func loadModel() {
    guard !downloadState.isDownloading else {
      return
    }

    let trimmedPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else {
      errorMessage = "Choose a local model directory before loading."
      return
    }

    let directoryURL = URL(filePath: trimmedPath, directoryHint: .isDirectory)
    loadTask?.cancel()
    let operationID = UUID()
    modelOperationID = operationID
    contextUsageRequestID = UUID()
    let lifecycleCoordinator = modelLifecycleCoordinator
    let runtimeOperations = runtimeOperations
    let requestedContextTokenLimit = modelContextTokenLimit

    loadTask = Task {
      await runtimeOperations.setCurrentOperation(operationID)
      errorMessage = nil
      modelState = .loading

      do {
        let result = try await lifecycleCoordinator.loadModel(
          from: directoryURL,
          requestedContextTokenLimit: requestedContextTokenLimit,
          operationID: operationID
        )
        try Task.checkCancellation()
        guard await runtimeOperations.isCurrent(operationID), operationID == modelOperationID else {
          return
        }
        modelState = .ready
        contextUsage = result.contextUsage
        await updateContextUsage()
      } catch is CancellationError {
        if await runtimeOperations.isCurrent(operationID), operationID == modelOperationID {
          modelState = .notLoaded
          contextUsage = nil
        }
      } catch {
        guard await runtimeOperations.isCurrent(operationID), operationID == modelOperationID else {
          return
        }
        modelState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
      }

      if operationID == modelOperationID {
        loadTask = nil
      }
    }
  }

  func unloadModel() {
    let operationID = UUID()
    modelOperationID = operationID
    contextUsageRequestID = UUID()
    loadTask?.cancel()
    cancelGeneration()
    errorMessage = nil
    modelState = .notLoaded
    contextUsage = nil
    let lifecycleCoordinator = modelLifecycleCoordinator
    let runtimeOperations = runtimeOperations

    loadTask = Task {
      await runtimeOperations.setCurrentOperation(operationID)
      do {
        try await lifecycleCoordinator.unloadModel(operationID: operationID)
      } catch is CancellationError {
      } catch {
        guard await runtimeOperations.isCurrent(operationID), operationID == modelOperationID else {
          return
        }
        errorMessage = error.localizedDescription
      }
      if await runtimeOperations.isCurrent(operationID), operationID == modelOperationID {
        loadTask = nil
      }
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
    contextUsage = nil
    let requestID = UUID()
    contextUsageRequestID = requestID
    notifySessionDidChange()

    let operationID = modelOperationID
    let lifecycleCoordinator = modelLifecycleCoordinator
    Task {
      do {
        try await lifecycleCoordinator.clearContext(operationID: operationID)
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
      }
      guard requestID == contextUsageRequestID else {
        return
      }
      await updateContextUsage()
    }
  }

  func refreshContextUsage() {
    let requestID = UUID()
    contextUsageRequestID = requestID
    contextUsageTask?.cancel()
    contextUsageTask = Task {
      await updateContextUsage()
    }
  }

  func updateContextUsage() async {
    guard modelState == .ready else {
      contextUsage = nil
      return
    }

    let requestID = contextUsageRequestID
    let operationID = modelOperationID
    let messages = chatSession.messages
    let attachments = chatSession.attachments
    let prompt = systemPrompt(toolPromptMode: .disabled)
    let lifecycleCoordinator = modelLifecycleCoordinator

    do {
      let usage = try await lifecycleCoordinator.contextUsage(
        for: messages,
        attachments: attachments,
        systemPrompt: prompt,
        operationID: operationID
      )
      guard requestID == contextUsageRequestID, operationID == modelOperationID else {
        return
      }
      contextUsage = usage
    } catch is CancellationError {
    } catch {
      guard requestID == contextUsageRequestID, operationID == modelOperationID else {
        return
      }
      contextUsage = nil
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

  private static func normalizedDownloadProgress(_ progress: Progress) -> Double? {
    let fraction = progress.fractionCompleted
    guard fraction.isFinite else {
      return nil
    }

    return min(max(fraction, 0), 1)
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

enum ModelDownloadState: Equatable {
  case idle
  case downloading(progress: Double?)
  case downloaded
  case failed(String)

  var isDownloading: Bool {
    if case .downloading = self {
      return true
    }

    return false
  }

  var label: String {
    switch self {
    case .idle:
      "Not downloaded"
    case .downloading(let progress):
      if let progress {
        "Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))"
      } else {
        "Downloading"
      }
    case .downloaded:
      "Downloaded"
    case .failed:
      "Download failed"
    }
  }
}

enum ModelLoadState: Equatable {
  case notLoaded
  case loading
  case ready
  case failed(String)

  var label: String {
    switch self {
    case .notLoaded:
      "No model loaded"
    case .loading:
      "Loading model"
    case .ready:
      "Model ready"
    case .failed:
      "Model failed"
    }
  }

  var systemImage: String {
    switch self {
    case .notLoaded:
      "circle"
    case .loading:
      "clock"
    case .ready:
      "checkmark.circle.fill"
    case .failed:
      "xmark.octagon.fill"
    }
  }
}

enum LocalModelDirectoryError: LocalizedError {
  case notFound(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let path):
      "Model directory does not exist: \(path)"
    }
  }
}
