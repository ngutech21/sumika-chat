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
  private var loadedModelPreservesHistoricalReasoning = false
  private var loadedModelReasoningEffort: ModelReasoningEffort?
  private var loadedThinkingBudgetPolicy: ThinkingBudgetPolicy = .unmanaged
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
  private let generationActivity: MLXGenerationActivity
  private let applicationStateSnapshotProvider: RuntimeApplicationStateSnapshotProvider

  init(
    debugTraceStore: MLXDebugTraceStore,
    applicationStateSnapshotProvider: @escaping RuntimeApplicationStateSnapshotProvider = {
      .unavailable
    },
    generationActivity: MLXGenerationActivity = .live
  ) {
    self.memoryCacheClearer = .live
    self.debugTraceStore = debugTraceStore
    self.generationActivity = generationActivity
    self.applicationStateSnapshotProvider = applicationStateSnapshotProvider
  }

  init(
    memoryCacheClearer: MLXMemoryCacheClearer = .live,
    debugTraceStore: MLXDebugTraceStore,
    applicationStateSnapshotProvider: @escaping RuntimeApplicationStateSnapshotProvider = {
      .unavailable
    },
    generationActivity: MLXGenerationActivity = .live
  ) {
    self.memoryCacheClearer = memoryCacheClearer
    self.debugTraceStore = debugTraceStore
    self.generationActivity = generationActivity
    self.applicationStateSnapshotProvider = applicationStateSnapshotProvider
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
    let memoryTraceScope = await debugTraceStore.beginMemoryScope(phase: .modelLoadBefore)

    do {
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
      loadedModelPreservesHistoricalReasoning =
        configuration.supportsHistoricalReasoningPreservation
      loadedModelReasoningEffort = configuration.reasoningEffort
      loadedThinkingBudgetPolicy = configuration.thinkingBudgetPolicy
      contextTokenLimit = configuration.contextTokenLimit
      lastRuntimeCacheDebugSnapshot = nil
      invalidateCachedSession(reason: .modelChanged)
      await debugTraceStore.recordMemorySnapshot(
        phase: .modelLoadAfter,
        scope: memoryTraceScope,
        modelLoadOutcome: .loaded
      )
    } catch {
      await debugTraceStore.recordMemorySnapshot(
        phase: .modelLoadAfter,
        scope: memoryTraceScope,
        modelLoadOutcome: .failed
      )
      throw error
    }
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
    loadedModelPreservesHistoricalReasoning = false
    loadedModelReasoningEffort = nil
    loadedThinkingBudgetPolicy = .unmanaged
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

  static func generateParameters(from settings: ChatGenerationSettings) -> GenerateParameters {
    GenerateParameters(
      maxTokens: settings.maxTokens,
      maxKVSize: nil,
      temperature: Float(settings.temperature),
      topP: Float(settings.topP),
      topK: settings.topK,
      minP: Float(settings.minP),
      repetitionPenalty: mlxRepetitionPenalty(from: settings),
      repetitionContextSize: settings.repetitionContextSize,
      presencePenalty: Float(settings.presencePenalty),
      presenceContextSize: settings.repetitionContextSize
    )
  }

  static func appendTransientInstructions(
    _ instructions: [String],
    toPromptSnapshot promptSnapshot: [ProviderPromptMessage]
  ) -> [ProviderPromptMessage] {
    var updatedSnapshot = promptSnapshot
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

    }
    return updatedSnapshot
  }

  // Ordered stream setup keeps the memory baseline adjacent to upstream stream creation.
  // swiftlint:disable:next function_body_length
  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
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
      images: imageInputs,
      reasoningEnabled: settings.reasoningEnabled,
      supportsHistoricalReasoningPreservation:
        loadedModelPreservesHistoricalReasoning,
      reasoningEffort: loadedModelReasoningEffort
    )
    let generateParameters = Self.generateParameters(from: settings)
    let additionalContext = generationInput.additionalContext
    let systemPrompt = promptPlan.stableInstructions
    let toolSpecs = MLXToolMapper.toolSpecs(from: promptPlan.toolContext)
    let historySnapshot = generationInput.historySnapshot
    let history = generationInput.history
    let promptSnapshot = Self.appendTransientInstructions(
      promptPlan.transientInstructions,
      toPromptSnapshot: generationInput.promptSnapshot
    )
    let promptMessages = MLXHistoryRenderer.chatMessages(
      from: promptSnapshot,
      images: imageInputs,
      supportsHistoricalReasoningPreservation:
        loadedModelPreservesHistoricalReasoning
    )
    let finalPrompt = promptMessages.map(\.content).joined(separator: "\n\n")
    let traceMetadata = TurnTraceContext.current
    let traceID = traceMetadata?.generationID ?? UUID()
    let thinkingBudgetPlan = try await prepareThinkingBudgetPlan(
      modelContainer: modelContainer,
      generateParameters: generateParameters,
      settings: settings,
      interactionMode: interactionMode,
      traceID: traceID,
      systemPrompt: systemPrompt,
      history: history,
      finalPrompt: finalPrompt,
      imageAttachments: imageAttachments
    )
    await supersedeActiveGenerationBeforeStartingNew()
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
      thinkingBudgetIdentity: thinkingBudgetPlan.identity,
      components: thinkingBudgetPlan.components,
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
      imageAttachments: imageAttachments,
      thinkingBudget: thinkingBudgetPlan.trace,
      interactionMode: interactionMode
    )

    let createStreamInterval = ChatDiagnostics.beginInterval(
      "MLX create stream",
      category: .generation
    )
    let estimateGeneratedTokenCount = await generationTokenEstimator(
      modelContainer: modelContainer
    )
    let runtimeCacheDiagnostics = try await beginRuntimeCacheDiagnostics(
      modelContainer: modelContainer,
      generateParameters: generateParameters,
      cachePlan: cachePlan,
      traceID: traceID
    )
    let memoryTraceScope = await debugTraceStore.beginMemoryScope(
      phase: .generationStart,
      generationID: traceID,
      traceMetadata: traceMetadata
    )
    let startedGeneration = generationActivity.start {
      cachePlan.session.streamDetails(to: cachePlan.streamMessages)
    }
    var activityLeaseHandedOff = false
    defer {
      if !activityLeaseHandedOff {
        startedGeneration.activityLease.end()
      }
    }
    let generationProgressTracer = makeGenerationProgressTracer(
      traceID: traceID,
      traceMetadata: traceMetadata,
      startedAt: startedGeneration.startedAt,
      generationActivityRequest: startedGeneration.activityLease.request,
      estimateTokenCount: estimateGeneratedTokenCount
    )
    ChatDiagnostics.endInterval(createStreamInterval)
    await recordRuntimeStreamStart(
      traceID: traceID,
      traceMetadata: traceMetadata,
      cachePlan: cachePlan,
      streamStartStartedAt: streamStartStartedAt,
      messageCount: transcript.entries.count,
      imageAttachments: imageAttachments,
      applicationState: applicationStateSnapshotProvider(),
      generationActivityRequest: startedGeneration.activityLease.request
    )
    let streamPlan = MLXModelStreamProcessor.modelStreamPlan(
      from: startedGeneration.stream,
      reasoningTraceFormat: settings.reasoningEnabled ? loadedReasoningTraceFormat : .none,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cachePlan.trace,
      debugTraceStore: debugTraceStore,
      runtimeCacheDiagnostics: runtimeCacheDiagnostics,
      generationProgressTracer: generationProgressTracer,
      generationStartedAt: startedGeneration.startedAt,
      memoryTraceScope: memoryTraceScope,
      generationActivityLease: startedGeneration.activityLease,
      applicationStateSnapshotProvider: applicationStateSnapshotProvider,
      thinkingBudgetTrace: thinkingBudgetPlan.trace,
      thinkingBudgetEnforcementState: thinkingBudgetPlan.enforcementState,
      markCompleted: { [weak self] assistant in
        await self?.markSessionCompleted(
          generationID: generationID,
          historyPrefix: historySnapshot,
          promptSnapshot: promptSnapshot,
          assistant: assistant
        )
      },
      markNativeToolCallBoundary: { [weak self] assistant, nativeToolCalls in
        await self?.markSessionNativeToolCallBoundary(
          generationID: generationID,
          historyPrefix: historySnapshot,
          promptSnapshot: promptSnapshot,
          assistant: assistant,
          nativeToolCalls: nativeToolCalls
        )
      },
      markCancelled: { [weak self, runtimeCacheDiagnostics] reason in
        await runtimeCacheDiagnostics?.invalidate()
        await self?.markCachedSessionInvalid(generationID: generationID, reason: reason)
      }
    )
    activityLeaseHandedOff = true
    activeGenerationRegistry.register(id: generationID, task: streamPlan.task)
    if generationOwnership.activeGenerationID != generationID {
      activeGenerationRegistry.clearIfCurrent(generationID)
    }
    return streamPlan.stream
  }
}

