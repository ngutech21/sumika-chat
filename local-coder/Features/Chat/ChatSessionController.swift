// swiftlint:disable file_length
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
  var draft = ""
  var isGenerating = false
  var errorMessage: String?

  @ObservationIgnored private let runtime: any ChatModelRuntime
  @ObservationIgnored private let resourceMonitor: any ProcessResourceMonitoring
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private let modelDownloader: any ModelDownloading
  @ObservationIgnored private let toolCallParser: any ToolCallParsing
  @ObservationIgnored private let toolPromptRenderer: any ToolPromptRendering
  @ObservationIgnored private let toolOrchestrator: ToolOrchestrator
  @ObservationIgnored private let chatAttachmentLoader: any ChatAttachmentLoading
  @ObservationIgnored private var isHandlingDroppedDraftPath = false
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var modelOperationID = UUID()
  @ObservationIgnored private var generationTask: Task<Void, Never>?
  @ObservationIgnored private var resourceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var onSessionDidChange: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private let maxToolIterations = 1
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

  init(
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

    self.runtime = runtime
    self.resourceMonitor = resourceMonitor
    self.modelSettingsStore = settingsStore
    self.modelDownloader = downloader
    self.toolCallParser = toolCallParser
    self.toolPromptRenderer = toolPromptRenderer
    self.toolOrchestrator = toolOrchestrator
    self.chatAttachmentLoader = chatAttachmentLoader
    self.selectedModelID = selectedModel.id
    self.modelPath = selectedModel.localPath
    self.modelContextTokenLimit = storedSettings.contextTokenLimit
    self.chatSession = ChatSessionState(
      messages: [],
      toolCalls: [],
      attachments: [],
      systemPrompt: storedSettings.systemPrompt,
      generationSettings: storedSettings.generationSettings
    )
  }

  init(
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
    self.runtime = runtime
    self.resourceMonitor = resourceMonitor
    self.modelSettingsStore = modelSettingsStore
    self.modelDownloader = modelDownloader
    self.toolCallParser = toolCallParser
    self.toolPromptRenderer = toolPromptRenderer
    self.toolOrchestrator = toolOrchestrator
    self.chatAttachmentLoader = chatAttachmentLoader
    self.selectedModelID = ManagedModelCatalog.defaultModelID
    self.modelPath = modelPath
    self.modelContextTokenLimit = ManagedModelCatalog.defaultModel.defaultContextTokenLimit
  }

  deinit {
    loadTask?.cancel()
    downloadTask?.cancel()
    generationTask?.cancel()
    resourceMonitorTask?.cancel()
  }

  func prepareDefaultModelDirectory() {
    do {
      let baseURL = try LocalModelDirectory.ensureDefaultBaseDirectoryExists()
      if modelPath.isEmpty {
        modelPath = selectedModel.localPath
      } else if !modelPath.hasPrefix(baseURL.path(percentEncoded: false)) {
        modelPath = selectedModel.localPath
      }
    } catch {
      errorMessage = error.localizedDescription
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
    cancelGeneration()
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
      modelState = .notLoaded
      Task {
        await runtime.unload()
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
    let modelDirectory = model.localDirectoryURL
    let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: modelDirectory.path(percentEncoded: false),
        isDirectory: &isDirectory
      ), isDirectory.boolValue
    else {
      return false
    }

    return FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false))
  }

  func downloadSelectedModel() {
    guard !downloadState.isDownloading else {
      return
    }

    let model = selectedModel
    downloadTask?.cancel()
    downloadProgress = nil
    downloadState = .downloading(progress: nil)
    errorMessage = nil

    downloadTask = Task {
      do {
        _ = try await modelDownloader.download(model: model) { progress in
          let fraction = Self.normalizedDownloadProgress(progress)
          self.downloadProgress = fraction
          self.downloadState = .downloading(progress: self.downloadProgress)
        }
        try Task.checkCancellation()
        downloadState = .downloaded
        downloadProgress = 1
        modelPath = model.localPath
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
    modelOperationID = UUID()
    let operationID = modelOperationID

    loadTask = Task {
      errorMessage = nil
      modelState = .loading

      do {
        try validateModelDirectory(directoryURL)
        try Task.checkCancellation()
        let configuration = ChatModelConfiguration(
          localModelDirectory: directoryURL,
          contextTokenLimit: effectiveContextTokenLimit(for: directoryURL)
        )
        try await runtime.load(configuration: configuration)
        try Task.checkCancellation()
        guard operationID == modelOperationID else {
          return
        }
        modelState = .ready
        await updateContextUsage()
      } catch is CancellationError {
        if operationID == modelOperationID {
          modelState = .notLoaded
          contextUsage = nil
        }
      } catch {
        guard operationID == modelOperationID else {
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
    modelOperationID = UUID()
    loadTask?.cancel()
    loadTask = nil
    cancelGeneration()
    errorMessage = nil
    modelState = .notLoaded
    contextUsage = nil

    Task {
      await runtime.unload()
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
        let allowsToolCalls = shouldAllowToolCalls(
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
    generationTask?.cancel()
    generationTask = nil
    isGenerating = false
  }

  func clearChatHistory() {
    chatSession.messages.removeAll()
    chatSession.attachments.removeAll()
    contextUsage = nil
    notifySessionDidChange()

    Task {
      await runtime.clearContext()
      await updateContextUsage()
    }
  }

  func refreshContextUsage() {
    Task {
      await updateContextUsage()
    }
  }

  func effectiveContextTokenLimit(for modelDirectory: URL) -> Int {
    let modelLimit = LocalModelDirectory.readContextTokenLimit(from: modelDirectory)
    let requestedLimit = max(modelContextTokenLimit, 1)

    guard let modelLimit else {
      return requestedLimit
    }

    return min(requestedLimit, modelLimit)
  }

  func updateContextUsage() async {
    guard modelState == .ready else {
      contextUsage = nil
      return
    }

    do {
      contextUsage = try await runtime.contextUsage(
        for: chatSession.messages,
        attachments: chatSession.attachments,
        systemPrompt: systemPrompt(toolPromptMode: .disabled)
      )
    } catch {
      contextUsage = nil
    }
  }

  func addAttachments(from urls: [URL]) {
    do {
      let attachments = try chatAttachmentLoader.loadAttachments(
        from: urls,
        existingAttachments: chatSession.attachments
      )
      chatSession.attachments.append(contentsOf: attachments)
      errorMessage = nil
      refreshContextUsage()
    } catch {
      errorMessage = error.localizedDescription
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

  private func messageContent(for id: UUID) -> String {
    chatSession.messages.first(where: { $0.id == id })?.content ?? ""
  }

  private func validateModelDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    let path = url.path(percentEncoded: false)

    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw LocalModelDirectoryError.notFound(path)
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
  fileprivate enum ToolPromptMode {
    case disabled
    case enabled(Bool)
    case afterToolResult
  }

  fileprivate func streamAssistantReply(to assistantMessageID: UUID, toolPromptMode: ToolPromptMode)
    async throws
  {
    let stream = try await runtime.streamReply(
      for: chatSession.messages,
      attachments: [],
      systemPrompt: systemPrompt(toolPromptMode: toolPromptMode),
      settings: chatSession.generationSettings
    )

    var bufferedChunk = ""
    var lastFlushDate = Date()

    func flushBufferedChunks() {
      guard !bufferedChunk.isEmpty else {
        return
      }

      appendChunk(bufferedChunk, to: assistantMessageID)
      bufferedChunk = ""
      lastFlushDate = Date()
    }

    func shouldFlushBufferedChunks() -> Bool {
      bufferedChunk.count >= streamingFlushCharacterLimit
        || Date().timeIntervalSince(lastFlushDate) >= streamingFlushInterval
    }

    defer {
      flushBufferedChunks()
    }

    for try await event in stream {
      switch event {
      case .chunk(let chunk):
        bufferedChunk += chunk
        if shouldFlushBufferedChunks() {
          flushBufferedChunks()
        }
      case .completed(let metrics):
        flushBufferedChunks()
        updateGenerationMetrics(metrics, for: assistantMessageID)
        await updateContextUsage()
      }
    }
  }

  fileprivate func runReadOnlyToolLoop(
    workspace: Workspace?,
    sessionID: CodingSession.ID?,
    lastAssistantMessageID: UUID
  ) async throws {
    guard let workspace, let sessionID else {
      return
    }

    var assistantMessageID = lastAssistantMessageID

    for _ in 0..<maxToolIterations {
      try Task.checkCancellation()
      let assistantContent = messageContent(for: assistantMessageID)
      let parseResult = try parseToolCallResult(
        assistantContent,
        workspaceID: workspace.id,
        sessionID: sessionID
      )

      guard case .toolCall(let output) = parseResult else {
        return
      }

      let request = output.request
      annotateToolCall(output.modelMessage, for: assistantMessageID)
      let record = await toolOrchestrator.execute(request: request, workspace: workspace)
      chatSession.toolCalls.append(record)
      notifySessionDidChange()

      let resultPreview =
        record.resultPreview
        ?? ToolResultPreview(
          status: .failed,
          text: "Tool result unavailable for \(request.toolName.rawValue)."
        )
      let toolResult = ToolResultModelMessage(
        callID: request.id,
        toolName: request.toolName,
        preview: resultPreview
      )
      chatSession.messages.append(
        ChatMessage(kind: .toolResult, content: "", toolResult: toolResult))

      let nextAssistantMessageID = UUID()
      chatSession.messages.append(
        ChatMessage(id: nextAssistantMessageID, kind: .assistant, content: ""))
      notifySessionDidChange()

      try await streamAssistantReply(to: nextAssistantMessageID, toolPromptMode: .afterToolResult)
      assistantMessageID = nextAssistantMessageID
    }
  }

  fileprivate func parseToolCallResult(
    _ content: String,
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID
  ) throws -> ToolCallParseResult {
    do {
      return try toolCallParser.parse(
        content,
        workspaceID: workspaceID,
        sessionID: sessionID,
        createdAt: Date()
      )
    } catch is TaggedToolCallParseError {
      guard let actionContent = recoverableToolActionContent(from: content) else {
        return .none
      }

      do {
        return try toolCallParser.parse(
          actionContent,
          workspaceID: workspaceID,
          sessionID: sessionID,
          createdAt: Date()
        )
      } catch is TaggedToolCallParseError {
        return .none
      }
    }
  }

  fileprivate func recoverableToolActionContent(from content: String) -> String? {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    if let fencedContent = singleFencedCodeBlockContent(from: trimmed) {
      return recoverableToolActionContent(from: fencedContent)
    }

    guard let actionStart = trimmed.range(of: "<action") else {
      return nil
    }
    guard
      let actionEnd = trimmed.range(
        of: "</action>", range: actionStart.upperBound..<trimmed.endIndex)
    else {
      return nil
    }

    let blockEnd = actionEnd.upperBound
    guard trimmed[blockEnd...].range(of: "<action") == nil else {
      return nil
    }

    return String(trimmed[actionStart.lowerBound..<blockEnd])
  }

  fileprivate func singleFencedCodeBlockContent(from content: String) -> String? {
    guard content.hasPrefix("```") else {
      return nil
    }

    var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 2 else {
      return nil
    }
    guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    else {
      return nil
    }
    guard let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" else {
      return nil
    }

    lines.removeFirst()
    lines.removeLast()
    return lines.joined(separator: "\n")
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
    switch toolPromptMode {
    case .disabled, .enabled(false):
      return chatSession.systemPrompt
    case .afterToolResult:
      return [
        chatSession.systemPrompt,
        """
        You just received a tool result. Use it to answer the user's request directly.
        Do not emit another <action> tag in this response.
        """,
      ].joined(separator: "\n\n")
    case .enabled(true):
      return [
        chatSession.systemPrompt,
        toolPromptRenderer.renderToolInstructions(
          registry: .promptTools,
          payloadDelimiter: "LC_PAYLOAD_V1"
        ),
      ].joined(separator: "\n\n")
    }
  }

  fileprivate func shouldAllowToolCalls(
    workspace: Workspace?,
    prompt: String,
    attachments: [ChatAttachment]
  ) -> Bool {
    guard workspace != nil else {
      return false
    }

    if !attachments.isEmpty {
      return true
    }

    let normalizedPrompt = prompt.lowercased()
    let explicitToolIntentPhrases = [
      "read ",
      "open ",
      "show ",
      "inspect",
      "look at",
      "list files",
      "list the files",
      "what files",
      "which files",
      "file",
      "folder",
      "directory",
      "workspace",
      "repo",
      "repository",
      "project",
      "source",
      "code",
      "implementation",
      "readme",
    ]

    if explicitToolIntentPhrases.contains(where: { normalizedPrompt.contains($0) }) {
      return true
    }

    return ChatAttachmentLimits.supportedTextFileExtensions.contains { fileExtension in
      normalizedPrompt.contains(".\(fileExtension)")
    }
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
