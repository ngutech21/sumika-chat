import Foundation
import LocalCoderCore
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

nonisolated enum GemmaMLXRuntimeError: LocalizedError {
  case modelNotLoaded
  case missingUserMessage
  case invalidChatTemplateMessageSequence
  case unsupportedArchitecture
  case unsupportedImageInput
  case interruptedStream

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      "Load a local Gemma model before sending a message."
    case .missingUserMessage:
      "Enter a message before generating a reply."
    case .invalidChatTemplateMessageSequence:
      "The chat history contains a message role sequence that cannot be rendered by the model template."
    case .unsupportedArchitecture:
      "Local Gemma inference through MLX requires an Apple Silicon Mac."
    case .unsupportedImageInput:
      "The selected local model cannot analyze images. Select a vision-capable Gemma 4 model or remove the image attachment."
    case .interruptedStream:
      "Local Gemma generation ended before the model reported completion."
    }
  }
}

nonisolated enum GemmaMemoryClearReason: String, Equatable, Sendable {
  case unload
  case clearContext = "clear_context"
  case runtimeError = "runtime_error"
  case interruptedStream = "interrupted_stream"
}

nonisolated enum GemmaModelStreamTermination: Equatable, Sendable {
  case completed
  case downstreamTerminated
  case cancelled
  case nativeToolCallBoundary
  case runtimeError
  case interruptedStream
}

nonisolated struct GemmaMemoryCacheClearer: Sendable {
  static let live = GemmaMemoryCacheClearer { _ in
    Memory.clearCache()
  }

  let clearCache: @Sendable (GemmaMemoryClearReason) async -> Void

  init(_ clearCache: @escaping @Sendable (GemmaMemoryClearReason) async -> Void) {
    self.clearCache = clearCache
  }
}

nonisolated enum GemmaSessionCacheMode: String, Equatable, Sendable {
  case newSessionHistory = "new_session_history"
  case sessionReused = "session_reused"
  case invalidatedSignatureMismatch = "invalidated_signature_mismatch"
  case invalidatedCancelled = "invalidated_cancelled"
  case invalidatedInterrupted = "invalidated_interrupted"
  case invalidatedDownstreamTerminated = "invalidated_downstream_terminated"
  case invalidatedRuntimeError = "invalidated_runtime_error"
  case invalidatedModelChanged = "invalidated_model_changed"
  case invalidatedNativeToolCallBoundary = "invalidated_native_tool_call_boundary"
}

nonisolated enum GemmaSessionInvalidationReason: Equatable, Sendable {
  case signatureMismatch
  case cancelled
  case interrupted
  case downstreamTerminated
  case runtimeError
  case modelChanged
  case nativeToolCallBoundary

  var cacheMode: GemmaSessionCacheMode {
    switch self {
    case .signatureMismatch:
      .invalidatedSignatureMismatch
    case .cancelled:
      .invalidatedCancelled
    case .interrupted:
      .invalidatedInterrupted
    case .downstreamTerminated:
      .invalidatedDownstreamTerminated
    case .runtimeError:
      .invalidatedRuntimeError
    case .modelChanged:
      .invalidatedModelChanged
    case .nativeToolCallBoundary:
      .invalidatedNativeToolCallBoundary
    }
  }
}

nonisolated enum GemmaSessionCacheReason: String, Equatable, Sendable {
  case sessionReused = "session_reused"
  case newSessionNoCache = "new_session_no_cache"
  case invalidatedGenCancelled = "invalidated_generation_cancelled"
  case invalidatedGenInterrupted = "invalidated_generation_interrupted"
  case invalidatedGenDownstreamTerminated = "invalidated_generation_downstream_terminated"
  case invalidatedGenRuntimeError = "invalidated_generation_runtime_error"
  case invalidatedSettingsChanged = "invalidated_settings_changed"
  case invalidatedRendererVersionChanged = "invalidated_renderer_version_changed"
  case invalidatedRenderedContextChanged = "invalidated_rendered_context_signature_changed"
  case invalidatedSystemPromptChanged = "invalidated_system_prompt_changed"
  case invalidatedHistoryAppended = "invalidated_history_appended"
  case invalidatedHistoryPrefixMismatch = "invalidated_history_prefix_mismatch"
  case invalidatedCurrentPromptContextBoundary = "invalidated_current_prompt_context_boundary"
  case invalidatedToolPromptChanged = "invalidated_tool_prompt_changed"
  case invalidatedToolSchemaChanged = "invalidated_tool_schema_changed"
  case invalidatedModelChanged = "invalidated_model_changed"
  case invalidatedRuntimeContextCleared = "invalidated_runtime_context_cleared"
  case invalidatedNativeToolCallBoundary = "invalidated_native_tool_call_boundary"
  case appendOnlyDeltaReused = "append_only_delta_reused"

  static func generationInvalidationReason(
    from reason: GemmaSessionInvalidationReason
  ) -> GemmaSessionCacheReason {
    switch reason {
    case .signatureMismatch:
      .invalidatedRuntimeContextCleared
    case .cancelled:
      .invalidatedGenCancelled
    case .interrupted:
      .invalidatedGenInterrupted
    case .downstreamTerminated:
      .invalidatedGenDownstreamTerminated
    case .runtimeError:
      .invalidatedGenRuntimeError
    case .modelChanged:
      .invalidatedModelChanged
    case .nativeToolCallBoundary:
      .invalidatedNativeToolCallBoundary
    }
  }
}

nonisolated struct GemmaMessageSnapshot: Equatable, Sendable {
  let role: String
  let content: String
  /// Identities of images prefilled with this message. Part of the prefix
  /// comparison so identical text with different images never reuses a
  /// cached session.
  let imageSignatures: [String]

  init(role: String, content: String, imageSignatures: [String] = []) {
    self.role = role
    self.content = content
    self.imageSignatures = imageSignatures
  }
}

nonisolated struct GemmaHistoryItem: Sendable {
  let role: Chat.Message.Role
  let content: String
  let imageSignatures: [String]
}

nonisolated struct GemmaRenderedContextSignature: Equatable, Sendable {
  let rendererVersion: Int
  let projectionMode: ModelContextProjectionMode
  let systemPromptHash: String
  let renderedHistoryHash: String
  let generationSettingsHash: String
  let nativeToolSchemaHash: String

  var traceValue: String {
    "renderer-v\(rendererVersion):projection-\(projectionMode.signatureComponent):system-\(systemPromptHash):history-\(renderedHistoryHash):settings-\(generationSettingsHash):tools-\(nativeToolSchemaHash)"
  }
}

nonisolated private enum CurrentPromptContextRuntimeBoundary: Equatable, Sendable {
  case attachedFile
  case focusedFile
  case ambiguousRecentFiles

  var marker: String {
    switch self {
    case .attachedFile:
      "Attached file:"
    case .focusedFile:
      "Current focused file:"
    case .ambiguousRecentFiles:
      "Recent files are ambiguous:"
    }
  }

  static let all: [CurrentPromptContextRuntimeBoundary] = [
    .attachedFile,
    .focusedFile,
    .ambiguousRecentFiles,
  ]
}

nonisolated private struct CurrentPromptContextRuntimeBoundaryMatch: Equatable, Sendable {
  let boundary: CurrentPromptContextRuntimeBoundary
  let range: Range<String.Index>
}

nonisolated private struct CurrentPromptContextRuntimeBlock: Equatable, Sendable {
  let boundary: CurrentPromptContextRuntimeBoundary
  let content: String
}

nonisolated struct GemmaGenerationID: Equatable, Hashable, Sendable {
  let rawValue: UInt64
}

nonisolated struct GemmaGenerationOwnership: Equatable, Sendable {
  private var nextRawValue: UInt64 = 0
  private(set) var activeGenerationID: GemmaGenerationID?

  mutating func beginGeneration() -> GemmaGenerationID {
    nextRawValue &+= 1
    let generationID = GemmaGenerationID(rawValue: nextRawValue)
    activeGenerationID = generationID
    return generationID
  }

  mutating func completeIfCurrent(_ generationID: GemmaGenerationID) -> Bool {
    guard activeGenerationID == generationID else {
      return false
    }
    activeGenerationID = nil
    return true
  }

  mutating func invalidateIfCurrent(_ generationID: GemmaGenerationID) -> Bool {
    guard activeGenerationID == generationID else {
      return false
    }
    activeGenerationID = nil
    return true
  }

  mutating func invalidateActiveGeneration() {
    activeGenerationID = nil
  }
}

nonisolated struct ActiveGemmaGeneration: Sendable {
  let id: GemmaGenerationID
  let task: Task<Void, Never>
}

