import Foundation
import LocalCoderCore
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

nonisolated enum GemmaMLXRuntimeError: LocalizedError {
  case modelNotLoaded
  case missingUserMessage
  case invalidChatTemplateMessageSequence
  case unsupportedArchitecture
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
    case .interruptedStream:
      "Local Gemma generation ended before the model reported completion."
    }
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
}

nonisolated enum GemmaSessionInvalidationReason: Equatable, Sendable {
  case signatureMismatch
  case cancelled
  case interrupted
  case downstreamTerminated
  case runtimeError
  case modelChanged

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
  case invalidatedModelChanged = "invalidated_model_changed"

  static func generationInvalidationReason(
    from reason: GemmaSessionInvalidationReason
  ) -> GemmaSessionCacheReason {
    switch reason {
    case .signatureMismatch:
      .invalidatedRenderedContextChanged
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
    }
  }
}

nonisolated struct GemmaMessageSnapshot: Equatable, Sendable {
  let role: String
  let content: String
}

nonisolated struct GemmaRenderedContextSignature: Equatable, Sendable {
  let rendererVersion: Int
  let renderedHistoryHash: String
  let generationSettingsHash: String

  var traceValue: String {
    "renderer-v\(rendererVersion):history-\(renderedHistoryHash):settings-\(generationSettingsHash)"
  }
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
  case inFlight(generationID: GemmaGenerationID)
  case dirty(reason: GemmaSessionInvalidationReason)

  var isReusable: Bool {
    self == .clean
  }

  var invalidationReason: GemmaSessionInvalidationReason? {
    switch self {
    case .clean:
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
  let shouldReuse: Bool
  let trace: GemmaSessionCacheTrace
}

nonisolated private struct CachedGemmaSession {
  let session: ChatSession
  let prefix: [GemmaMessageSnapshot]
  let settings: ChatGenerationSettings
  let contextSignature: GemmaRenderedContextSignature
  let state: GemmaCachedSessionState
}

nonisolated private struct GemmaSessionCachePlan {
  let session: ChatSession
  let trace: GemmaSessionCacheTrace
}

nonisolated struct GemmaModelStreamPlan {
  let stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  let task: Task<Void, Never>
}

final actor GemmaMLXRuntime: ChatModelRuntime {
  private var modelContainer: ModelContainer?
  private var cachedSession: CachedGemmaSession?
  private var pendingCacheInvalidationReason: GemmaSessionInvalidationReason?
  private var contextTokenLimit: Int?
  private var generationOwnership = GemmaGenerationOwnership()
  private var activeGenerationRegistry = GemmaActiveGenerationRegistry()
  private var activeCompletionContext: ActiveGemmaCompletionContext?

  func load(configuration: ChatModelConfiguration) async throws {
    #if !arch(arm64)
      throw GemmaMLXRuntimeError.unsupportedArchitecture
    #endif

    configureMLXMemory()

    let modelConfiguration = ModelConfiguration(
      directory: configuration.localModelDirectory,
      extraEOSTokens: ["<end_of_turn>"]
    )

    let container = try await LLMModelFactory.shared.loadContainer(
      from: LocalDownloader(),
      using: LocalTokenizerLoader(),
      configuration: modelConfiguration
    )

    modelContainer = container
    contextTokenLimit = configuration.contextTokenLimit
    invalidateCachedSession(reason: .modelChanged)
  }

  func unload() async {
    invalidateCachedSession(reason: .modelChanged)
    modelContainer = nil
    contextTokenLimit = nil
    Memory.clearCache()
  }

  func clearContext() async {
    invalidateCachedSession(reason: .signatureMismatch)
    Memory.clearCache()
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
    for transcript: ModelFacingTranscript,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = attachments
    _ = systemPrompt
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }

    let rawMessages = try Self.validatedTemplateMessages(
      transcript.entries.map(Self.chatMessage(from:))
    )
    .map { ["role": $0.role.rawValue, "content": $0.content] as [String: any Sendable] }
    let usedTokens = try await modelContainer.perform { context in
      try context.tokenizer.applyChatTemplate(messages: rawMessages).count
    }

    return ChatContextUsage(usedTokens: usedTokens, tokenLimit: contextTokenLimit)
  }

  func streamReply(
    for transcript: ModelFacingTranscript,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = attachments
    _ = systemPrompt
    let streamStartStartedAt = Date()
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }

    let entries = transcript.entries
    guard let lastUserIndex = entries.lastIndex(where: { $0.frozenContent.role == .user }) else {
      throw GemmaMLXRuntimeError.missingUserMessage
    }

    let promptMessage = Self.chatMessage(from: entries[lastUserIndex])
    let generateParameters = GenerateParameters(
      maxTokens: settings.maxTokens,
      maxKVSize: settings.maxKVSize,
      temperature: Float(settings.temperature),
      topP: Float(settings.topP),
      topK: settings.topK
    )
    let history = try Self.generationHistoryMessages(
      from: entries[..<lastUserIndex]
    )
    let historySnapshot = Self.messageSnapshot(from: history)
    let finalPrompt = promptMessage.content
    await supersedeActiveGenerationBeforeStartingNew()
    let generationID = generationOwnership.beginGeneration()
    let cachePlan = prepareSession(
      modelContainer: modelContainer,
      history: history,
      historySnapshot: historySnapshot,
      settings: settings,
      generateParameters: generateParameters,
      generationID: generationID
    )

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
      contextTokenLimit: contextTokenLimit
    )

    let stream = cachePlan.session.streamDetails(to: finalPrompt, images: [], videos: [])
    if let traceMetadata {
      await traceMetadata.tracer.recordTurnTraceEvent(
        TurnTraceEvent(
          turnID: traceMetadata.turnID,
          generationID: traceID,
          phase: .runtimeStreamStart,
          durationMs: Date().timeIntervalSince(streamStartStartedAt) * 1000,
          promptBytes: finalPrompt.utf8.count,
          messageCount: entries.count,
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
          currentPromptContextChanged: cachePlan.trace.currentPromptContextChanged
        )
      )
    }
    activeCompletionContext = ActiveGemmaCompletionContext(
      generationID: generationID,
      historyPrefix: historySnapshot,
      prompt: finalPrompt,
      settings: settings
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
          settings: settings
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
      settings: context.settings
    )
  }

  private func supersedeActiveGenerationBeforeStartingNew() async {
    guard let superseded = activeGenerationRegistry.supersedeActiveGeneration() else {
      return
    }

    markCachedSessionInvalid(generationID: superseded.id, reason: .cancelled)
    await superseded.task.value
  }

  private func prepareSession(
    modelContainer: ModelContainer,
    history: [Chat.Message],
    historySnapshot: [GemmaMessageSnapshot],
    settings: ChatGenerationSettings,
    generateParameters: GenerateParameters,
    generationID: GemmaGenerationID
  ) -> GemmaSessionCachePlan {
    let contextSignature = Self.renderedContextSignature(
      for: historySnapshot,
      settings: settings
    )
    let cached = cachedSession
    let decision = Self.cacheDecision(
      cachedPrefix: cached?.prefix,
      cachedSettings: cached?.settings,
      cachedContextSignature: cached?.contextSignature,
      cachedState: cached?.state ?? pendingCacheInvalidationReason.map { .dirty(reason: $0) },
      currentHistory: historySnapshot,
      currentSettings: settings
    )
    pendingCacheInvalidationReason = nil

    if decision.shouldReuse, let cached {
      cachedSession = CachedGemmaSession(
        session: cached.session,
        prefix: cached.prefix,
        settings: cached.settings,
        contextSignature: cached.contextSignature,
        state: .inFlight(generationID: generationID)
      )
      return GemmaSessionCachePlan(session: cached.session, trace: decision.trace)
    }

    let session = ChatSession(
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
    return GemmaSessionCachePlan(session: session, trace: decision.trace)
  }

  private func markSessionCompleted(
    generationID: GemmaGenerationID,
    historyPrefix: [GemmaMessageSnapshot],
    prompt: String,
    output: String,
    settings: ChatGenerationSettings
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
        settings: settings
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
    _ = activeGenerationRegistry.supersedeActiveGeneration()
    generationOwnership.invalidateActiveGeneration()
    activeCompletionContext = nil
    cachedSession = nil
    pendingCacheInvalidationReason = reason
  }

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

  nonisolated static func chatMessage(from entry: ModelContextEntry) -> Chat.Message {
    switch entry.frozenContent.role {
    case .user:
      return .user(entry.frozenContent.content)
    case .assistant:
      return .assistant(entry.frozenContent.content)
    }
  }

  nonisolated static func cacheDecision(
    cachedPrefix: [GemmaMessageSnapshot]?,
    cachedSettings: ChatGenerationSettings?,
    cachedContextSignature: GemmaRenderedContextSignature? = nil,
    cachedState: GemmaCachedSessionState?,
    currentHistory: [GemmaMessageSnapshot],
    currentSettings: ChatGenerationSettings,
    currentRendererVersion: Int = gemmaRendererVersion
  ) -> GemmaSessionCacheDecision {
    let currentSignature = renderedContextSignature(
      for: currentHistory,
      settings: currentSettings,
      rendererVersion: currentRendererVersion
    )
    let previousSignature =
      cachedContextSignature
      ?? cachedPrefix.flatMap { prefix in
        cachedSettings.map { settings in
          renderedContextSignature(for: prefix, settings: settings)
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
    let shouldReuse: Bool
    let mismatchReason: String?
    if cachedPrefix == nil, let invalidationReason = cachedState?.invalidationReason {
      cacheMode = invalidationReason.cacheMode
      cacheReason = .generationInvalidationReason(from: invalidationReason)
      shouldReuse = false
      mismatchReason = nil
    } else if cachedPrefix == nil {
      cacheMode = .newSessionHistory
      cacheReason = .newSessionNoCache
      shouldReuse = false
      mismatchReason = nil
    } else if cachedState?.isReusable != true {
      let invalidationReason = cachedState?.invalidationReason ?? .interrupted
      cacheMode = invalidationReason.cacheMode
      cacheReason = .generationInvalidationReason(from: invalidationReason)
      shouldReuse = false
      mismatchReason = nil
    } else if cachedSettings != currentSettings {
      cacheMode = .invalidatedSignatureMismatch
      cacheReason = .invalidatedSettingsChanged
      shouldReuse = false
      mismatchReason = "settings_changed"
    } else if cachedPrefix == currentHistory {
      if previousSignature == currentSignature {
        cacheMode = .sessionReused
        cacheReason = .sessionReused
        shouldReuse = true
        mismatchReason = nil
      } else {
        cacheMode = .invalidatedSignatureMismatch
        cacheReason = Self.signatureMismatchReason(
          previousSignature: previousSignature,
          currentSignature: currentSignature
        )
        shouldReuse = false
        mismatchReason = "rendered_context_signature_changed"
      }
    } else if appendOnly {
      cacheMode = .invalidatedSignatureMismatch
      cacheReason = .invalidatedHistoryAppended
      shouldReuse = false
      mismatchReason = "history_appended"
    } else {
      cacheMode = .invalidatedSignatureMismatch
      cacheReason = Self.historyMismatchReason(
        systemPromptChanged: systemPromptChanged,
        currentPromptContextChanged: currentPromptContextChanged
      )
      shouldReuse = false
      mismatchReason = "history_prefix_mismatch"
    }

    return GemmaSessionCacheDecision(
      shouldReuse: shouldReuse,
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

  nonisolated static func renderedContextSignature(
    for messages: [GemmaMessageSnapshot],
    settings: ChatGenerationSettings,
    rendererVersion: Int = gemmaRendererVersion
  ) -> GemmaRenderedContextSignature {
    GemmaRenderedContextSignature(
      rendererVersion: rendererVersion,
      renderedHistoryHash: contextSignature(for: messages),
      generationSettingsHash: generationSettingsSignature(for: settings)
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
    return .invalidatedRenderedContextChanged
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
    guard let currentPromptContextRange = currentPromptContextRange(in: block) else {
      return block
    }
    return String(block[..<currentPromptContextRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func currentPromptContextBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> String? {
    guard let block = systemInstructionBlock(from: messages),
      let currentPromptContextRange = currentPromptContextRange(in: block)
    else {
      return nil
    }
    return String(block[currentPromptContextRange.lowerBound...])
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

  nonisolated private static func currentPromptContextRange(
    in systemInstructionBlock: String
  ) -> Range<String.Index>? {
    let markers = [
      "Attached file:",
      "Current focused file:",
      "Recent files are ambiguous:",
    ]
    return markers.compactMap { systemInstructionBlock.range(of: $0) }
      .min { $0.lowerBound < $1.lowerBound }
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

  nonisolated static func modelStream(
    from stream: AsyncThrowingStream<Generation, Error>,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markCancelled: @escaping @Sendable (GemmaSessionInvalidationReason) async -> Void
  ) -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    modelStreamPlan(
      from: stream,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cacheTrace,
      markCompleted: markCompleted,
      markCancelled: markCancelled
    ).stream
  }

  nonisolated static func modelStreamPlan(
    from stream: AsyncThrowingStream<Generation, Error>,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markCancelled: @escaping @Sendable (GemmaSessionInvalidationReason) async -> Void
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
      defer {
        let memoryClearStartedAt = Date()
        Memory.clearCache()
        if let traceMetadata {
          let durationMs = Date().timeIntervalSince(memoryClearStartedAt) * 1000
          Task {
            await traceMetadata.tracer.recordTurnTraceEvent(
              TurnTraceEvent(
                turnID: traceMetadata.turnID,
                generationID: traceID,
                phase: .memoryClear,
                durationMs: durationMs,
                toolLoopIteration: traceMetadata.toolLoopIteration,
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
      }

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

          if let info = generation.info {
            let metrics = ChatGenerationMetrics(
              generatedTokenCount: info.generationTokenCount,
              tokensPerSecond: info.tokensPerSecond
            )
            completedMetrics = metrics
            if let traceMetadata {
              let decodeStartedAt = firstChunkAt ?? iterationStartedAt
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
          await GemmaDebugTraceStore.shared.traceResponse(
            id: traceID,
            output: output,
            metrics: completedMetrics,
            error: error.localizedDescription
          )
          continuation.finish(throwing: error)
          return
        }

        await markCompleted(output)
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

  nonisolated static func templateMessages(
    from transcript: ModelFacingTranscript,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) throws -> [Chat.Message] {
    _ = attachments
    _ = systemPrompt
    return try validatedTemplateMessages(
      normalizedChatMessages(
        transcript.entries.map(Self.chatMessage(from:))
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
    from entries: ArraySlice<ModelContextEntry>
  ) throws -> [Chat.Message] {
    var history = normalizedChatMessages(entries.map(Self.chatMessage(from:)))

    while history.last?.role == .user {
      history.removeLast()
    }

    return try validatedTemplateMessages(history)
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
