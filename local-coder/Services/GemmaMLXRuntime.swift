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
  case invalidatedImageInputBoundary = "invalidated_image_input_boundary"
}

nonisolated enum GemmaSessionInvalidationReason: Equatable, Sendable {
  case signatureMismatch
  case cancelled
  case interrupted
  case downstreamTerminated
  case runtimeError
  case modelChanged
  case nativeToolCallBoundary
  case imageInputBoundary

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
    case .imageInputBoundary:
      .invalidatedImageInputBoundary
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
  case invalidatedHistoryAppended = "invalidated_history_appended"
  case invalidatedHistoryPrefixMismatch = "invalidated_history_prefix_mismatch"
  case invalidatedCurrentPromptContextBoundary = "invalidated_current_prompt_context_boundary"
  case invalidatedToolPromptChanged = "invalidated_tool_prompt_changed"
  case invalidatedToolSchemaChanged = "invalidated_tool_schema_changed"
  case invalidatedModelChanged = "invalidated_model_changed"
  case invalidatedRuntimeContextCleared = "invalidated_runtime_context_cleared"
  case invalidatedNativeToolCallBoundary = "invalidated_native_tool_call_boundary"
  case invalidatedImageInputBoundary = "invalidated_image_input_boundary"
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
    case .imageInputBoundary:
      .invalidatedImageInputBoundary
    }
  }
}

nonisolated enum GemmaSessionCacheEligibilityReason: String, Equatable, Sendable {
  case imageInputBoundary = "image_input_boundary"
}

nonisolated enum GemmaSessionCacheEligibility: Equatable, Sendable {
  case enabled
  case disabled(reason: GemmaSessionCacheEligibilityReason)

  var traceValue: String {
    switch self {
    case .enabled:
      "enabled"
    case .disabled:
      "disabled"
    }
  }

  var traceReason: String? {
    switch self {
    case .enabled:
      nil
    case .disabled(let reason):
      reason.rawValue
    }
  }
}

nonisolated struct GemmaMessageSnapshot: Equatable, Sendable {
  let role: String
  let content: String
}