nonisolated struct GemmaActiveGenerationRegistry: Sendable {
  private(set) var activeGeneration: ActiveGemmaGeneration?

  var activeGenerationID: GemmaGenerationID? {
    activeGeneration?.id
  }

  mutating func register(id: GemmaGenerationID, task: Task<Void, Never>) {
    activeGeneration = ActiveGemmaGeneration(id: id, task: task)
  }

  mutating func supersedeActiveGeneration() -> ActiveGemmaGeneration? {
    guard let activeGeneration else {
      return nil
    }
    self.activeGeneration = nil
    activeGeneration.task.cancel()
    return activeGeneration
  }

  @discardableResult
  mutating func clearIfCurrent(_ generationID: GemmaGenerationID) -> Bool {
    guard activeGeneration?.id == generationID else {
      return false
    }
    activeGeneration = nil
    return true
  }
}

nonisolated enum GemmaCachedSessionState: Equatable, Sendable {
  case clean
  case cleanNativeToolCallBoundary
  case inFlight(generationID: GemmaGenerationID)
  case dirty(reason: GemmaSessionInvalidationReason)

  var isReusable: Bool {
    switch self {
    case .clean, .cleanNativeToolCallBoundary:
      true
    case .inFlight, .dirty:
      false
    }
  }

  var invalidationReason: GemmaSessionInvalidationReason? {
    switch self {
    case .clean, .cleanNativeToolCallBoundary:
      nil
    case .inFlight:
      .interrupted
    case .dirty(let reason):
      reason
    }
  }

  func completing(generationID: GemmaGenerationID) -> GemmaCachedSessionState? {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .clean
  }

  func completingNativeToolCallBoundary(generationID: GemmaGenerationID) -> GemmaCachedSessionState?
  {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .cleanNativeToolCallBoundary
  }

  func invalidating(
    generationID: GemmaGenerationID,
    reason: GemmaSessionInvalidationReason
  ) -> GemmaCachedSessionState? {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .dirty(reason: reason)
  }
}

nonisolated struct GemmaSessionCacheTrace: Equatable, Sendable {
  let cacheMode: GemmaSessionCacheMode
  let cacheReason: GemmaSessionCacheReason
  let contextSignature: String
  let previousContextSignature: String?
  let appendOnly: Bool
  let reusedMessageCount: Int
  let appendedMessageCount: Int
  let mismatchReason: String?
  let firstMismatchIndex: Int?
  let systemPromptChanged: Bool?
  let currentPromptContextChanged: Bool?
}

nonisolated struct GemmaSessionCacheDecision: Equatable, Sendable {
  let reuseStrategy: GemmaSessionReuseStrategy
  let trace: GemmaSessionCacheTrace

  var shouldReuse: Bool {
    reuseStrategy != .none
  }
}

nonisolated enum GemmaSessionReuseStrategy: Equatable, Sendable {
  case none
  case exactPrompt
  case appendHistoryDelta(startIndex: Int)
}

nonisolated private struct CachedGemmaSession {
  let session: MLXLMCommon.ChatSession
  let prefix: [GemmaMessageSnapshot]
  let settings: ChatGenerationSettings
  let contextSignature: GemmaRenderedContextSignature
  let state: GemmaCachedSessionState
}

nonisolated private struct GemmaSessionCachePlan {
  let session: MLXLMCommon.ChatSession
  let trace: GemmaSessionCacheTrace
  let reuseStrategy: GemmaSessionReuseStrategy
  let streamInput: GemmaSessionStreamInput
}

nonisolated private enum GemmaSessionStreamInput {
  case prompt(String, images: [UserInput.Image])
  case messages([Chat.Message])

  var contentByteCount: Int {
    switch self {
    case .prompt(let prompt, let images):
      return prompt.utf8.count + images.count
    case .messages(let messages):
      return messages.reduce(0) { byteCount, message in
        byteCount + message.content.utf8.count + message.images.count
      }
    }
  }
}

nonisolated struct GemmaModelStreamPlan {
  let stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  let task: Task<Void, Never>
}

