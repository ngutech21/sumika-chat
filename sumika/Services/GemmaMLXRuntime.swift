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

  nonisolated private static func appendTransientInstructions(
    _ instructions: [String],
    toPromptSnapshot promptSnapshot: [GemmaMessageSnapshot],
    promptMessages: [Chat.Message]
  ) -> (promptSnapshot: [GemmaMessageSnapshot], promptMessages: [Chat.Message]) {
    var updatedSnapshot = promptSnapshot
    var updatedMessages = promptMessages
    for instruction in instructions {
      if let lastSnapshot = updatedSnapshot.last,
        lastSnapshot.role == Chat.Message.Role.user.rawValue,
        !lastSnapshot.hasToolMetadata
      {
        updatedSnapshot[updatedSnapshot.count - 1] = GemmaMessageSnapshot(
          role: Chat.Message.Role.user.rawValue,
          content: [lastSnapshot.content, instruction].joined(separator: "\n\n"),
          imageSignatures: lastSnapshot.imageSignatures
        )
      } else {
        updatedSnapshot.append(
          GemmaMessageSnapshot(
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
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    try await streamReply(
      for: transcript,
      attachments: attachments,
      promptPlan: ChatRuntimePromptPlan(stableInstructions: systemPrompt),
      settings: settings
    )
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    try await streamReply(
      for: transcript,
      attachments: attachments,
      promptPlan: ChatRuntimePromptPlan(
        stableInstructions: systemPrompt,
        toolContext: toolContext
      ),
      settings: settings
    )
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
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
    let generationInput = try GemmaHistoryRenderer.generationInput(
      from: transcript,
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
    let systemPrompt = promptPlan.stableInstructions
    let toolSpecs = GemmaNativeToolSchema.toolSpecs(from: promptPlan.toolContext)
    let cacheSystemPrompt = promptPlan.cacheIdentityInstructions
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
      "Gemma prepare session",
      category: .generation
    )
    let cachePlan = prepareSession(
      modelContainer: modelContainer,
      history: history,
      historySnapshot: historySnapshot,
      promptMessages: promptMessages,
      systemPrompt: systemPrompt,
      cacheSystemPrompt: cacheSystemPrompt,
      settings: settings,
      generateParameters: generateParameters,
      additionalContext: additionalContext,
      projectionMode: projectionMode,
      generationID: generationID
    )
    ChatDiagnostics.endInterval(prepareSessionInterval)
    lastRuntimeCacheDebugSnapshot = GemmaSessionCachePolicy.runtimeCacheDebugSnapshot(
      from: cachePlan.trace,
      appendDeltaStartIndex: cachePlan.appendDeltaStartIndex,
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
    let streamPlan = GemmaModelStreamProcessor.modelStreamPlan(
      from: stream,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cachePlan.trace,
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
        promptBytes: GemmaSessionCachePolicy.contentByteCount(for: cachePlan.streamMessages),
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
    promptMessages: [Chat.Message],
    systemPrompt: String,
    cacheSystemPrompt: String,
    settings: ChatGenerationSettings,
    generateParameters: GenerateParameters,
    additionalContext: [String: any Sendable],
    projectionMode: ModelContextProjectionMode,
    generationID: GemmaGenerationID
  ) -> GemmaSessionCachePlan {
    let currentIdentity = GemmaSessionCachePolicy.cacheIdentity(
      systemPrompt: cacheSystemPrompt,
      settings: settings,
      projectionMode: projectionMode
    )
    let cached = cachedSession
    let appendOnly: Bool
    let firstMismatchIndex: Int?
    if let cached {
      appendOnly = GemmaSessionCachePolicy.isPrefix(cached.prefix, of: historySnapshot)
      firstMismatchIndex = GemmaSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cached.prefix,
        currentHistory: historySnapshot
      )
    } else {
      appendOnly = false
      firstMismatchIndex = nil
    }
    let cachedState = cached?.state ?? pendingCacheInvalidationReason.map { .dirty(reason: $0) }
    let traceMode: GemmaSessionCacheMode
    let traceReason: GemmaSessionCacheReason
    let shouldReuse: Bool
    let appendDeltaStartIndex: Int?
    let mismatchReason: String?
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
      traceReason = GemmaSessionCachePolicy.identityMismatchReason(
        cached: cached.identity,
        current: currentIdentity
      )
      shouldReuse = false
      appendDeltaStartIndex = nil
      mismatchReason = "identity_changed"
    } else if appendOnly, let cached {
      let deltaStartIndex = cached.prefix.count
      if deltaStartIndex == historySnapshot.count {
        traceMode = .reusedSession
        traceReason = .reusedSession
        appendDeltaStartIndex = nil
      } else {
        traceMode = .appendDelta
        traceReason = .appendOnlyDelta
        appendDeltaStartIndex = deltaStartIndex
      }
      shouldReuse = true
      mismatchReason = nil
    } else {
      traceMode = .dirtyRebuild
      traceReason = .historyChanged
      shouldReuse = false
      appendDeltaStartIndex = nil
      mismatchReason = "history_changed"
    }

    let trace = GemmaSessionCachePolicy.trace(
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
      cached.session.instructions = GemmaSessionCachePolicy.chatSessionInstructions(
        for: traceMode,
        systemPrompt: systemPrompt
      )
      cached.session.generateParameters = generateParameters
      cached.session.additionalContext = additionalContext
      cachedSession = CachedGemmaSession(
        session: cached.session,
        prefix: cached.prefix,
        identity: cached.identity,
        state: .inFlight(generationID: generationID)
      )
      return GemmaSessionCachePlan(
        session: cached.session,
        trace: trace,
        appendDeltaStartIndex: appendDeltaStartIndex,
        streamMessages: GemmaSessionCachePolicy.streamMessages(
          history: history,
          promptMessages: promptMessages,
          appendDeltaStartIndex: appendDeltaStartIndex
        )
      )
    }

    let session = MLXLMCommon.ChatSession(
      modelContainer,
      instructions: GemmaSessionCachePolicy.chatSessionInstructions(
        for: traceMode,
        systemPrompt: systemPrompt
      ),
      history: history,
      generateParameters: generateParameters,
      additionalContext: additionalContext
    )
    cachedSession = CachedGemmaSession(
      session: session,
      prefix: historySnapshot,
      identity: currentIdentity,
      state: .inFlight(generationID: generationID)
    )
    return GemmaSessionCachePlan(
      session: session,
      trace: trace,
      appendDeltaStartIndex: nil,
      streamMessages: GemmaSessionCachePolicy.streamMessages(
        history: history,
        promptMessages: promptMessages,
        appendDeltaStartIndex: nil
      )
    )
  }

  private func markSessionCompleted(
    generationID: GemmaGenerationID,
    historyPrefix: [GemmaMessageSnapshot],
    promptSnapshot: [GemmaMessageSnapshot],
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
      + [GemmaMessageSnapshot(role: Chat.Message.Role.assistant.rawValue, content: output)]
    cachedSession = CachedGemmaSession(
      session: cached.session,
      prefix: completedPrefix,
      identity: cached.identity,
      state: completedState
    )
    activeGenerationRegistry.clearIfCurrent(generationID)
  }

  private func markSessionNativeToolCallBoundary(
    generationID: GemmaGenerationID,
    historyPrefix: [GemmaMessageSnapshot],
    promptSnapshot: [GemmaMessageSnapshot],
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

    let assistantOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let assistantSnapshots = [
      GemmaMessageSnapshot(
        role: Chat.Message.Role.assistant.rawValue,
        content: assistantOutput,
        toolCalls: nativeToolCalls.map(Self.toolCallSnapshot(from:))
      )
    ]
    let completedPrefix =
      historyPrefix
      + promptSnapshot
      + assistantSnapshots
    cachedSession = CachedGemmaSession(
      session: cached.session,
      prefix: completedPrefix,
      identity: cached.identity,
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
      identity: cached.identity,
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

  nonisolated private static func toolCallSnapshot(
    from toolCall: ChatRuntimeToolCall
  ) -> GemmaToolCallSnapshot {
    GemmaToolCallSnapshot(
      id: RuntimeToolCallID.uuid(from: toolCall.id).map(RuntimeToolCallID.string(for:))
        ?? toolCall.id,
      name: toolCall.name,
      arguments: toolCall.arguments
    )
  }
}