extension MLXChatRuntime {
  private func makeGenerationProgressTracer(
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    startedAt: Date,
    generationActivityRequest: GenerationActivityRequest,
    estimateTokenCount: (@Sendable (String) -> Int)?
  ) -> MLXGenerationProgressTracer {
    guard let estimateTokenCount else {
      return .disabled
    }
    return MLXGenerationProgressTracer(
      traceID: traceID,
      traceMetadata: traceMetadata,
      debugTraceStore: debugTraceStore,
      startedAt: startedAt,
      applicationStateSnapshotProvider: applicationStateSnapshotProvider,
      generationActivityRequest: generationActivityRequest,
      estimateTokenCount: estimateTokenCount
    )
  }

  private func generationTokenEstimator(
    modelContainer: ModelContainer
  ) async -> (@Sendable (String) -> Int)? {
    guard MLXDebugTraceStore.isEnabled else {
      return nil
    }
    let tokenizer = await modelContainer.tokenizer
    return { output in
      tokenizer.encode(text: output, addSpecialTokens: false).count
    }
  }

  private func beginRuntimeCacheDiagnostics(
    modelContainer: ModelContainer,
    generateParameters: GenerateParameters,
    cachePlan: MLXSessionCachePlan,
    traceID: UUID
  ) async throws -> MLXRuntimeCacheDiagnostics? {
    guard let runtimeCacheDiagnostics else {
      return nil
    }
    let cacheCapabilities = try await MLXRuntimeCacheDiagnostics.capabilities(
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
    return runtimeCacheDiagnostics
  }

  private func prepareThinkingBudgetPlan(
    modelContainer: ModelContainer,
    generateParameters: GenerateParameters,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?,
    traceID: UUID,
    systemPrompt: String,
    history: [Chat.Message],
    finalPrompt: String,
    imageAttachments: [ChatAttachment]
  ) async throws -> MLXThinkingBudgetPlan {
    let attemptedTrace = MLXThinkingBudgetPlanner.trace(
      policy: loadedThinkingBudgetPolicy,
      reasoningEnabled: settings.reasoningEnabled,
      interactionMode: interactionMode
    )
    do {
      return try await MLXThinkingBudgetPlanner.makePlan(
        policy: loadedThinkingBudgetPolicy,
        reasoningEnabled: settings.reasoningEnabled,
        interactionMode: interactionMode,
        modelContainer: modelContainer,
        generateParameters: generateParameters
      )
    } catch {
      try await traceDebugRequest(
        id: traceID,
        systemPrompt: systemPrompt,
        history: history,
        prompt: finalPrompt,
        settings: settings,
        imageAttachments: imageAttachments,
        thinkingBudget: attemptedTrace,
        interactionMode: interactionMode
      )
      await debugTraceStore.traceResponse(
        id: traceID,
        output: "",
        metrics: nil,
        error: error.localizedDescription,
        thinkingBudget: attemptedTrace,
        thinkingBudgetOutcome: .preflightFailed(
          MLXThinkingBudgetPlanner.diagnostic(for: error)
        )
      )
      throw error
    }
  }

  private func traceDebugRequest(
    id: UUID,
    systemPrompt: String,
    history: [Chat.Message],
    prompt: String,
    settings: ChatGenerationSettings,
    imageAttachments: [ChatAttachment],
    thinkingBudget: MLXThinkingBudgetTrace,
    interactionMode: WorkspaceInteractionMode?
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
      imageAttachments: imageAttachments,
      thinkingBudget: thinkingBudget,
      interactionMode: interactionMode
    )
  }