nonisolated struct GemmaRenderedContextSignature: Equatable, Sendable {
  let rendererVersion: Int
  let projectionMode: ModelContextProjectionMode
  let renderedHistoryHash: String
  let generationSettingsHash: String
  let nativeToolSchemaHash: String

  var traceValue: String {
    "renderer-v\(rendererVersion):projection-\(projectionMode.signatureComponent):history-\(renderedHistoryHash):settings-\(generationSettingsHash):tools-\(nativeToolSchemaHash)"
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

nonisolated struct ActiveGemmaCompletionContext: Sendable {
  let generationID: GemmaGenerationID
  let historyPrefix: [GemmaMessageSnapshot]
  let prompt: String
  let settings: ChatGenerationSettings
  let projectionMode: ModelContextProjectionMode
  let nativeToolSchemaHash: String
  let cacheEligibility: GemmaSessionCacheEligibility
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
  let cacheEligibility: String
  let cacheEligibilityReason: String?
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
  private let attachmentStore = ChatAttachmentStore()
  private var contextTokenLimit: Int?
  private var generationOwnership = GemmaGenerationOwnership()
  private var activeGenerationRegistry = GemmaActiveGenerationRegistry()
  private var activeCompletionContext: ActiveGemmaCompletionContext?
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

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = attachments
    _ = systemPrompt
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }

    let rawMessages = try Self.validatedTemplateMessages(
      transcript.runtimeProjectedEntries(mode: .compactedHistoryForLaterTurns)
        .map { Self.chatMessage(from: $0) }
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
    _ = systemPrompt
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
    let cacheEligibility: GemmaSessionCacheEligibility =
      imageAttachments.isEmpty ? .enabled : .disabled(reason: .imageInputBoundary)

    let projectionMode = ModelContextProjectionMode.compactedHistoryForLaterTurns
    let projectedEntries = try transcript.runtimeProjectedEntries(mode: projectionMode)
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
    let history = try Self.generationHistoryMessages(
      from: projectedEntries[..<currentPromptIndex]
    )
    let historySnapshot = Self.messageSnapshot(from: history)
    let finalPrompt = promptMessage.content
    await supersedeActiveGenerationBeforeStartingNew()
    let generationID = generationOwnership.beginGeneration()
    let cachePlan = prepareSession(
      modelContainer: modelContainer,
      history: history,
      historySnapshot: historySnapshot,
      promptMessage: promptMessage,
      settings: settings,
      generateParameters: generateParameters,
      projectionMode: projectionMode,
      nativeToolSchemaHash: nativeToolSchemaHash,
      cacheEligibility: cacheEligibility,
      generationID: generationID
    )
    cachePlan.session.tools = toolSpecs

    let traceMetadata = TurnTraceContext.current
    let traceID = traceMetadata?.generationID ?? UUID()
    let traceHistory = history.map { message in
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
          cacheEligibility: cachePlan.trace.cacheEligibility,
          cacheEligibilityReason: cachePlan.trace.cacheEligibilityReason,
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
    activeCompletionContext = ActiveGemmaCompletionContext(
      generationID: generationID,
      historyPrefix: historySnapshot,
      prompt: finalPrompt,
      settings: settings,
      projectionMode: projectionMode,
      nativeToolSchemaHash: nativeToolSchemaHash,
      cacheEligibility: cacheEligibility
    )
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
          output: output,
          settings: settings,
          projectionMode: projectionMode,
          nativeToolSchemaHash: nativeToolSchemaHash,
          cacheEligibility: cacheEligibility
        )
      },
      markNativeToolCallBoundary: { [weak self] output, nativeToolCalls in
        await self?.markSessionNativeToolCallBoundary(
          generationID: generationID,
          historyPrefix: historySnapshot,
          prompt: finalPrompt,
          output: output,
          nativeToolCalls: nativeToolCalls,
          settings: settings,
          projectionMode: projectionMode,
          nativeToolSchemaHash: nativeToolSchemaHash,
          cacheEligibility: cacheEligibility
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

  func completePartialReply(output: String) async {
    guard let context = activeCompletionContext else {
      return
    }

    markSessionCompleted(
      generationID: context.generationID,
      historyPrefix: context.historyPrefix,
      prompt: context.prompt,
      output: output,
      settings: context.settings,
      projectionMode: context.projectionMode,
      nativeToolSchemaHash: context.nativeToolSchemaHash,
      cacheEligibility: context.cacheEligibility
    )
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
    settings: ChatGenerationSettings,
    generateParameters: GenerateParameters,
    projectionMode: ModelContextProjectionMode,
    nativeToolSchemaHash: String,
    cacheEligibility: GemmaSessionCacheEligibility,
    generationID: GemmaGenerationID
  ) -> GemmaSessionCachePlan {
    let contextSignature = Self.renderedContextSignature(
      for: historySnapshot,
      settings: settings,
      projectionMode: projectionMode,
      nativeToolSchemaHash: nativeToolSchemaHash
    )
    let cached = cachedSession
    let decision =
      switch cacheEligibility {
      case .enabled:
        Self.cacheDecision(
          cachedPrefix: cached?.prefix,
          cachedSettings: cached?.settings,
          cachedContextSignature: cached?.contextSignature,
          cachedState: cached?.state ?? pendingCacheInvalidationReason.map { .dirty(reason: $0) },
          currentHistory: historySnapshot,
          currentSettings: settings,
          projectionMode: projectionMode,
          currentNativeToolSchemaHash: nativeToolSchemaHash,
          cacheEligibility: cacheEligibility
        )
      case .disabled:
        Self.disabledCacheDecision(
          cachedPrefix: cached?.prefix,
          currentHistory: historySnapshot,
          currentSettings: settings,
          projectionMode: projectionMode,
          currentNativeToolSchemaHash: nativeToolSchemaHash,
          cacheEligibility: cacheEligibility
        )
      }
    pendingCacheInvalidationReason = nil

    if cacheEligibility == .enabled, decision.shouldReuse, let cached {
      cachedSession = CachedGemmaSession(
        session: cached.session,
        prefix: cached.prefix,
        settings: cached.settings,
        contextSignature: cached.contextSignature,
        state: .inFlight(generationID: generationID)
      )
      return GemmaSessionCachePlan(
        session: cached.session,
        trace: decision.trace,
        streamInput: Self.streamInput(
          for: decision.reuseStrategy,
          history: history,
          promptMessage: promptMessage
        )
      )
    }

    let session = MLXLMCommon.ChatSession(
      modelContainer,
      instructions: nil,
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
      streamInput: .prompt(promptMessage.content, images: promptMessage.images)
    )
  }

  private func markSessionCompleted(
    generationID: GemmaGenerationID,
    historyPrefix: [GemmaMessageSnapshot],
    prompt: String,
    output: String,
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode,
    nativeToolSchemaHash: String,
    cacheEligibility: GemmaSessionCacheEligibility
  ) {
    guard generationOwnership.completeIfCurrent(generationID) else {
      return
    }
    clearActiveCompletionContextIfCurrent(generationID)

    guard let cached = cachedSession,
      let completedState = cached.state.completing(generationID: generationID)
    else {
      activeGenerationRegistry.clearIfCurrent(generationID)
      return
    }

    if cacheEligibility != .enabled {
      cachedSession = nil
      pendingCacheInvalidationReason = .imageInputBoundary
      activeGenerationRegistry.clearIfCurrent(generationID)
      return
    }

    let completedPrefix =
      historyPrefix
      + [
        GemmaMessageSnapshot(role: Chat.Message.Role.user.rawValue, content: prompt),
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
    output: String,
    nativeToolCalls: [ChatRuntimeToolCall],
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode,
    nativeToolSchemaHash: String,
    cacheEligibility: GemmaSessionCacheEligibility
  ) {
    guard generationOwnership.completeIfCurrent(generationID) else {
      return
    }
    clearActiveCompletionContextIfCurrent(generationID)

    guard let cached = cachedSession,
      let completedState = cached.state.completingNativeToolCallBoundary(generationID: generationID)
    else {
      activeGenerationRegistry.clearIfCurrent(generationID)
      return
    }

    if cacheEligibility != .enabled {
      cachedSession = nil
      pendingCacheInvalidationReason = .imageInputBoundary
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
      + [GemmaMessageSnapshot(role: Chat.Message.Role.user.rawValue, content: prompt)]
      + assistantSnapshots
    cachedSession = CachedGemmaSession(
      session: cached.session,
      prefix: completedPrefix,
      settings: settings,
      contextSignature: Self.renderedContextSignature(
        for: completedPrefix,
        settings: settings,
        projectionMode: projectionMode,
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
    clearActiveCompletionContextIfCurrent(generationID)

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
    activeCompletionContext = nil
    cachedSession = nil
    pendingCacheInvalidationReason = reason
  }

  #if DEBUG
    func registerActiveGenerationForTesting(id: GemmaGenerationID, task: Task<Void, Never>) {
      activeGenerationRegistry.register(id: id, task: task)
    }
  #endif

  private func clearActiveCompletionContextIfCurrent(_ generationID: GemmaGenerationID) {
    guard activeCompletionContext?.generationID == generationID else {
      return
    }
    activeCompletionContext = nil
  }

  private func configureMLXMemory() {
    if Memory.cacheLimit > Self.maxMLXCacheBytes {
      Memory.cacheLimit = Self.maxMLXCacheBytes
    }
  }

  nonisolated private static let maxMLXCacheBytes = 512 * 1024 * 1024
  nonisolated static let gemmaRendererVersion = 1

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
    currentNativeToolSchemaHash: String = nativeToolSchemaSignature(from: nil),
    currentRendererVersion: Int = gemmaRendererVersion,
    cacheEligibility: GemmaSessionCacheEligibility = .enabled
  ) -> GemmaSessionCacheDecision {
    let currentSignature = renderedContextSignature(
      for: currentHistory,
      settings: currentSettings,
      projectionMode: projectionMode,
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
      systemPromptChanged =
        baseSystemInstructionBlock(from: cachedPrefix)
        != baseSystemInstructionBlock(from: currentHistory)
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
    } else if cachedSettings != currentSettings {
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
        currentPromptContextChanged: mismatchReason == nil ? nil : currentPromptContextChanged,
        cacheEligibility: cacheEligibility.traceValue,
        cacheEligibilityReason: cacheEligibility.traceReason
      )
    )
  }

  nonisolated static func disabledCacheDecision(
    cachedPrefix: [GemmaMessageSnapshot]?,
    currentHistory: [GemmaMessageSnapshot],
    currentSettings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode,
    currentNativeToolSchemaHash: String,
    cacheEligibility: GemmaSessionCacheEligibility
  ) -> GemmaSessionCacheDecision {
    let currentSignature = renderedContextSignature(
      for: currentHistory,
      settings: currentSettings,
      projectionMode: projectionMode,
      nativeToolSchemaHash: currentNativeToolSchemaHash
    )
    return GemmaSessionCacheDecision(
      reuseStrategy: .none,
      trace: GemmaSessionCacheTrace(
        cacheMode: .invalidatedImageInputBoundary,
        cacheReason: .invalidatedImageInputBoundary,
        contextSignature: currentSignature.traceValue,
        previousContextSignature: nil,
        appendOnly: cachedPrefix.map { isPrefix($0, of: currentHistory) } ?? false,
        reusedMessageCount: 0,
        appendedMessageCount: currentHistory.count,
        mismatchReason: cacheEligibility.traceReason,
        firstMismatchIndex: nil,
        systemPromptChanged: nil,
        currentPromptContextChanged: nil,
        cacheEligibility: cacheEligibility.traceValue,
        cacheEligibilityReason: cacheEligibility.traceReason
      )
    )
  }

  nonisolated static func renderedContextSignature(
    for messages: [GemmaMessageSnapshot],
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode = .fullHistory,
    nativeToolSchemaHash: String = nativeToolSchemaSignature(from: nil),
    rendererVersion: Int = gemmaRendererVersion
  ) -> GemmaRenderedContextSignature {
    GemmaRenderedContextSignature(
      rendererVersion: rendererVersion,
      projectionMode: projectionMode,
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

  nonisolated private static func generationSettingsSignature(
    for settings: ChatGenerationSettings
  ) -> String {
    hashSignature { updateString in
      updateString(String(settings.maxTokens))
      updateString(String(settings.temperature))
      updateString(String(settings.topP))
      updateString(String(settings.topK))
      updateString(settings.maxKVSize.map(String.init) ?? "nil")
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
    guard let block = systemInstructionBlock(from: messages) else {
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
    guard let block = systemInstructionBlock(from: messages),
      let boundary = currentPromptContextBoundary(in: block)
    else {
      return nil
    }
    return CurrentPromptContextRuntimeBlock(
      boundary: boundary.boundary,
      content: String(block[boundary.range.lowerBound...])
    )
  }

  nonisolated private static func systemInstructionBlock(
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
    _ = systemPrompt
    return try validatedTemplateMessages(
      normalizedChatMessages(
        try transcript.runtimeProjectedEntries(mode: .compactedHistoryForLaterTurns)
          .map { Self.chatMessage(from: $0) }
      )
    )
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

  nonisolated static func validatedTemplateMessages(_ messages: [Chat.Message]) throws -> [Chat
    .Message]
  {
    guard messages.allSatisfy({ $0.role == .user || $0.role == .assistant }) else {
      throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
    }

    for index in messages.indices.dropFirst() {
      let previousIndex = messages.index(before: index)
      if messages[previousIndex].role == messages[index].role {
        throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
      }
    }

    return messages
  }

  nonisolated static func generationHistoryMessages(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) throws -> [Chat.Message] {
    var history = normalizedChatMessages(entries.map { Self.chatMessage(from: $0) })

    while history.last?.role == .user {
      history.removeLast()
    }

    return try validatedTemplateMessages(history)
  }

  nonisolated static func generationHistoryMessages(
    from transcript: ModelContextSnapshot
  ) throws -> [Chat.Message] {
    let entries = try transcript.runtimeProjectedEntries(mode: .compactedHistoryForLaterTurns)
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
