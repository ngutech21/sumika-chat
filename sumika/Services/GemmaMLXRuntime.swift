import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import SumikaCore
import Tokenizers

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
    await GemmaModelStreamProcessor.clearMemoryCache(
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
    await GemmaModelStreamProcessor.clearMemoryCache(
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

  nonisolated static func mlxRepetitionPenalty(
    from settings: ChatGenerationSettings
  ) -> Float? {
    settings.repetitionPenalty == 1 ? nil : Float(settings.repetitionPenalty)
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
    let setupInterval = ChatDiagnostics.beginInterval(
      "Gemma stream reply setup",
      category: .generation
    )
    defer {
      ChatDiagnostics.endInterval(setupInterval)
    }
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
    let imageInputs = try GemmaHistoryRenderer.imageInputs(
      from: imageAttachments, attachmentStore: attachmentStore)
    let projectionMode = GemmaHistoryRenderer.runtimeProjectionMode
    let projectedEntries = transcript.projectedEntries(mode: projectionMode)
    guard let currentPromptIndex = projectedEntries.lastIndex(where: { $0.role == .user }) else {
      throw GemmaMLXRuntimeError.missingUserMessage
    }

    let promptMessage = GemmaHistoryRenderer.chatMessage(
      from: projectedEntries[currentPromptIndex],
      images: imageInputs
    )
    let generateParameters = GenerateParameters(
      maxTokens: settings.maxTokens,
      maxKVSize: settings.maxKVSize,
      temperature: Float(settings.temperature),
      topP: Float(settings.topP),
      topK: settings.topK,
      repetitionPenalty: Self.mlxRepetitionPenalty(from: settings)
    )
    let additionalContext = Self.chatTemplateAdditionalContext(
      reasoningEnabled: settings.reasoningEnabled)
    let toolSpecs = GemmaNativeToolSchema.toolSpecs(from: toolContext)
    let nativeToolSchemaHash = GemmaSessionCachePolicy.nativeToolSchemaSignature(from: toolContext)
    let cacheSystemPrompt = toolContext?.cacheSystemPrompt ?? systemPrompt
    let historySnapshot = GemmaHistoryRenderer.generationHistorySnapshot(
      from: projectedEntries[..<currentPromptIndex]
    )
    let history = try GemmaHistoryRenderer.validatedChatMessages(from: historySnapshot)
    let promptImageSignatures = projectedEntries[currentPromptIndex].imageSignatures
    let finalPrompt = promptMessage.content
    await supersedeActiveGenerationBeforeStartingNew()
    let traceMetadata = TurnTraceContext.current
    let traceID = traceMetadata?.generationID ?? UUID()
    let generationID = generationOwnership.beginGeneration()
    let prepareSessionInterval = ChatDiagnostics.beginInterval(
      "Gemma prepare session",
      category: .generation
    )
    let cachePlan = prepareSession(
      modelContainer: modelContainer,
      history: history,
      historySnapshot: historySnapshot,
      promptMessage: promptMessage,
      systemPrompt: systemPrompt,
      cacheSystemPrompt: cacheSystemPrompt,
      settings: settings,
      generateParameters: generateParameters,
      additionalContext: additionalContext,
      projectionMode: projectionMode,
      nativeToolSchemaHash: nativeToolSchemaHash,
      generationID: generationID
    )
    ChatDiagnostics.endInterval(prepareSessionInterval)
    lastRuntimeCacheDebugSnapshot = GemmaSessionCachePolicy.runtimeCacheDebugSnapshot(
      from: cachePlan.trace,
      reuseStrategy: cachePlan.reuseStrategy,
      generationID: traceID
    )
    cachePlan.session.tools = toolSpecs

    try await traceDebugRequest(
      id: traceID,
      systemPrompt: systemPrompt,
      history: history,
      prompt: finalPrompt,
      settings: settings,
      imageAttachments: imageAttachments
    )

    let createStreamInterval = ChatDiagnostics.beginInterval(
      "Gemma create MLX stream",
      category: .generation
    )
    let stream: AsyncThrowingStream<Generation, Error>
    switch cachePlan.streamInput {
    case .prompt(let prompt, let images):
      stream = cachePlan.session.streamDetails(to: prompt, images: images, videos: [])
    case .messages(let messages):
      stream = cachePlan.session.streamDetails(to: messages)
    }
    ChatDiagnostics.endInterval(createStreamInterval)
    await recordRuntimeStreamStart(
      traceID: traceID,
      traceMetadata: traceMetadata,
      cachePlan: cachePlan,
      streamStartStartedAt: streamStartStartedAt,
      messageCount: projectedEntries.count,
      imageAttachments: imageAttachments
    )
    let streamPlan = GemmaModelStreamProcessor.modelStreamPlan(
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
          toolRegistry: toolContext?.registry,
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

  private func traceDebugRequest(
    id: UUID,
    systemPrompt: String,
    history: [Chat.Message],
    prompt: String,
    settings: ChatGenerationSettings,
    imageAttachments: [ChatAttachment]
  ) async throws {
    let traceMessages = try GemmaHistoryRenderer.runtimeHistoryMessages(
      systemPrompt: systemPrompt,
      history: history
    )
    let traceHistory = traceMessages.map { message in
      (role: message.role.rawValue, content: message.content)
    }
    let interval = ChatDiagnostics.beginInterval(
      "Gemma debug trace request",
      category: .generation
    )
    defer {
      ChatDiagnostics.endInterval(interval)
    }
    await GemmaDebugTraceStore.shared.traceRequest(
      id: id,
      history: traceHistory,
      prompt: prompt,
      settings: settings,
      contextTokenLimit: contextTokenLimit,
      imageAttachments: imageAttachments
    )
  }

  private func recordRuntimeStreamStart(
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cachePlan: GemmaSessionCachePlan,
    streamStartStartedAt: Date,
    messageCount: Int,
    imageAttachments: [ChatAttachment]
  ) async {
    guard let traceMetadata else {
      return
    }
    await traceMetadata.tracer.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: traceMetadata.turnID,
        generationID: traceID,
        phase: .runtimeStreamStart,
        durationMs: Date().timeIntervalSince(streamStartStartedAt) * 1000,
        promptBytes: cachePlan.streamInput.contentByteCount,
        messageCount: messageCount,
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
        imageTypes: GemmaHistoryRenderer.imageTypes(from: imageAttachments),
        imageByteCount: GemmaHistoryRenderer.imageByteCount(from: imageAttachments)
      )
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
    systemPrompt: String,
    cacheSystemPrompt: String,
    settings: ChatGenerationSettings,
    generateParameters: GenerateParameters,
    additionalContext: [String: any Sendable],
    projectionMode: ModelContextProjectionMode,
    nativeToolSchemaHash: String,
    generationID: GemmaGenerationID
  ) -> GemmaSessionCachePlan {
    let contextSignature = GemmaSessionCachePolicy.renderedContextSignature(
      for: historySnapshot,
      settings: settings,
      projectionMode: projectionMode,
      systemPrompt: cacheSystemPrompt,
      nativeToolSchemaHash: nativeToolSchemaHash
    )
    let cached = cachedSession
    let decision = GemmaSessionCachePolicy.cacheDecision(
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
      cached.session.instructions = GemmaHistoryRenderer.normalizedRuntimeSystemPrompt(systemPrompt)
      // Sampling params no longer invalidate the prefix, so push the current values
      // onto the reused session to ensure a mid-session change still takes effect.
      cached.session.generateParameters = generateParameters
      cached.session.additionalContext = additionalContext
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
        streamInput: GemmaSessionCachePolicy.streamInput(
          for: decision.reuseStrategy,
          history: history,
          promptMessage: promptMessage
        )
      )
    }

    let session = MLXLMCommon.ChatSession(
      modelContainer,
      instructions: GemmaHistoryRenderer.normalizedRuntimeSystemPrompt(systemPrompt),
      history: history,
      generateParameters: generateParameters,
      additionalContext: additionalContext
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
      contextSignature: GemmaSessionCachePolicy.renderedContextSignature(
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
    toolRegistry: ToolRegistry?,
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

    let nativeBoundary = NativeToolCallBoundaryRenderer.renderModelContextGemma4(
      nativeToolCalls,
      registry: toolRegistry
    )
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
      contextSignature: GemmaSessionCachePolicy.renderedContextSignature(
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

  nonisolated private static func chatTemplateAdditionalContext(
    reasoningEnabled: Bool
  ) -> [String: any Sendable] {
    ["enable_thinking": reasoningEnabled]
  }
}
