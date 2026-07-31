import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import SumikaCore

final actor MLXChatRuntime: ChatModelRuntime {
  /// Leaves image sizing to each model processor instead of pre-resizing to 512 px.
  static var modelNativeMediaProcessing: UserInput.Processing {
    .init()
  }

  private var modelContainer: ModelContainer?
  private var loadedModelSupportsImageInput = false
  private var loadedReasoningTraceFormat: ReasoningTraceFormat = .none
  private var cachedSession: CachedMLXSession?
  private var pendingCacheInvalidationReason: MLXSessionInvalidationReason?
  private var lastRuntimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot?
  private var runtimeCacheDiagnostics: MLXRuntimeCacheDiagnostics?
  private let attachmentStore = ChatAttachmentStore()
  private var contextTokenLimit: Int?
  private var generationOwnership = MLXGenerationOwnership()
  private var activeGenerationRegistry = MLXActiveGenerationRegistry()
  private var lifecycleTransitionInProgress = false
  private let memoryCacheClearer: MLXMemoryCacheClearer
  private let debugTraceStore: MLXDebugTraceStore

  init(debugTraceStore: MLXDebugTraceStore) {
    self.memoryCacheClearer = .live
    self.debugTraceStore = debugTraceStore
  }

  init(
    memoryCacheClearer: MLXMemoryCacheClearer = .live,
    debugTraceStore: MLXDebugTraceStore
  ) {
    self.memoryCacheClearer = memoryCacheClearer
    self.debugTraceStore = debugTraceStore
  }

  func load(configuration: ChatModelConfiguration) async throws {
    #if !arch(arm64)
      throw MLXChatRuntimeError.unsupportedArchitecture
    #endif

    lifecycleTransitionInProgress = true
    defer { lifecycleTransitionInProgress = false }
    await cancelAndDrainActiveGeneration(reason: .modelChanged)
    configureMLXMemory()

    let tokenizerLoader = makeHuggingFaceTokenizerLoader()

    let container =
      if configuration.supportsImageInput {
        try await VLMModelFactory.shared.loadContainer(
          from: configuration.localModelDirectory,
          using: tokenizerLoader
        )
      } else {
        try await LLMModelFactory.shared.loadContainer(
          from: configuration.localModelDirectory,
          using: tokenizerLoader
        )
      }

    runtimeCacheDiagnostics =
      if MLXDebugTraceStore.isEnabled {
        await MLXRuntimeCacheDiagnostics.install(on: container)
      } else {
        nil
      }
    modelContainer = container
    loadedModelSupportsImageInput = configuration.supportsImageInput
    loadedReasoningTraceFormat = configuration.reasoningTraceFormat
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
    runtimeCacheDiagnostics = nil
    loadedModelSupportsImageInput = false
    loadedReasoningTraceFormat = .none
    contextTokenLimit = nil
    lastRuntimeCacheDebugSnapshot = nil
    await MLXModelStreamProcessor.clearMemoryCache(
      reason: .unload,
      traceID: nil,
      traceMetadata: TurnTraceContext.current,
      cacheTrace: nil,
      debugTraceStore: debugTraceStore,
      memoryCacheClearer: memoryCacheClearer
    )
  }

  func clearContext() async {
    lifecycleTransitionInProgress = true
    defer { lifecycleTransitionInProgress = false }
    await cancelAndDrainActiveGeneration(reason: .signatureMismatch)
    invalidateCachedSession(reason: .signatureMismatch)
    await runtimeCacheDiagnostics?.invalidate()
    lastRuntimeCacheDebugSnapshot = nil
    await MLXModelStreamProcessor.clearMemoryCache(
      reason: .clearContext,
      traceID: nil,
      traceMetadata: TurnTraceContext.current,
      cacheTrace: nil,
      debugTraceStore: debugTraceStore,
      memoryCacheClearer: memoryCacheClearer
    )
  }

  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    lastRuntimeCacheDebugSnapshot
  }

  static func mlxRepetitionPenalty(
    from settings: ChatGenerationSettings
  ) -> Float? {
    settings.repetitionPenalty == 1 ? nil : Float(settings.repetitionPenalty)
  }

  static func appendTransientInstructions(
    _ instructions: [String],
    toPromptSnapshot promptSnapshot: [ProviderPromptMessage],
    promptMessages: [Chat.Message]
  ) -> (promptSnapshot: [ProviderPromptMessage], promptMessages: [Chat.Message]) {
    var updatedSnapshot = promptSnapshot
    var updatedMessages = promptMessages
    for instruction in instructions {
      if let lastSnapshot = updatedSnapshot.last,
        lastSnapshot.role == Chat.Message.Role.user.rawValue,
        !lastSnapshot.hasToolMetadata
      {
        updatedSnapshot[updatedSnapshot.count - 1] = ProviderPromptMessage(
          role: Chat.Message.Role.user.rawValue,
          content: [lastSnapshot.content, instruction].joined(separator: "\n\n"),
          imageSignatures: lastSnapshot.imageSignatures
        )
      } else {
        updatedSnapshot.append(
          ProviderPromptMessage(
            role: Chat.Message.Role.user.rawValue,
            content: instruction
          )
        )
      }

      if let lastMessage = updatedMessages.last,
        lastMessage.role == .user
      {
        updatedMessages[updatedMessages.count - 1].content =
          [lastMessage.content, instruction].joined(separator: "\n\n")
      } else {
        updatedMessages.append(.user(instruction))
      }
    }
    return (updatedSnapshot, updatedMessages)
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    let setupInterval = ChatDiagnostics.beginInterval(
      "MLX stream reply setup",
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
      throw MLXChatRuntimeError.modelNotLoaded
    }
    let imageAttachments = attachments.filter { $0.kind == .image }
    guard imageAttachments.isEmpty || loadedModelSupportsImageInput else {
      throw MLXChatRuntimeError.unsupportedImageInput
    }
    let imageInputs = try MLXHistoryRenderer.imageInputs(
      from: imageAttachments, attachmentStore: attachmentStore)
    let projectionMode = MLXHistoryRenderer.runtimeProjectionMode
    let generationInput = try MLXHistoryRenderer.generationInput(
      from: transcript,
      images: imageInputs
    )
    let generateParameters = GenerateParameters(
      maxTokens: settings.maxTokens,
      maxKVSize: settings.maxKVSize,
      temperature: Float(settings.temperature),
      topP: Float(settings.topP),
      topK: settings.topK,
      repetitionPenalty: Self.mlxRepetitionPenalty(from: settings),
      repetitionContextSize: settings.repetitionContextSize,
      presencePenalty: Float(settings.presencePenalty),
      presenceContextSize: settings.repetitionContextSize
    )
    let additionalContext = Self.chatTemplateAdditionalContext(
      reasoningEnabled: settings.reasoningEnabled)
    let systemPrompt = promptPlan.stableInstructions
    let toolSpecs = MLXToolMapper.toolSpecs(from: promptPlan.toolContext)
    let historySnapshot = generationInput.historySnapshot
    let history = generationInput.history
    let promptWithTransientInstructions = Self.appendTransientInstructions(
      promptPlan.transientInstructions,
      toPromptSnapshot: generationInput.promptSnapshot,
      promptMessages: generationInput.promptMessages
    )
    let promptSnapshot = promptWithTransientInstructions.promptSnapshot
    let promptMessages = promptWithTransientInstructions.promptMessages
    let finalPrompt = promptMessages.map(\.content).joined(separator: "\n\n")
    await supersedeActiveGenerationBeforeStartingNew()
    let traceMetadata = TurnTraceContext.current
    let traceID = traceMetadata?.generationID ?? UUID()
    let generationID = generationOwnership.beginGeneration()
    let prepareSessionInterval = ChatDiagnostics.beginInterval(
      "MLX prepare session",
      category: .generation
    )
    let cachePlan = prepareSession(
      modelContainer: modelContainer,
      history: history,
      historySnapshot: historySnapshot,
      promptMessages: promptMessages,
      systemPrompt: systemPrompt,
      toolSpecs: toolSpecs,
      settings: settings,
      generateParameters: generateParameters,
      additionalContext: additionalContext,
      projectionMode: projectionMode,
      generationID: generationID
    )
    ChatDiagnostics.endInterval(prepareSessionInterval)
    lastRuntimeCacheDebugSnapshot = MLXSessionCachePolicy.runtimeCacheDebugSnapshot(
      from: cachePlan.trace,
      appendDeltaStartIndex: cachePlan.appendDeltaStartIndex,
      generationID: traceID
    )
    try await traceDebugRequest(
      id: traceID,
      systemPrompt: systemPrompt,
      history: history,
      prompt: finalPrompt,
      settings: settings,
      imageAttachments: imageAttachments
    )

    let createStreamInterval = ChatDiagnostics.beginInterval(
      "MLX create stream",
      category: .generation
    )
    let generationProgressTracer: MLXGenerationProgressTracer
    if MLXDebugTraceStore.isEnabled {
      let tokenizer = await modelContainer.tokenizer
      generationProgressTracer = MLXGenerationProgressTracer(
        traceID: traceID,
        traceMetadata: traceMetadata,
        debugTraceStore: debugTraceStore,
        startedAt: Date(),
        estimateTokenCount: { output in
          tokenizer.encode(text: output, addSpecialTokens: false).count
        }
      )
    } else {
      generationProgressTracer = .disabled
    }
    let runtimeCacheDiagnostics = self.runtimeCacheDiagnostics
    if let runtimeCacheDiagnostics {
      let cacheCapabilities = await MLXRuntimeCacheDiagnostics.capabilities(
        of: modelContainer,
        parameters: generateParameters
      )
      await runtimeCacheDiagnostics.begin(
        generationID: traceID,
        expectsReuse: cachePlan.trace.cacheMode == .reusedSession
          || cachePlan.trace.cacheMode == .appendDelta,
        newMediaPresent: cachePlan.streamMessages.contains {
          !$0.images.isEmpty || !$0.videos.isEmpty || !$0.audios.isEmpty
        },
        capabilities: cacheCapabilities
      )
    }
    let stream = cachePlan.session.streamDetails(to: cachePlan.streamMessages)
    ChatDiagnostics.endInterval(createStreamInterval)
    await recordRuntimeStreamStart(
      traceID: traceID,
      traceMetadata: traceMetadata,
      cachePlan: cachePlan,
      streamStartStartedAt: streamStartStartedAt,
      messageCount: transcript.entries.count,
      imageAttachments: imageAttachments
    )
    let streamPlan = MLXModelStreamProcessor.modelStreamPlan(
      from: stream,
      reasoningTraceFormat: settings.reasoningEnabled ? loadedReasoningTraceFormat : .none,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cachePlan.trace,
      debugTraceStore: debugTraceStore,
      runtimeCacheDiagnostics: runtimeCacheDiagnostics,
      generationProgressTracer: generationProgressTracer,
      markCompleted: { [weak self] output in
        await self?.markSessionCompleted(
          generationID: generationID,
          historyPrefix: historySnapshot,
          promptSnapshot: promptSnapshot,
          output: output
        )
      },
      markNativeToolCallBoundary: { [weak self] output, nativeToolCalls in
        await self?.markSessionNativeToolCallBoundary(
          generationID: generationID,
          historyPrefix: historySnapshot,
          promptSnapshot: promptSnapshot,
          output: output,
          nativeToolCalls: nativeToolCalls
        )
      },
      markCancelled: { [weak self, runtimeCacheDiagnostics] reason in
        await runtimeCacheDiagnostics?.invalidate()
        await self?.markCachedSessionInvalid(generationID: generationID, reason: reason)
      }
    )
    activeGenerationRegistry.register(id: generationID, task: streamPlan.task)
    if generationOwnership.activeGenerationID != generationID {
      activeGenerationRegistry.clearIfCurrent(generationID)
    }
    return streamPlan.stream
  }
}