final actor GemmaMLXRuntime: ChatModelRuntime {
  private var modelContainer: ModelContainer?
  private var loadedModelSupportsImageInput = false
  private var cachedSession: CachedGemmaSession?
  private var pendingCacheInvalidationReason: GemmaSessionInvalidationReason?
  private var lastRuntimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot?
  private let attachmentStore = ChatAttachmentStore()
  private var contextTokenLimit: Int?
  private var generationOwnership = GemmaGenerationOwnership()
  private var activeGenerationRegistry = GemmaActiveGenerationRegistry()
  private var lifecycleTransitionInProgress = false
  private let memoryCacheClearer: GemmaMemoryCacheClearer

  init(memoryCacheClearer: GemmaMemoryCacheClearer = .live) {
    self.memoryCacheClearer = memoryCacheClearer
  }

  func load(configuration: ChatModelConfiguration) async throws {
    #if !arch(arm64)
      throw GemmaMLXRuntimeError.unsupportedArchitecture
    #endif

    lifecycleTransitionInProgress = true
    defer { lifecycleTransitionInProgress = false }
    await cancelAndDrainActiveGeneration(reason: .modelChanged)
    configureMLXMemory()

    let modelConfiguration = ModelConfiguration(
      directory: configuration.localModelDirectory,
      extraEOSTokens: ["<end_of_turn>"]
    )

    let container =
      if configuration.supportsImageInput {
        try await VLMModelFactory.shared.loadContainer(
          from: LocalDownloader(),
          using: LocalTokenizerLoader(),
          configuration: modelConfiguration
        )
      } else {
        try await LLMModelFactory.shared.loadContainer(
          from: LocalDownloader(),
          using: LocalTokenizerLoader(),
          configuration: modelConfiguration
        )
      }

    modelContainer = container
    loadedModelSupportsImageInput = configuration.supportsImageInput
    contextTokenLimit = configuration.contextTokenLimit
    lastRuntimeCacheDebugSnapshot = nil
    invalidateCachedSession(reason: .modelChanged)
  }

  func unload() async {
    lifecycleTransitionInProgress = true
    defer { lifecycleTransitionInProgress = false }
    await cancelAndDrainActiveGeneration(reason: .modelChanged)
    invalidateCachedSession(reason: .modelChanged)
    modelContainer = nil
    loadedModelSupportsImageInput = false
    contextTokenLimit = nil
    lastRuntimeCacheDebugSnapshot = nil
    await Self.clearMemoryCache(
      reason: .unload,
      traceID: nil,
      traceMetadata: TurnTraceContext.current,
      cacheTrace: nil,
      memoryCacheClearer: memoryCacheClearer
    )
  }

  func clearContext() async {
    lifecycleTransitionInProgress = true
    defer { lifecycleTransitionInProgress = false }
    await cancelAndDrainActiveGeneration(reason: .signatureMismatch)
    invalidateCachedSession(reason: .signatureMismatch)
    lastRuntimeCacheDebugSnapshot = nil
    await Self.clearMemoryCache(
      reason: .clearContext,
      traceID: nil,
      traceMetadata: TurnTraceContext.current,
      cacheTrace: nil,
      memoryCacheClearer: memoryCacheClearer
    )
  }

  func generatedTokenCount(for text: String) async throws -> Int {
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }

    return await modelContainer.perform { context in
      context.tokenizer.encode(text: text, addSpecialTokens: false).count
    }
  }

  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    lastRuntimeCacheDebugSnapshot
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }

    let rawMessages = try Self.templateMessages(
      from: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt
    )
    .map { ["role": $0.role.rawValue, "content": $0.content] as [String: any Sendable] }
    let usedTokens = try await modelContainer.perform { context in
      try context.tokenizer.applyChatTemplate(messages: rawMessages).count
    }

    return ChatContextUsage(usedTokens: usedTokens, tokenLimit: contextTokenLimit)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    try await streamReply(
      for: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt,
      settings: settings,
      toolContext: nil
    )
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    let streamStartStartedAt = Date()
    guard !lifecycleTransitionInProgress else {
      throw CancellationError()
    }
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }
    let imageAttachments = attachments.filter { $0.kind == .image }
    guard imageAttachments.isEmpty || loadedModelSupportsImageInput else {
      throw GemmaMLXRuntimeError.unsupportedImageInput
    }
    let imageInputs = try Self.imageInputs(from: imageAttachments, attachmentStore: attachmentStore)
    let projectionMode = Self.runtimeProjectionMode
    let projectedEntries = transcript.projectedEntries(mode: projectionMode)
    guard let currentPromptIndex = projectedEntries.lastIndex(where: { $0.role == .user }) else {
      throw GemmaMLXRuntimeError.missingUserMessage
    }

    let promptMessage = Self.chatMessage(
      from: projectedEntries[currentPromptIndex],
      images: imageInputs
    )
    let generateParameters = GenerateParameters(
      maxTokens: settings.maxTokens,
      maxKVSize: settings.maxKVSize,
      temperature: Float(settings.temperature),
      topP: Float(settings.topP),
      topK: settings.topK
    )
    let toolSpecs = Self.toolSpecs(from: toolContext)
    let nativeToolSchemaHash = Self.nativeToolSchemaSignature(from: toolContext)
    let cacheSystemPrompt = toolContext?.cacheSystemPrompt ?? systemPrompt
    let history = try Self.generationHistoryMessages(
      from: projectedEntries[..<currentPromptIndex]
    )
    let historySnapshot = Self.generationHistorySnapshot(
      from: projectedEntries[..<currentPromptIndex]
    )
    let promptImageSignatures = projectedEntries[currentPromptIndex].imageSignatures
    let finalPrompt = promptMessage.content
    await supersedeActiveGenerationBeforeStartingNew()
    let traceMetadata = TurnTraceContext.current
    let traceID = traceMetadata?.generationID ?? UUID()
    let generationID = generationOwnership.beginGeneration()
    let cachePlan = prepareSession(
      modelContainer: modelContainer,
      history: history,
      historySnapshot: historySnapshot,
      promptMessage: promptMessage,
      systemPrompt: systemPrompt,
      cacheSystemPrompt: cacheSystemPrompt,
      settings: settings,
      generateParameters: generateParameters,
      projectionMode: projectionMode,
      nativeToolSchemaHash: nativeToolSchemaHash,
      generationID: generationID
    )
    lastRuntimeCacheDebugSnapshot = Self.runtimeCacheDebugSnapshot(
      from: cachePlan.trace,
      reuseStrategy: cachePlan.reuseStrategy,
      generationID: traceID
    )
    cachePlan.session.tools = toolSpecs

    let traceMessages = try Self.runtimeHistoryMessages(
      systemPrompt: systemPrompt,
      history: history
    )
    let traceHistory = traceMessages.map { message in
      (role: message.role.rawValue, content: message.content)
    }
    await GemmaDebugTraceStore.shared.traceRequest(
      id: traceID,
      history: traceHistory,
      prompt: finalPrompt,
      settings: settings,
      contextTokenLimit: contextTokenLimit,
      imageAttachments: imageAttachments
    )

    let stream =
      switch cachePlan.streamInput {
      case .prompt(let prompt, let images):
        cachePlan.session.streamDetails(to: prompt, images: images, videos: [])
      case .messages(let messages):
        cachePlan.session.streamDetails(to: messages)
      }
    if let traceMetadata {
      await traceMetadata.tracer.recordTurnTraceEvent(
        TurnTraceEvent(
          turnID: traceMetadata.turnID,
          generationID: traceID,
          phase: .runtimeStreamStart,
          durationMs: Date().timeIntervalSince(streamStartStartedAt) * 1000,
          promptBytes: cachePlan.streamInput.contentByteCount,
          messageCount: projectedEntries.count,
          toolLoopIteration: traceMetadata.toolLoopIteration,
          cacheMode: cachePlan.trace.cacheMode.rawValue,
          cacheReason: cachePlan.trace.cacheReason.rawValue,
          interactionMode: traceMetadata.interactionMode,
          contextSignature: cachePlan.trace.contextSignature,
          previousContextSignature: cachePlan.trace.previousContextSignature,
          appendOnly: cachePlan.trace.appendOnly,
          reusedMessageCount: cachePlan.trace.reusedMessageCount,
          appendedMessageCount: cachePlan.trace.appendedMessageCount,
          mismatchReason: cachePlan.trace.mismatchReason,
          firstMismatchIndex: cachePlan.trace.firstMismatchIndex,
          systemPromptChanged: cachePlan.trace.systemPromptChanged,
          currentPromptContextChanged: cachePlan.trace.currentPromptContextChanged,
          imageCount: imageAttachments.isEmpty ? nil : imageAttachments.count,
          imageTypes: Self.imageTypes(from: imageAttachments),
          imageByteCount: Self.imageByteCount(from: imageAttachments)
        )
      )
    }
    let streamPlan = Self.modelStreamPlan(
      from: stream,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cachePlan.trace,
      markCompleted: { [weak self] output in
        await self?.markSessionCompleted(
          generationID: generationID,
          historyPrefix: historySnapshot,
          prompt: finalPrompt,
          promptImageSignatures: promptImageSignatures,
          output: output,
          settings: settings,
          projectionMode: projectionMode,
          nativeToolSchemaHash: nativeToolSchemaHash
        )
      },
      markNativeToolCallBoundary: { [weak self] output, nativeToolCalls in
        await self?.markSessionNativeToolCallBoundary(
          generationID: generationID,
          historyPrefix: historySnapshot,
          prompt: finalPrompt,
          promptImageSignatures: promptImageSignatures,
          output: output,
          nativeToolCalls: nativeToolCalls,
          settings: settings,
          projectionMode: projectionMode,
          nativeToolSchemaHash: nativeToolSchemaHash
        )
      },
      markCancelled: { [weak self] reason in
        await self?.markCachedSessionInvalid(generationID: generationID, reason: reason)
      }
    )
    activeGenerationRegistry.register(id: generationID, task: streamPlan.task)
    if generationOwnership.activeGenerationID != generationID {
      activeGenerationRegistry.clearIfCurrent(generationID)
    }
    return streamPlan.stream
  }

  private func supersedeActiveGenerationBeforeStartingNew() async {
    await cancelAndDrainActiveGeneration(reason: .cancelled)
  }

  private func cancelAndDrainActiveGeneration(reason: GemmaSessionInvalidationReason) async {
    guard let superseded = activeGenerationRegistry.supersedeActiveGeneration() else {
      return
    }

    markCachedSessionInvalid(generationID: superseded.id, reason: reason)
    await superseded.task.value
  }

  private func prepareSession(
    modelContainer: ModelContainer,
    history: [Chat.Message],
    historySnapshot: [GemmaMessageSnapshot],
    promptMessage: Chat.Message,
    systemPrompt: String,
    cacheSystemPrompt: String,
    settings: ChatGenerationSettings,
    generateParameters: GenerateParameters,
    projectionMode: ModelContextProjectionMode,
    nativeToolSchemaHash: String,
    generationID: GemmaGenerationID
  ) -> GemmaSessionCachePlan {
    let contextSignature = Self.renderedContextSignature(
      for: historySnapshot,
      settings: settings,
      projectionMode: projectionMode,
      systemPrompt: cacheSystemPrompt,
      nativeToolSchemaHash: nativeToolSchemaHash
    )
    let cached = cachedSession
    let decision = Self.cacheDecision(
      cachedPrefix: cached?.prefix,
      cachedSettings: cached?.settings,
      cachedContextSignature: cached?.contextSignature,
      cachedState: cached?.state ?? pendingCacheInvalidationReason.map { .dirty(reason: $0) },
      currentHistory: historySnapshot,
      currentSettings: settings,
      projectionMode: projectionMode,
      currentSystemPrompt: cacheSystemPrompt,
      currentNativeToolSchemaHash: nativeToolSchemaHash
    )
    pendingCacheInvalidationReason = nil

    if decision.shouldReuse, let cached {
      cached.session.instructions = Self.normalizedRuntimeSystemPrompt(systemPrompt)
      // Sampling params no longer invalidate the prefix, so push the current values
      // onto the reused session to ensure a mid-session change still takes effect.
      cached.session.generateParameters = generateParameters
      cachedSession = CachedGemmaSession(
        session: cached.session,
        prefix: cached.prefix,
        settings: settings,
        contextSignature: cached.contextSignature,
        state: .inFlight(generationID: generationID)
      )
      return GemmaSessionCachePlan(
        session: cached.session,
        trace: decision.trace,
        reuseStrategy: decision.reuseStrategy,
        streamInput: Self.streamInput(
          for: decision.reuseStrategy,
          history: history,
          promptMessage: promptMessage
        )
      )
    }

    let session = MLXLMCommon.ChatSession(
      modelContainer,
      instructions: Self.normalizedRuntimeSystemPrompt(systemPrompt),
      history: history,
      generateParameters: generateParameters
    )
    cachedSession = CachedGemmaSession(
      session: session,
      prefix: historySnapshot,
      settings: settings,
      contextSignature: contextSignature,
      state: .inFlight(generationID: generationID)
    )
    return GemmaSessionCachePlan(
      session: session,
      trace: decision.trace,
      reuseStrategy: decision.reuseStrategy,
      streamInput: .prompt(promptMessage.content, images: promptMessage.images)
    )
  }

  private func markSessionCompleted(
    generationID: GemmaGenerationID,
    historyPrefix: [GemmaMessageSnapshot],
    prompt: String,
    promptImageSignatures: [String],
    output: String,
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode,
    nativeToolSchemaHash: String
  ) {
    guard generationOwnership.completeIfCurrent(generationID) else {
      return
    }

    guard let cached = cachedSession,
      let completedState = cached.state.completing(generationID: generationID)
    else {
      activeGenerationRegistry.clearIfCurrent(generationID)
      return
    }

    let completedPrefix =
      historyPrefix
      + [
        GemmaMessageSnapshot(
          role: Chat.Message.Role.user.rawValue,
          content: prompt,
          imageSignatures: promptImageSignatures
        ),
        GemmaMessageSnapshot(role: Chat.Message.Role.assistant.rawValue, content: output),
      ]
    cachedSession = CachedGemmaSession(
      session: cached.session,
      prefix: completedPrefix,
      settings: settings,
      contextSignature: Self.renderedContextSignature(
        for: completedPrefix,
        settings: settings,
        projectionMode: projectionMode,
        systemPromptHash: cached.contextSignature.systemPromptHash,
        nativeToolSchemaHash: nativeToolSchemaHash
      ),
      state: completedState
    )
    activeGenerationRegistry.clearIfCurrent(generationID)
  }

  private func markSessionNativeToolCallBoundary(
    generationID: GemmaGenerationID,
    historyPrefix: [GemmaMessageSnapshot],
    prompt: String,
    promptImageSignatures: [String],
    output: String,
    nativeToolCalls: [ChatRuntimeToolCall],
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode,
    nativeToolSchemaHash: String
  ) {
    guard generationOwnership.completeIfCurrent(generationID) else {
      return
    }

    guard let cached = cachedSession,
      let completedState = cached.state.completingNativeToolCallBoundary(generationID: generationID)
    else {
      activeGenerationRegistry.clearIfCurrent(generationID)
      return
    }

    let nativeBoundary = NativeToolCallBoundaryRenderer.renderGemma4(nativeToolCalls)
    let assistantOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let assistantSnapshots =
      assistantOutput.isEmpty
      ? [GemmaMessageSnapshot(role: Chat.Message.Role.assistant.rawValue, content: nativeBoundary)]
      : [
        GemmaMessageSnapshot(role: Chat.Message.Role.assistant.rawValue, content: assistantOutput),
        GemmaMessageSnapshot(role: Chat.Message.Role.assistant.rawValue, content: nativeBoundary),
      ]
    let completedPrefix =
      historyPrefix
      + [
        GemmaMessageSnapshot(
          role: Chat.Message.Role.user.rawValue,
          content: prompt,
          imageSignatures: promptImageSignatures
        )
      ]
      + assistantSnapshots
    cachedSession = CachedGemmaSession(
      session: cached.session,
      prefix: completedPrefix,
      settings: settings,
      contextSignature: Self.renderedContextSignature(
        for: completedPrefix,
        settings: settings,
        projectionMode: projectionMode,
        systemPromptHash: cached.contextSignature.systemPromptHash,
        nativeToolSchemaHash: nativeToolSchemaHash
      ),
      state: completedState
    )
    activeGenerationRegistry.clearIfCurrent(generationID)
  }

  private func markCachedSessionInvalid(
    generationID: GemmaGenerationID,
    reason: GemmaSessionInvalidationReason
  ) {
    guard generationOwnership.invalidateIfCurrent(generationID) else {
      return
    }

    guard let cached = cachedSession,
      let dirtyState = cached.state.invalidating(generationID: generationID, reason: reason)
    else {
      activeGenerationRegistry.clearIfCurrent(generationID)
      return
    }

    cachedSession = CachedGemmaSession(
      session: cached.session,
      prefix: cached.prefix,
      settings: cached.settings,
      contextSignature: cached.contextSignature,
      state: dirtyState
    )
    activeGenerationRegistry.clearIfCurrent(generationID)
  }

  private func invalidateCachedSession(reason: GemmaSessionInvalidationReason) {
    generationOwnership.invalidateActiveGeneration()
    cachedSession = nil
    pendingCacheInvalidationReason = reason
  }

  #if DEBUG
    func registerActiveGenerationForTesting(id: GemmaGenerationID, task: Task<Void, Never>) {
      activeGenerationRegistry.register(id: id, task: task)
    }
  #endif

  private func configureMLXMemory() {
    if Memory.cacheLimit > Self.maxMLXCacheBytes {
      Memory.cacheLimit = Self.maxMLXCacheBytes
    }
  }

  nonisolated private static let maxMLXCacheBytes = 512 * 1024 * 1024
  nonisolated static let gemmaRendererVersion = 1

  /// Full history keeps the rendered transcript append-only so the cached
  /// KV prefix stays a byte-stable prefix of every later generation. Receipt
  /// compaction rewrites past observations and would invalidate the cache
  /// after every tool turn.
  nonisolated static let runtimeProjectionMode = ModelContextProjectionMode.fullHistory

  nonisolated static func messageSnapshot(from messages: [Chat.Message]) -> [GemmaMessageSnapshot] {
    messages.map { message in
      GemmaMessageSnapshot(role: message.role.rawValue, content: message.content)
    }
  }

  nonisolated static func chatMessage(
    from entry: ProjectedModelContextEntry,
    images: [UserInput.Image] = []
  ) -> Chat.Message {
    switch entry.role {
    case .user:
      return .user(entry.content, images: images)
    case .assistant:
      return .assistant(entry.content)
    }
  }

  nonisolated private static func streamInput(
    for reuseStrategy: GemmaSessionReuseStrategy,
    history: [Chat.Message],
    promptMessage: Chat.Message
  ) -> GemmaSessionStreamInput {
    switch reuseStrategy {
    case .none, .exactPrompt:
      return .prompt(promptMessage.content, images: promptMessage.images)
    case .appendHistoryDelta(let startIndex):
      let boundedStartIndex = min(max(0, startIndex), history.count)
      return .messages(Array(history[boundedStartIndex...]) + [promptMessage])
    }
  }

  nonisolated static func imageInputs(
    from attachments: [ChatAttachment],
    attachmentStore: ChatAttachmentStore = ChatAttachmentStore()
  ) throws -> [UserInput.Image] {
    try attachments.map { attachment in
      .url(try attachmentStore.validateStoredFile(for: attachment))
    }
  }

  nonisolated private static func imageTypes(from attachments: [ChatAttachment]) -> [String]? {
    let types = attachments.compactMap(\.mimeType)
    return types.isEmpty ? nil : types
  }

  nonisolated private static func imageByteCount(from attachments: [ChatAttachment]) -> Int? {
    let byteCount = attachments.reduce(0) { total, attachment in
      total + attachment.byteSize
    }
    return byteCount == 0 ? nil : byteCount
  }

  nonisolated static func cacheDecision(
    cachedPrefix: [GemmaMessageSnapshot]?,
    cachedSettings: ChatGenerationSettings?,
    cachedContextSignature: GemmaRenderedContextSignature? = nil,
    cachedState: GemmaCachedSessionState?,
    currentHistory: [GemmaMessageSnapshot],
    currentSettings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode = .fullHistory,
    currentSystemPrompt: String? = nil,
    currentNativeToolSchemaHash: String = nativeToolSchemaSignature(from: nil),
    currentRendererVersion: Int = gemmaRendererVersion
  ) -> GemmaSessionCacheDecision {
    let currentSignature = renderedContextSignature(
      for: currentHistory,
      settings: currentSettings,
      projectionMode: projectionMode,
      systemPrompt: currentSystemPrompt,
      nativeToolSchemaHash: currentNativeToolSchemaHash,
      rendererVersion: currentRendererVersion
    )
    let previousSignature =
      cachedContextSignature
      ?? cachedPrefix.flatMap { prefix in
        cachedSettings.map { settings in
          renderedContextSignature(
            for: prefix,
            settings: settings,
            projectionMode: projectionMode
          )
        }
      }
    let appendOnly = cachedPrefix.map { isPrefix($0, of: currentHistory) } ?? false
    let reusedMessageCount = appendOnly ? (cachedPrefix?.count ?? 0) : 0
    let appendedMessageCount =
      appendOnly ? max(0, currentHistory.count - (cachedPrefix?.count ?? 0)) : currentHistory.count
    let mismatchIndex: Int?
    let systemPromptChanged: Bool?
    let currentPromptContextChanged: Bool?
    if let cachedPrefix {
      mismatchIndex = firstMismatchIndex(cachedPrefix: cachedPrefix, currentHistory: currentHistory)
      let renderedHistorySystemPromptChanged =
        baseSystemInstructionBlock(from: cachedPrefix)
        != baseSystemInstructionBlock(from: currentHistory)
      let runtimeSystemPromptChanged =
        previousSignature.map { $0.systemPromptHash != currentSignature.systemPromptHash }
      systemPromptChanged =
        renderedHistorySystemPromptChanged || runtimeSystemPromptChanged == true
      currentPromptContextChanged =
        currentPromptContextBlock(from: cachedPrefix)
        != currentPromptContextBlock(from: currentHistory)
    } else {
      mismatchIndex = nil
      systemPromptChanged = nil
      currentPromptContextChanged = nil
    }

    let cacheMode: GemmaSessionCacheMode
    let cacheReason: GemmaSessionCacheReason
    let reuseStrategy: GemmaSessionReuseStrategy
    let mismatchReason: String?
    if cachedPrefix == nil, let invalidationReason = cachedState?.invalidationReason {
      cacheMode = invalidationReason.cacheMode
      cacheReason = .generationInvalidationReason(from: invalidationReason)
      reuseStrategy = .none
      mismatchReason = nil
    } else if cachedPrefix == nil {
      cacheMode = .newSessionHistory
      cacheReason = .newSessionNoCache
      reuseStrategy = .none
      mismatchReason = nil
    } else if cachedState?.isReusable != true {
      let invalidationReason = cachedState?.invalidationReason ?? .interrupted
      cacheMode = invalidationReason.cacheMode
      cacheReason = .generationInvalidationReason(from: invalidationReason)
      reuseStrategy = .none
      mismatchReason = nil
    } else if Self.cacheAffectingSettingsChanged(cachedSettings, currentSettings) {
      cacheMode = .invalidatedSignatureMismatch
      cacheReason = .invalidatedSettingsChanged
      reuseStrategy = .none
      mismatchReason = "settings_changed"
    } else if cachedPrefix == currentHistory {
      if previousSignature == currentSignature {
        cacheMode = .sessionReused
        if cachedState == .cleanNativeToolCallBoundary {
          cacheReason = .appendOnlyDeltaReused
          reuseStrategy = .appendHistoryDelta(startIndex: cachedPrefix?.count ?? 0)
        } else {
          cacheReason = .sessionReused
          reuseStrategy = .exactPrompt
        }
        mismatchReason = nil
      } else {
        cacheMode = .invalidatedSignatureMismatch
        cacheReason = Self.signatureMismatchReason(
          previousSignature: previousSignature,
          currentSignature: currentSignature
        )
        reuseStrategy = .none
        mismatchReason = "rendered_context_signature_changed"
      }
    } else if appendOnly {
      if Self.canReuseAppendOnlyDelta(
        previousSignature: previousSignature,
        currentSignature: currentSignature
      ) {
        cacheMode = .sessionReused
        cacheReason = .appendOnlyDeltaReused
        reuseStrategy = .appendHistoryDelta(startIndex: cachedPrefix?.count ?? 0)
        mismatchReason = nil
      } else {
        cacheMode = .invalidatedSignatureMismatch
        cacheReason = Self.signatureMismatchReason(
          previousSignature: previousSignature,
          currentSignature: currentSignature
        )
        reuseStrategy = .none
        mismatchReason = "rendered_context_signature_changed"
      }
    } else {
      cacheMode = .invalidatedSignatureMismatch
      cacheReason = Self.historyMismatchReason(
        systemPromptChanged: systemPromptChanged,
        currentPromptContextChanged: currentPromptContextChanged
      )
      reuseStrategy = .none
      mismatchReason = "history_prefix_mismatch"
    }

    return GemmaSessionCacheDecision(
      reuseStrategy: reuseStrategy,
      trace: GemmaSessionCacheTrace(
        cacheMode: cacheMode,
        cacheReason: cacheReason,
        contextSignature: currentSignature.traceValue,
        previousContextSignature: previousSignature?.traceValue,
        appendOnly: appendOnly,
        reusedMessageCount: reusedMessageCount,
        appendedMessageCount: appendedMessageCount,
        mismatchReason: mismatchReason,
        firstMismatchIndex: mismatchReason == nil ? nil : mismatchIndex,
        systemPromptChanged: mismatchReason == nil ? nil : systemPromptChanged,
        currentPromptContextChanged: mismatchReason == nil ? nil : currentPromptContextChanged
      )
    )
  }

  nonisolated static func runtimeCacheDebugSnapshot(
    from trace: GemmaSessionCacheTrace,
    reuseStrategy: GemmaSessionReuseStrategy,
    generationID: UUID,
    recordedAt: Date = Date()
  ) -> RuntimeCacheDebugSnapshot {
    let strategy = runtimeCacheDebugReuseStrategy(reuseStrategy)
    return RuntimeCacheDebugSnapshot(
      generationID: generationID,
      recordedAt: recordedAt,
      cacheMode: trace.cacheMode.rawValue,
      cacheReason: trace.cacheReason.rawValue,
      reuseStrategy: strategy.name,
      appendDeltaStartIndex: strategy.appendDeltaStartIndex,
      contextSignature: trace.contextSignature,
      previousContextSignature: trace.previousContextSignature,
      appendOnly: trace.appendOnly,
      reusedMessageCount: trace.reusedMessageCount,
      appendedMessageCount: trace.appendedMessageCount,
      mismatchReason: trace.mismatchReason,
      firstMismatchIndex: trace.firstMismatchIndex,
      systemPromptChanged: trace.systemPromptChanged,
      currentPromptContextChanged: trace.currentPromptContextChanged
    )
  }

  nonisolated private static func runtimeCacheDebugReuseStrategy(
    _ reuseStrategy: GemmaSessionReuseStrategy
  ) -> (name: String, appendDeltaStartIndex: Int?) {
    switch reuseStrategy {
    case .none:
      ("none", nil)
    case .exactPrompt:
      ("exact_prompt", nil)
    case .appendHistoryDelta(let startIndex):
      ("append_history_delta", startIndex)
    }
  }

  nonisolated static func renderedContextSignature(
    for messages: [GemmaMessageSnapshot],
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode = .fullHistory,
    systemPrompt: String? = nil,
    systemPromptHash: String? = nil,
    nativeToolSchemaHash: String = nativeToolSchemaSignature(from: nil),
    rendererVersion: Int = gemmaRendererVersion
  ) -> GemmaRenderedContextSignature {
    GemmaRenderedContextSignature(
      rendererVersion: rendererVersion,
      projectionMode: projectionMode,
      systemPromptHash: systemPromptHash ?? runtimeSystemPromptSignature(from: systemPrompt),
      renderedHistoryHash: contextSignature(for: messages),
      generationSettingsHash: generationSettingsSignature(for: settings),
      nativeToolSchemaHash: nativeToolSchemaHash
    )
  }

  nonisolated private static func signatureMismatchReason(
    previousSignature: GemmaRenderedContextSignature?,
    currentSignature: GemmaRenderedContextSignature
  ) -> GemmaSessionCacheReason {
    guard let previousSignature else {
      return .invalidatedRenderedContextChanged
    }
    if previousSignature.rendererVersion != currentSignature.rendererVersion {
      return .invalidatedRendererVersionChanged
    }
    if previousSignature.projectionMode != currentSignature.projectionMode {
      return .invalidatedRenderedContextChanged
    }
    if previousSignature.systemPromptHash != currentSignature.systemPromptHash {
      return .invalidatedSystemPromptChanged
    }
    if previousSignature.nativeToolSchemaHash != currentSignature.nativeToolSchemaHash {
      return .invalidatedToolSchemaChanged
    }
    return .invalidatedRenderedContextChanged
  }

  nonisolated private static func canReuseAppendOnlyDelta(
    previousSignature: GemmaRenderedContextSignature?,
    currentSignature: GemmaRenderedContextSignature
  ) -> Bool {
    guard let previousSignature else {
      return false
    }
    return previousSignature.rendererVersion == currentSignature.rendererVersion
      && previousSignature.projectionMode == currentSignature.projectionMode
      && previousSignature.systemPromptHash == currentSignature.systemPromptHash
      && previousSignature.generationSettingsHash == currentSignature.generationSettingsHash
      && previousSignature.nativeToolSchemaHash == currentSignature.nativeToolSchemaHash
  }

  nonisolated private static func historyMismatchReason(
    systemPromptChanged: Bool?,
    currentPromptContextChanged: Bool?
  ) -> GemmaSessionCacheReason {
    if currentPromptContextChanged == true {
      return .invalidatedCurrentPromptContextBoundary
    }
    if systemPromptChanged == true {
      return .invalidatedToolPromptChanged
    }
    return .invalidatedHistoryPrefixMismatch
  }

  /// Whether a settings change should invalidate a reusable KV-cache prefix.
  ///
  /// Only `maxKVSize` affects the cached prefill. Sampling params and `maxTokens`
  /// are applied at decode time, so changing them keeps the prefix valid (the new
  /// values are pushed onto the reused session instead — see `prepareSession`).
  nonisolated private static func cacheAffectingSettingsChanged(
    _ cached: ChatGenerationSettings?,
    _ current: ChatGenerationSettings
  ) -> Bool {
    guard let cached else { return true }
    return cached.maxKVSize != current.maxKVSize
  }

  nonisolated private static func generationSettingsSignature(
    for settings: ChatGenerationSettings
  ) -> String {
    // Only settings that change the KV-cache prefill belong in the cache signature.
    // Sampling params (temperature/topP/topK) and maxTokens are applied at decode
    // time and never alter the cached prefix, so they must not invalidate it. Only
    // maxKVSize matters here, because it controls cache rotation/eviction.
    hashSignature { updateString in
      updateString(settings.maxKVSize.map(String.init) ?? "nil")
    }
  }

  nonisolated private static func runtimeSystemPromptSignature(from systemPrompt: String?) -> String
  {
    guard let normalizedSystemPrompt = normalizedRuntimeSystemPrompt(systemPrompt ?? "") else {
      return "none"
    }
    return hashSignature { updateString in
      updateString("runtime_system_prompt_v1")
      updateString(normalizedSystemPrompt)
    }
  }

  nonisolated static func nativeToolSchemaSignature(
    from toolContext: ChatRuntimeToolContext?
  ) -> String {
    guard toolContext?.strategy == .nativeGemma4 else {
      return "none"
    }
    return nativeToolSchemaSignature(for: toolContext?.registry.tools ?? [])
  }

  nonisolated static func nativeToolSchemaSignature(
    for tools: [ToolDefinition]
  ) -> String {
    guard !tools.isEmpty else {
      return "none"
    }

    return hashSignature { updateString in
      updateString("native_gemma4_tools_v1")
      for tool in tools {
        updateString("tool")
        updateString(tool.name.rawValue)
        updateString(tool.description)
        for parameter in tool.parameters {
          updateString("parameter")
          updateString(parameter.name)
          updateString(parameter.description)
          updateString(parameter.isRequired ? "required" : "optional")
          updateString(parameter.valueType.rawValue)
          if let enumValues = parameter.enumValues {
            updateString("enum")
            for value in enumValues {
              updateString(value)
            }
          } else {
            updateString("enum:nil")
          }
          updateString(parameter.defaultValue.map(toolArgumentSignature(from:)) ?? "default:nil")
          updateString(parameter.minimum.map { String($0) } ?? "minimum:nil")
          updateString(parameter.maximum.map { String($0) } ?? "maximum:nil")
        }
      }
    }
  }

  nonisolated private static func toolArgumentSignature(from value: ToolArgumentValue) -> String {
    switch value {
    case .string(let string):
      return "string:\(string)"
    case .number(let number):
      return "number:\(number)"
    case .bool(let bool):
      return "bool:\(bool)"
    case .array(let array):
      return "array:[\(array.map(toolArgumentSignature(from:)).joined(separator: ","))]"
    case .object(let object):
      let entries = object.keys.sorted().map { key in
        "\(key):\(toolArgumentSignature(from: object[key] ?? .null))"
      }
      return "object:{\(entries.joined(separator: ","))}"
    case .null:
      return "null"
    }
  }

  nonisolated private static func firstMismatchIndex(
    cachedPrefix: [GemmaMessageSnapshot],
    currentHistory: [GemmaMessageSnapshot]
  ) -> Int? {
    let sharedCount = min(cachedPrefix.count, currentHistory.count)
    for index in 0..<sharedCount where cachedPrefix[index] != currentHistory[index] {
      return index
    }
    return cachedPrefix.count == currentHistory.count ? nil : sharedCount
  }

  nonisolated private static func baseSystemInstructionBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> String? {
    if let first = messages.first, first.role == Chat.Message.Role.system.rawValue {
      return first.content
    }

    guard let block = userSystemInstructionBlock(from: messages) else {
      return nil
    }
    guard let boundary = currentPromptContextBoundary(in: block) else {
      return block
    }
    return String(block[..<boundary.range.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func currentPromptContextBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> CurrentPromptContextRuntimeBlock? {
    guard let block = userSystemInstructionBlock(from: messages),
      let boundary = currentPromptContextBoundary(in: block)
    else {
      return nil
    }
    return CurrentPromptContextRuntimeBlock(
      boundary: boundary.boundary,
      content: String(block[boundary.range.lowerBound...])
    )
  }

  nonisolated private static func userSystemInstructionBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> String? {
    guard let firstUser = messages.first(where: { $0.role == Chat.Message.Role.user.rawValue }),
      firstUser.content.hasPrefix("System instructions:")
    else {
      return nil
    }
    guard let userRequestRange = firstUser.content.range(of: "\n\nUser request:") else {
      return firstUser.content
    }
    return String(firstUser.content[..<userRequestRange.lowerBound])
  }

  nonisolated private static func currentPromptContextBoundary(
    in systemInstructionBlock: String
  ) -> CurrentPromptContextRuntimeBoundaryMatch? {
    CurrentPromptContextRuntimeBoundary.all.compactMap { boundary in
      systemInstructionBlock.range(of: boundary.marker).map { range in
        CurrentPromptContextRuntimeBoundaryMatch(boundary: boundary, range: range)
      }
    }
    .min { $0.range.lowerBound < $1.range.lowerBound }
  }

  nonisolated static func contextSignature(for messages: [GemmaMessageSnapshot]) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func update(_ byte: UInt8) {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }

    for message in messages {
      for byte in message.role.utf8 {
        update(byte)
      }
      update(0)
      for byte in message.content.utf8 {
        update(byte)
      }
      for signature in message.imageSignatures {
        update(0xFE)
        for byte in signature.utf8 {
          update(byte)
        }
      }
      update(0xFF)
    }

    return String(format: "%016llx", hash)
  }

  nonisolated private static func hashSignature(_ body: ((String) -> Void) -> Void) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func update(_ byte: UInt8) {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }

    body { value in
      for byte in value.utf8 {
        update(byte)
      }
      update(0)
    }

    return String(format: "%016llx", hash)
  }

  nonisolated private static func isPrefix(
    _ prefix: [GemmaMessageSnapshot],
    of messages: [GemmaMessageSnapshot]
  ) -> Bool {
    guard prefix.count <= messages.count else {
      return false
    }

    return zip(prefix, messages).allSatisfy(==)
  }

  nonisolated static func toolSpecs(from toolContext: ChatRuntimeToolContext?) -> [ToolSpec]? {
    guard toolContext?.strategy == .nativeGemma4 else {
      return nil
    }
    let tools = toolContext?.registry.tools ?? []
    guard !tools.isEmpty else {
      return nil
    }
    return tools.map(toolSpec(for:))
  }

  nonisolated private static func toolSpec(for definition: ToolDefinition) -> ToolSpec {
    [
      "type": "function",
      "function": [
        "name": definition.name.rawValue,
        "description": definition.description,
        "parameters": jsonSchemaObject(for: definition.parameters),
      ] as [String: any Sendable],
    ] as ToolSpec
  }

  nonisolated private static func jsonSchemaObject(
    for parameters: [ToolParameterDefinition]
  ) -> [String: any Sendable] {
    var properties: [String: any Sendable] = [:]
    var required: [String] = []

    for parameter in parameters {
      properties[parameter.name] = jsonSchemaProperty(for: parameter)
      if parameter.isRequired {
        required.append(parameter.name)
      }
    }

    return [
      "type": "object",
      "properties": properties,
      "required": required,
      "additionalProperties": false,
    ] as [String: any Sendable]
  }

  nonisolated private static func jsonSchemaProperty(
    for parameter: ToolParameterDefinition
  ) -> [String: any Sendable] {
    var schema: [String: any Sendable] = [
      "type": parameter.valueType.rawValue,
      "description": parameter.description,
    ]
    if let enumValues = parameter.enumValues {
      schema["enum"] = enumValues
    }
    if let defaultValue = parameter.defaultValue {
      schema["default"] = sendableValue(from: defaultValue)
    }
    if let minimum = parameter.minimum {
      schema["minimum"] = minimum
    }
    if let maximum = parameter.maximum {
      schema["maximum"] = maximum
    }
    if let arrayItems = parameter.arrayItems {
      schema["items"] = jsonSchemaObjectValue(for: arrayItems)
    }
    return schema
  }

  nonisolated private static func jsonSchemaObjectValue(
    for object: ToolJSONSchemaObject
  ) -> [String: any Sendable] {
    var properties: [String: any Sendable] = [:]
    for (name, property) in object.properties {
      properties[name] = jsonSchemaPropertyValue(for: property)
    }

    return [
      "type": object.type,
      "properties": properties,
      "required": object.required,
      "additionalProperties": object.additionalProperties,
    ] as [String: any Sendable]
  }

  nonisolated private static func jsonSchemaPropertyValue(
    for property: ToolJSONSchemaProperty
  ) -> [String: any Sendable] {
    var schema: [String: any Sendable] = [
      "type": property.type.rawValue,
      "description": property.description,
    ]
    if let enumValues = property.enumValues {
      schema["enum"] = enumValues
    }
    if let defaultValue = property.defaultValue {
      schema["default"] = sendableValue(from: defaultValue)
    }
    if let minimum = property.minimum {
      schema["minimum"] = minimum
    }
    if let maximum = property.maximum {
      schema["maximum"] = maximum
    }
    if let arrayItems = property.arrayItems {
      schema["items"] = jsonSchemaObjectValue(for: arrayItems)
    }
    return schema
  }

  nonisolated private static func sendableValue(
    from value: ToolArgumentValue
  ) -> any Sendable {
    switch value {
    case .string(let string):
      return string
    case .number(let number):
      return number
    case .bool(let bool):
      return bool
    case .array(let array):
      return array.map(sendableValue(from:))
    case .object(let object):
      return object.mapValues(sendableValue(from:))
    case .null:
      return NSNull()
    }
  }

  nonisolated static func chatRuntimeToolCall(from toolCall: MLXLMCommon.ToolCall)
    -> ChatRuntimeToolCall
  {
    let runtimeToolCall = ChatRuntimeToolCall(
      name: toolCall.function.name,
      arguments: toolCall.function.arguments.mapValues(toolArgumentValue(from:))
    )
    return ChatRuntimeToolCall(
      name: runtimeToolCall.name,
      arguments: runtimeToolCall.arguments,
      rawText: NativeToolCallBoundaryRenderer.renderGemma4(runtimeToolCall)
    )
  }

  nonisolated private static func toolArgumentValue(from value: JSONValue) -> ToolArgumentValue {
    switch value {
    case .null:
      return .null
    case .bool(let bool):
      return .bool(bool)
    case .int(let int):
      return .number(Double(int))
    case .double(let double):
      return .number(double)
    case .string(let string):
      return .string(string)
    case .array(let array):
      return .array(array.map(toolArgumentValue(from:)))
    case .object(let object):
      return .object(object.mapValues(toolArgumentValue(from:)))
    }
  }

  nonisolated static func modelStream(
    from stream: AsyncThrowingStream<Generation, Error>,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markNativeToolCallBoundary: @escaping @Sendable (String, [ChatRuntimeToolCall]) async -> Void =
      {
        _, _ in
      },
    markCancelled: @escaping @Sendable (GemmaSessionInvalidationReason) async -> Void,
    memoryCacheClearer: GemmaMemoryCacheClearer = .live
  ) -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    modelStreamPlan(
      from: stream,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cacheTrace,
      markCompleted: markCompleted,
      markNativeToolCallBoundary: markNativeToolCallBoundary,
      markCancelled: markCancelled,
      memoryCacheClearer: memoryCacheClearer
    ).stream
  }

  nonisolated static func modelStreamPlan(
    from stream: AsyncThrowingStream<Generation, Error>,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markNativeToolCallBoundary: @escaping @Sendable (String, [ChatRuntimeToolCall]) async -> Void =
      {
        _, _ in
      },
    markCancelled: @escaping @Sendable (GemmaSessionInvalidationReason) async -> Void,
    memoryCacheClearer: GemmaMemoryCacheClearer = .live
  ) -> GemmaModelStreamPlan {
    let (outputStream, continuation) = AsyncThrowingStream<ChatModelStreamEvent, Error>
      .makeStream(bufferingPolicy: .unbounded)
    let task = Task {
      var output = ""
      var completedMetrics: ChatGenerationMetrics?
      let iterationStartedAt = Date()
      var firstChunkAt: Date?
      var didCompleteNaturally = false
      var didTerminateDownstream = false
      var nativeToolCalls: [ChatRuntimeToolCall] = []

      do {
        generationLoop: for try await generation in stream {
          try Task.checkCancellation()

          if let chunk = generation.chunk {
            if firstChunkAt == nil {
              let now = Date()
              firstChunkAt = now
              if let traceMetadata {
                let ttftMs = now.timeIntervalSince(iterationStartedAt) * 1000
                await traceMetadata.tracer.recordTurnTraceEvent(
                  TurnTraceEvent(
                    turnID: traceMetadata.turnID,
                    generationID: traceID,
                    phase: .runtimeTTFT,
                    durationMs: ttftMs,
                    toolLoopIteration: traceMetadata.toolLoopIteration,
                    ttftMs: ttftMs,
                    cacheMode: cacheTrace.cacheMode.rawValue,
                    cacheReason: cacheTrace.cacheReason.rawValue,
                    interactionMode: traceMetadata.interactionMode,
                    contextSignature: cacheTrace.contextSignature,
                    previousContextSignature: cacheTrace.previousContextSignature,
                    appendOnly: cacheTrace.appendOnly,
                    reusedMessageCount: cacheTrace.reusedMessageCount,
                    appendedMessageCount: cacheTrace.appendedMessageCount,
                    mismatchReason: cacheTrace.mismatchReason,
                    firstMismatchIndex: cacheTrace.firstMismatchIndex,
                    systemPromptChanged: cacheTrace.systemPromptChanged,
                    currentPromptContextChanged: cacheTrace.currentPromptContextChanged
                  )
                )
              }
            }
            output += chunk
            if case .terminated = continuation.yield(.chunk(chunk)) {
              didTerminateDownstream = true
              break generationLoop
            }
          }

          if let toolCall = generation.toolCall {
            let runtimeToolCall = Self.chatRuntimeToolCall(from: toolCall)
            nativeToolCalls.append(runtimeToolCall)
            if case .terminated = continuation.yield(
              .toolCall(runtimeToolCall)
            ) {
              didTerminateDownstream = true
              break generationLoop
            }
          }

          if let info = generation.info {
            let decodeStartedAt = firstChunkAt ?? iterationStartedAt
            let durationMs = Date().timeIntervalSince(decodeStartedAt) * 1000
            let metrics = ChatGenerationMetrics(
              generatedTokenCount: info.generationTokenCount,
              tokensPerSecond: info.tokensPerSecond,
              durationMs: durationMs
            )
            completedMetrics = metrics
            if let traceMetadata {
              await traceMetadata.tracer.recordTurnTraceEvent(
                TurnTraceEvent(
                  turnID: traceMetadata.turnID,
                  generationID: traceID,
                  phase: .runtimeDecode,
                  durationMs: Date().timeIntervalSince(decodeStartedAt) * 1000,
                  toolLoopIteration: traceMetadata.toolLoopIteration,
                  tokensPerSecond: info.tokensPerSecond,
                  cacheMode: cacheTrace.cacheMode.rawValue,
                  cacheReason: cacheTrace.cacheReason.rawValue,
                  interactionMode: traceMetadata.interactionMode,
                  contextSignature: cacheTrace.contextSignature,
                  previousContextSignature: cacheTrace.previousContextSignature,
                  appendOnly: cacheTrace.appendOnly,
                  reusedMessageCount: cacheTrace.reusedMessageCount,
                  appendedMessageCount: cacheTrace.appendedMessageCount,
                  mismatchReason: cacheTrace.mismatchReason,
                  firstMismatchIndex: cacheTrace.firstMismatchIndex,
                  systemPromptChanged: cacheTrace.systemPromptChanged,
                  currentPromptContextChanged: cacheTrace.currentPromptContextChanged
                )
              )
            }
            didCompleteNaturally = true
            if case .terminated = continuation.yield(.completed(metrics)) {
              didTerminateDownstream = true
              break generationLoop
            }
          }
        }

        if didTerminateDownstream {
          await markCancelled(.downstreamTerminated)
          continuation.finish()
          return
        }

        if !didCompleteNaturally {
          let error = GemmaMLXRuntimeError.interruptedStream
          await markCancelled(.interrupted)
          if let memoryClearReason = memoryClearReason(for: .interruptedStream) {
            await clearMemoryCache(
              reason: memoryClearReason,
              traceID: traceID,
              traceMetadata: traceMetadata,
              cacheTrace: cacheTrace,
              memoryCacheClearer: memoryCacheClearer
            )
          }
          await GemmaDebugTraceStore.shared.traceResponse(
            id: traceID,
            output: output,
            metrics: completedMetrics,
            error: error.localizedDescription
          )
          continuation.finish(throwing: error)
          return
        }

        if !nativeToolCalls.isEmpty {
          await markNativeToolCallBoundary(output, nativeToolCalls)
        } else {
          await markCompleted(output)
        }
        await GemmaDebugTraceStore.shared.traceResponse(
          id: traceID,
          output: output,
          metrics: completedMetrics
        )
        continuation.finish()
      } catch is CancellationError {
        await markCancelled(.cancelled)
        await GemmaDebugTraceStore.shared.traceResponse(
          id: traceID,
          output: output,
          metrics: completedMetrics,
          error: CancellationError().localizedDescription
        )
        continuation.finish(throwing: CancellationError())
      } catch {
        await markCancelled(.runtimeError)
        if let memoryClearReason = memoryClearReason(for: .runtimeError) {
          await clearMemoryCache(
            reason: memoryClearReason,
            traceID: traceID,
            traceMetadata: traceMetadata,
            cacheTrace: cacheTrace,
            memoryCacheClearer: memoryCacheClearer
          )
        }
        await GemmaDebugTraceStore.shared.traceResponse(
          id: traceID,
          output: output,
          metrics: completedMetrics,
          error: error.localizedDescription
        )
        continuation.finish(throwing: error)
      }
    }

    continuation.onTermination = { termination in
      guard case .cancelled = termination else {
        return
      }

      Task {
        await markCancelled(.downstreamTerminated)
        task.cancel()
      }
    }

    return GemmaModelStreamPlan(stream: outputStream, task: task)
  }

  nonisolated static func memoryClearReason(
    for termination: GemmaModelStreamTermination
  ) -> GemmaMemoryClearReason? {
    switch termination {
    case .runtimeError:
      .runtimeError
    case .interruptedStream:
      .interruptedStream
    case .completed, .downstreamTerminated, .cancelled, .nativeToolCallBoundary:
      nil
    }
  }

  nonisolated private static func clearMemoryCache(
    reason: GemmaMemoryClearReason,
    traceID: UUID?,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace?,
    memoryCacheClearer: GemmaMemoryCacheClearer
  ) async {
    let memoryClearStartedAt = Date()
    await memoryCacheClearer.clearCache(reason)
    let durationMs = Date().timeIntervalSince(memoryClearStartedAt) * 1000
    let event = TurnTraceEvent(
      turnID: traceMetadata?.turnID,
      generationID: traceID ?? traceMetadata?.generationID,
      phase: .memoryClear,
      durationMs: durationMs,
      toolLoopIteration: traceMetadata?.toolLoopIteration,
      cacheMode: cacheTrace?.cacheMode.rawValue,
      cacheReason: cacheTrace?.cacheReason.rawValue,
      memoryClearReason: reason.rawValue,
      interactionMode: traceMetadata?.interactionMode,
      contextSignature: cacheTrace?.contextSignature,
      previousContextSignature: cacheTrace?.previousContextSignature,
      appendOnly: cacheTrace?.appendOnly,
      reusedMessageCount: cacheTrace?.reusedMessageCount,
      appendedMessageCount: cacheTrace?.appendedMessageCount,
      mismatchReason: cacheTrace?.mismatchReason,
      firstMismatchIndex: cacheTrace?.firstMismatchIndex,
      systemPromptChanged: cacheTrace?.systemPromptChanged,
      currentPromptContextChanged: cacheTrace?.currentPromptContextChanged
    )
    if let traceMetadata {
      await traceMetadata.tracer.recordTurnTraceEvent(event)
    } else {
      await GemmaDebugTraceStore.shared.traceTurnEvent(event)
    }
  }

  nonisolated static func templateMessages(
    from transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) throws -> [Chat.Message] {
    _ = attachments
    return try validatedTemplateMessages(
      runtimeHistoryMessages(
        systemPrompt: systemPrompt,
        history: normalizedChatMessages(
          transcript.projectedEntries(mode: runtimeProjectionMode)
            .map { Self.chatMessage(from: $0) }
        )
      ),
      allowsSystemPrompt: true
    )
  }

  nonisolated static func runtimeHistoryMessages(
    systemPrompt: String,
    history: [Chat.Message]
  ) throws -> [Chat.Message] {
    let normalizedSystemPrompt = normalizedRuntimeSystemPrompt(systemPrompt)
    let messages =
      if let normalizedSystemPrompt {
        [Chat.Message.system(normalizedSystemPrompt)] + history
      } else {
        history
      }
    return try validatedTemplateMessages(messages, allowsSystemPrompt: true)
  }

  nonisolated private static func normalizedRuntimeSystemPrompt(_ systemPrompt: String) -> String? {
    ModelFacingPromptRenderer.normalizedSystemPrompt(systemPrompt)
  }

  nonisolated static func normalizedChatMessages(_ messages: [Chat.Message]) -> [Chat.Message] {
    messages.reduce(into: []) { normalizedMessages, message in
      guard !message.content.isEmpty else {
        return
      }

      guard let lastMessage = normalizedMessages.last, lastMessage.role == message.role else {
        normalizedMessages.append(message)
        return
      }

      let mergedContent = [lastMessage.content, message.content].joined(separator: "\n\n")
      normalizedMessages[normalizedMessages.index(before: normalizedMessages.endIndex)] =
        Chat.Message(role: lastMessage.role, content: mergedContent)
    }
  }

  nonisolated static func validatedTemplateMessages(
    _ messages: [Chat.Message],
    allowsSystemPrompt: Bool = false
  ) throws -> [Chat.Message] {
    let bodyMessages: ArraySlice<Chat.Message>
    if messages.first?.role == .system {
      guard allowsSystemPrompt else {
        throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
      }
      bodyMessages = messages.dropFirst()
    } else {
      bodyMessages = messages[...]
    }

    guard bodyMessages.allSatisfy({ $0.role == .user || $0.role == .assistant }) else {
      throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
    }

    for index in bodyMessages.indices.dropFirst() {
      let previousIndex = bodyMessages.index(before: index)
      if bodyMessages[previousIndex].role == bodyMessages[index].role {
        throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
      }
    }

    return messages
  }

  /// Mirrors `normalizedChatMessages` (skip empty, merge consecutive same-role
  /// with a blank line) while carrying image signatures, then drops trailing
  /// user messages. Single source for both the template history and the cache
  /// prefix snapshot so the two can never drift.
  nonisolated private static func normalizedHistoryItems(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) -> [GemmaHistoryItem] {
    var items: [GemmaHistoryItem] = []
    for entry in entries {
      guard !entry.content.isEmpty else {
        continue
      }
      let role: Chat.Message.Role = entry.role == .user ? .user : .assistant
      if let last = items.last, last.role == role {
        items[items.count - 1] = GemmaHistoryItem(
          role: role,
          content: [last.content, entry.content].joined(separator: "\n\n"),
          imageSignatures: last.imageSignatures + entry.imageSignatures
        )
      } else {
        items.append(
          GemmaHistoryItem(
            role: role,
            content: entry.content,
            imageSignatures: entry.imageSignatures
          )
        )
      }
    }

    while items.last?.role == .user {
      items.removeLast()
    }

    return items
  }

  nonisolated static func generationHistoryMessages(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) throws -> [Chat.Message] {
    try validatedTemplateMessages(
      normalizedHistoryItems(from: entries).map {
        Chat.Message(role: $0.role, content: $0.content)
      }
    )
  }

  nonisolated static func generationHistorySnapshot(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) -> [GemmaMessageSnapshot] {
    normalizedHistoryItems(from: entries).map { item in
      GemmaMessageSnapshot(
        role: item.role.rawValue,
        content: item.content,
        imageSignatures: item.imageSignatures
      )
    }
  }

  nonisolated static func generationHistoryMessages(
    from transcript: ModelContextSnapshot
  ) throws -> [Chat.Message] {
    let entries = transcript.projectedEntries(mode: runtimeProjectionMode)
    guard let lastUserIndex = entries.lastIndex(where: { $0.role == .user }) else {
      return []
    }
    return try generationHistoryMessages(from: entries[..<lastUserIndex])
  }

}

nonisolated private struct LocalDownloader: MLXLMCommon.Downloader {
  func download(
    id: String,
    revision: String?,
    matching patterns: [String],
    useLatest: Bool,
    progressHandler: @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    throw ModelConfiguration.DirectoryError.unresolvedModelDirectory(id)
  }
}

nonisolated private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    return LocalTokenizer(tokenizer: tokenizer)
  }
}

nonisolated private struct LocalTokenizer: MLXLMCommon.Tokenizer {
  let tokenizer: any Tokenizers.Tokenizer

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? {
    tokenizer.convertTokenToId(token)
  }

  func convertIdToToken(_ id: Int) -> String? {
    tokenizer.convertIdToToken(id)
  }

  var bosToken: String? {
    tokenizer.bosToken
  }

  var eosToken: String? {
    tokenizer.eosToken
  }

  var unknownToken: String? {
    tokenizer.unknownToken
  }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    try tokenizer.applyChatTemplate(
      messages: messages,
      tools: tools,
      additionalContext: additionalContext
    )
  }
}