  private func recordRuntimeStreamStart(
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cachePlan: MLXSessionCachePlan,
    streamStartStartedAt: Date,
    messageCount: Int,
    imageAttachments: [ChatAttachment],
    applicationState: RuntimeApplicationStateSnapshot,
    generationActivityRequest: GenerationActivityRequest
  ) async {
    let event = TurnTraceEvent(
      turnID: traceMetadata?.turnID,
      generationID: traceID,
      phase: .runtimeStreamStart,
      durationMs: Date().timeIntervalSince(streamStartStartedAt) * 1000,
      promptBytes: MLXSessionCachePolicy.contentByteCount(for: cachePlan.streamMessages),
      messageCount: messageCount,
      toolLoopIteration: traceMetadata?.toolLoopIteration,
      cacheMode: cachePlan.trace.cacheMode.rawValue,
      cacheReason: cachePlan.trace.cacheReason.rawValue,
      interactionMode: traceMetadata?.interactionMode,
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
      imageByteCount: MLXHistoryRenderer.imageByteCount(from: imageAttachments),
      applicationActivation: applicationState.applicationActivation,
      applicationVisibility: applicationState.applicationVisibility,
      applicationOcclusion: applicationState.applicationOcclusion,
      mainWindowVisibility: applicationState.mainWindowVisibility,
      generationActivityRequest: generationActivityRequest
    )
    if let traceMetadata {
      await traceMetadata.tracer.recordTurnTraceEvent(event)
    } else {
      await debugTraceStore.recordTurnTraceEvent(event)
    }
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
    thinkingBudgetIdentity: MLXThinkingBudgetIdentity?,
    components: GenerationComponents,
    generationID: MLXGenerationID
  ) -> MLXSessionCachePlan {
    let currentIdentity = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: systemPrompt,
      settings: settings,
      projectionMode: projectionMode,
      toolSpecs: toolSpecs,
      additionalContext: additionalContext,
      thinkingBudgetIdentity: thinkingBudgetIdentity
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
      cached.session.components = components
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
      components: components,
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
    assistant: MLXCompletedAssistantSnapshot
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
      + [
        ProviderPromptMessage(
          role: Chat.Message.Role.assistant.rawValue,
          content: assistant.visibleContent,
          reasoningContent: loadedModelPreservesHistoricalReasoning
            ? assistant.completedReasoningContent
            : nil
        )
      ]
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
    assistant: MLXCompletedAssistantSnapshot,
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
        output: assistant.visibleContent,
        completedReasoningContent: assistant.completedReasoningContent,
        supportsHistoricalReasoningPreservation:
          loadedModelPreservesHistoricalReasoning,
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
    completedReasoningContent: String? = nil,
    supportsHistoricalReasoningPreservation: Bool = false,
    nativeToolCalls: [ChatRuntimeToolCall]
  ) -> ProviderPromptMessage {
    ProviderPromptMessage(
      role: Chat.Message.Role.assistant.rawValue,
      content: ProviderPromptProjection.canonicalAssistantToolBoundaryContent(
        output),
      reasoningContent: supportsHistoricalReasoningPreservation
        ? completedReasoningContent
        : nil,
      toolCalls: nativeToolCalls.map(Self.toolCallSnapshot(from:))
    )
  }
}