extension MLXChatRuntime {
  private func traceDebugRequest(
    id: UUID,
    systemPrompt: String,
    history: [Chat.Message],
    prompt: String,
    settings: ChatGenerationSettings,
    imageAttachments: [ChatAttachment]
  ) async throws {
    let traceMessages = try MLXHistoryRenderer.runtimeHistoryMessages(
      systemPrompt: systemPrompt,
      history: history
    )
    let traceHistory = traceMessages.map { message in
      (role: message.role.rawValue, content: message.content)
    }
    let interval = ChatDiagnostics.beginInterval(
      "MLX debug trace request",
      category: .generation
    )
    defer {
      ChatDiagnostics.endInterval(interval)
    }
    await debugTraceStore.traceRequest(
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
    cachePlan: MLXSessionCachePlan,
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
        promptBytes: MLXSessionCachePolicy.contentByteCount(for: cachePlan.streamMessages),
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
        imageCount: imageAttachments.isEmpty ? nil : imageAttachments.count,
        imageTypes: MLXHistoryRenderer.imageTypes(from: imageAttachments),
        imageByteCount: MLXHistoryRenderer.imageByteCount(from: imageAttachments)
      )
    )
  }

  private func supersedeActiveGenerationBeforeStartingNew() async {
    await cancelAndDrainActiveGeneration(reason: .cancelled)
  }

  private func cancelAndDrainActiveGeneration(reason: MLXSessionInvalidationReason) async {
    guard let superseded = activeGenerationRegistry.supersedeActiveGeneration() else {
      return
    }

    markCachedSessionInvalid(generationID: superseded.id, reason: reason)
    await superseded.task.value
  }

  private func prepareSession(
    modelContainer: ModelContainer,
    history: [Chat.Message],
    historySnapshot: [ProviderPromptMessage],
    promptMessages: [Chat.Message],
    systemPrompt: String,
    toolSpecs: [ToolSpec]?,
    settings: ChatGenerationSettings,
    generateParameters: GenerateParameters,
    additionalContext: [String: any Sendable],
    projectionMode: ModelContextProjectionMode,
    generationID: MLXGenerationID
  ) -> MLXSessionCachePlan {
    let currentIdentity = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: systemPrompt,
      settings: settings,
      projectionMode: projectionMode,
      toolSpecs: toolSpecs,
      additionalContext: additionalContext
    )
    let cached = cachedSession
    let appendOnly: Bool
    let firstMismatchIndex: Int?
    if let cached {
      appendOnly = MLXSessionCachePolicy.isPrefix(cached.prefix, of: historySnapshot)
      firstMismatchIndex = MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cached.prefix,
        currentHistory: historySnapshot
      )
    } else {
      appendOnly = false
      firstMismatchIndex = nil
    }
    let cachedState = cached?.state ?? pendingCacheInvalidationReason.map { .dirty(reason: $0) }
    let traceMode: MLXSessionCacheMode
    let traceReason: MLXSessionCacheReason
    let shouldReuse: Bool
    let appendDeltaStartIndex: Int?
    let mismatchReason: String?
    let isStructuredToolContinuation = promptMessages.first?.role == .tool
    if cached == nil, let invalidationReason = cachedState?.invalidationReason {
      traceMode = .dirtyRebuild
      traceReason = .generationInvalidationReason(from: invalidationReason)
      shouldReuse = false
      appendDeltaStartIndex = nil
      mismatchReason = nil
    } else if cached == nil {
      traceMode = .newSession
      traceReason = .newSessionNoCache
      shouldReuse = false
      appendDeltaStartIndex = nil
      mismatchReason = nil
    } else if cachedState?.isReusable != true {
      let invalidationReason = cachedState?.invalidationReason ?? .interrupted
      traceMode = .dirtyRebuild
      traceReason = .generationInvalidationReason(from: invalidationReason)
      shouldReuse = false
      appendDeltaStartIndex = nil
      mismatchReason = nil
    } else if let cached, cached.identity != currentIdentity {
      traceMode = .dirtyRebuild
      traceReason = MLXSessionCachePolicy.identityMismatchReason(
        cached: cached.identity,
        current: currentIdentity
      )
      shouldReuse = false
      appendDeltaStartIndex = nil
      mismatchReason = "identity_changed"
    } else if appendOnly, let cached {
      let deltaStartIndex = cached.prefix.count
      if deltaStartIndex == historySnapshot.count {
        traceMode = isStructuredToolContinuation ? .appendDelta : .reusedSession
        traceReason = isStructuredToolContinuation ? .appendOnlyDelta : .reusedSession
        shouldReuse = true
        appendDeltaStartIndex = nil
        mismatchReason = nil
      } else {
        traceMode = .appendDelta
        traceReason = .appendOnlyDelta
        shouldReuse = true
        appendDeltaStartIndex = deltaStartIndex
        mismatchReason = nil
      }
    } else {
      traceMode = .dirtyRebuild
      traceReason = .historyChanged
      shouldReuse = false
      appendDeltaStartIndex = nil
      mismatchReason = "history_changed"
    }

    let trace = MLXSessionCachePolicy.trace(
      mode: traceMode,
      reason: traceReason,
      currentHistory: historySnapshot,
      currentIdentity: currentIdentity,
      cachedPrefix: cached?.prefix,
      cachedIdentity: cached?.identity,
      appendOnly: appendOnly,
      mismatchReason: mismatchReason,
      firstMismatchIndex: mismatchReason == nil ? nil : firstMismatchIndex
    )
    pendingCacheInvalidationReason = nil

    if shouldReuse, let cached {
      cached.session.generateParameters = generateParameters
      cachedSession = CachedMLXSession(
        session: cached.session,
        prefix: cached.prefix,
        identity: cached.identity,
        state: .inFlight(generationID: generationID)
      )
      return MLXSessionCachePlan(
        session: cached.session,
        trace: trace,
        appendDeltaStartIndex: appendDeltaStartIndex,
        streamMessages: MLXSessionCachePolicy.streamMessages(
          history: history,
          promptMessages: promptMessages,
          appendDeltaStartIndex: appendDeltaStartIndex
        )
      )
    }

    let session = MLXLMCommon.ChatSession(
      modelContainer,
      instructions: ModelFacingPromptRenderer.normalizedSystemPrompt(systemPrompt),
      history: history,
      generateParameters: generateParameters,
      processing: Self.modelNativeMediaProcessing,
      additionalContext: additionalContext,
      tools: toolSpecs
    )
    cachedSession = CachedMLXSession(
      session: session,
      prefix: historySnapshot,
      identity: currentIdentity,
      state: .inFlight(generationID: generationID)
    )
    return MLXSessionCachePlan(
      session: session,
      trace: trace,
      appendDeltaStartIndex: nil,
      streamMessages: MLXSessionCachePolicy.streamMessages(
        history: history,
        promptMessages: promptMessages,
        appendDeltaStartIndex: nil
      )
    )
  }

  private func markSessionCompleted(
    generationID: MLXGenerationID,
    historyPrefix: [ProviderPromptMessage],
    promptSnapshot: [ProviderPromptMessage],
    output: String
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
      + promptSnapshot
      + [ProviderPromptMessage(role: Chat.Message.Role.assistant.rawValue, content: output)]
    cachedSession = CachedMLXSession(
      session: cached.session,
      prefix: completedPrefix,
      identity: cached.identity,
      state: completedState
    )
    activeGenerationRegistry.clearIfCurrent(generationID)
  }

  private func markSessionNativeToolCallBoundary(
    generationID: MLXGenerationID,
    historyPrefix: [ProviderPromptMessage],
    promptSnapshot: [ProviderPromptMessage],
    output: String,
    nativeToolCalls: [ChatRuntimeToolCall]
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

    let assistantSnapshots = [
      Self.nativeToolCallBoundarySnapshot(
        output: output,
        nativeToolCalls: nativeToolCalls
      )
    ]
    let completedPrefix =
      historyPrefix
      + promptSnapshot
      + assistantSnapshots
    cachedSession = CachedMLXSession(
      session: cached.session,
      prefix: completedPrefix,
      identity: cached.identity,
      state: completedState
    )
    activeGenerationRegistry.clearIfCurrent(generationID)
  }

  private func markCachedSessionInvalid(
    generationID: MLXGenerationID,
    reason: MLXSessionInvalidationReason
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

    cachedSession = CachedMLXSession(
      session: cached.session,
      prefix: cached.prefix,
      identity: cached.identity,
      state: dirtyState
    )
    activeGenerationRegistry.clearIfCurrent(generationID)
  }

  private func invalidateCachedSession(reason: MLXSessionInvalidationReason) {
    generationOwnership.invalidateActiveGeneration()
    cachedSession = nil
    pendingCacheInvalidationReason = reason
  }

  #if DEBUG
    // Test-only; exercised through @testable import.
    // swiftlint:disable:next unused_declaration
    func registerActiveGenerationForTesting(id: MLXGenerationID, task: Task<Void, Never>) {
      activeGenerationRegistry.register(id: id, task: task)
    }
  #endif

  private func configureMLXMemory() {
    if Memory.cacheLimit > Self.maxMLXCacheBytes {
      Memory.cacheLimit = Self.maxMLXCacheBytes
    }
  }

  private static let maxMLXCacheBytes = 512 * 1024 * 1024

  private static func chatTemplateAdditionalContext(
    reasoningEnabled: Bool
  ) -> [String: any Sendable] {
    ["enable_thinking": reasoningEnabled]
  }

  private static func toolCallSnapshot(
    from toolCall: ChatRuntimeToolCall
  ) -> ProviderToolCall {
    ProviderToolCall(
      id: RuntimeToolCallID.uuid(from: toolCall.id).map(RuntimeToolCallID.string(for:))
        ?? toolCall.id,
      name: toolCall.name,
      arguments: toolCall.arguments
    )
  }

  static func nativeToolCallBoundarySnapshot(
    output: String,
    nativeToolCalls: [ChatRuntimeToolCall]
  ) -> ProviderPromptMessage {
    ProviderPromptMessage(
      role: Chat.Message.Role.assistant.rawValue,
      content: ProviderPromptProjection.canonicalAssistantToolBoundaryContent(output),
      toolCalls: nativeToolCalls.map(Self.toolCallSnapshot(from:))
    )
  }
}
