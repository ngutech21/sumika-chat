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
  case invalidatedModelChanged = "invalidated_model_changed"
}

nonisolated enum GemmaSessionInvalidationReason: Equatable, Sendable {
  case signatureMismatch
  case cancelled
  case interrupted
  case modelChanged

  var cacheMode: GemmaSessionCacheMode {
    switch self {
    case .signatureMismatch:
      .invalidatedSignatureMismatch
    case .cancelled:
      .invalidatedCancelled
    case .interrupted:
      .invalidatedInterrupted
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

nonisolated struct GemmaSessionCacheTrace: Equatable, Sendable {
  let cacheMode: GemmaSessionCacheMode
  let contextSignature: String
  let previousContextSignature: String?
  let appendOnly: Bool
  let reusedMessageCount: Int
  let appendedMessageCount: Int
  let mismatchReason: String?
  let firstMismatchIndex: Int?
  let systemPromptChanged: Bool?
  let focusedContextChanged: Bool?
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
  let isReusable: Bool
  let invalidationReason: GemmaSessionInvalidationReason?
}

nonisolated private struct GemmaSessionCachePlan {
  let session: ChatSession
  let trace: GemmaSessionCacheTrace
}

final actor GemmaMLXRuntime: ChatModelRuntime {
  private var modelContainer: ModelContainer?
  private var cachedSession: CachedGemmaSession?
  private var pendingCacheInvalidationReason: GemmaSessionInvalidationReason?
  private var contextTokenLimit: Int?

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
    for messages: [ChatModelContextMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }

    let rawMessages = try Self.templateMessages(
      from: messages,
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
    for messages: [ChatModelContextMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    let streamStartStartedAt = Date()
    guard let modelContainer else {
      throw GemmaMLXRuntimeError.modelNotLoaded
    }

    guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
      throw GemmaMLXRuntimeError.missingUserMessage
    }

    let promptMessage = Self.generationPromptMessage(
      from: messages,
      lastUserIndex: lastUserIndex,
      attachments: attachments,
      systemPrompt: systemPrompt
    )
    let generateParameters = GenerateParameters(
      maxTokens: settings.maxTokens,
      maxKVSize: contextTokenLimit,
      temperature: Float(settings.temperature),
      topP: Float(settings.topP),
      topK: settings.topK
    )
    let history = try Self.generationHistoryMessages(
      from: messages[..<lastUserIndex]
    )
    let historySnapshot = Self.messageSnapshot(from: history)
    let finalPrompt = promptMessage.content
    let cachePlan = prepareSession(
      modelContainer: modelContainer,
      history: history,
      historySnapshot: historySnapshot,
      settings: settings,
      generateParameters: generateParameters
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
          messageCount: messages.count,
          cacheMode: cachePlan.trace.cacheMode.rawValue,
          interactionMode: traceMetadata.interactionMode,
          contextSignature: cachePlan.trace.contextSignature,
          previousContextSignature: cachePlan.trace.previousContextSignature,
          appendOnly: cachePlan.trace.appendOnly,
          reusedMessageCount: cachePlan.trace.reusedMessageCount,
          appendedMessageCount: cachePlan.trace.appendedMessageCount,
          mismatchReason: cachePlan.trace.mismatchReason,
          firstMismatchIndex: cachePlan.trace.firstMismatchIndex,
          systemPromptChanged: cachePlan.trace.systemPromptChanged,
          focusedContextChanged: cachePlan.trace.focusedContextChanged
        )
      )
    }
    return Self.modelStream(
      from: stream,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cachePlan.trace,
      markCompleted: { [weak self] output in
        await self?.markSessionCompleted(
          historyPrefix: historySnapshot,
          prompt: finalPrompt,
          output: output,
          settings: settings
        )
      },
      markCancelled: { [weak self] reason in
        await self?.markCachedSessionInvalid(reason: reason)
      }
    )
  }

  private func prepareSession(
    modelContainer: ModelContainer,
    history: [Chat.Message],
    historySnapshot: [GemmaMessageSnapshot],
    settings: ChatGenerationSettings,
    generateParameters: GenerateParameters
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
      cachedReusable: cached?.isReusable,
      invalidationReason: cached?.invalidationReason ?? pendingCacheInvalidationReason,
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
        isReusable: false,
        invalidationReason: .interrupted
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
      isReusable: false,
      invalidationReason: .interrupted
    )
    return GemmaSessionCachePlan(session: session, trace: decision.trace)
  }

  private func markSessionCompleted(
    historyPrefix: [GemmaMessageSnapshot],
    prompt: String,
    output: String,
    settings: ChatGenerationSettings
  ) {
    let completedPrefix =
      historyPrefix
      + [
        GemmaMessageSnapshot(role: Chat.Message.Role.user.rawValue, content: prompt),
        GemmaMessageSnapshot(role: Chat.Message.Role.assistant.rawValue, content: output),
      ]
    cachedSession = cachedSession.map { cached in
      CachedGemmaSession(
        session: cached.session,
        prefix: completedPrefix,
        settings: settings,
        contextSignature: Self.renderedContextSignature(
          for: completedPrefix,
          settings: settings
        ),
        isReusable: true,
        invalidationReason: nil
      )
    }
  }

  private func markCachedSessionInvalid(reason: GemmaSessionInvalidationReason) {
    cachedSession = cachedSession.map { cached in
      CachedGemmaSession(
        session: cached.session,
        prefix: cached.prefix,
        settings: cached.settings,
        contextSignature: cached.contextSignature,
        isReusable: false,
        invalidationReason: reason
      )
    }
  }

  private func invalidateCachedSession(reason: GemmaSessionInvalidationReason) {
    cachedSession = nil
    pendingCacheInvalidationReason = reason
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

  nonisolated static func cacheDecision(
    cachedPrefix: [GemmaMessageSnapshot]?,
    cachedSettings: ChatGenerationSettings?,
    cachedContextSignature: GemmaRenderedContextSignature? = nil,
    cachedReusable: Bool?,
    invalidationReason: GemmaSessionInvalidationReason?,
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
    let focusedContextChanged: Bool?
    if let cachedPrefix {
      mismatchIndex = firstMismatchIndex(cachedPrefix: cachedPrefix, currentHistory: currentHistory)
      systemPromptChanged =
        baseSystemInstructionBlock(from: cachedPrefix)
        != baseSystemInstructionBlock(from: currentHistory)
      focusedContextChanged =
        focusedContextBlock(from: cachedPrefix) != focusedContextBlock(from: currentHistory)
    } else {
      mismatchIndex = nil
      systemPromptChanged = nil
      focusedContextChanged = nil
    }

    let cacheMode: GemmaSessionCacheMode
    let shouldReuse: Bool
    let mismatchReason: String?
    if cachedPrefix == nil, let invalidationReason {
      cacheMode = invalidationReason.cacheMode
      shouldReuse = false
      mismatchReason = nil
    } else if cachedPrefix == nil {
      cacheMode = .newSessionHistory
      shouldReuse = false
      mismatchReason = nil
    } else if let invalidationReason, cachedReusable != true {
      cacheMode = invalidationReason.cacheMode
      shouldReuse = false
      mismatchReason = nil
    } else if cachedSettings != currentSettings {
      cacheMode = .invalidatedSignatureMismatch
      shouldReuse = false
      mismatchReason = "settings_changed"
    } else if cachedPrefix == currentHistory {
      if previousSignature == currentSignature {
        cacheMode = .sessionReused
        shouldReuse = true
        mismatchReason = nil
      } else {
        cacheMode = .invalidatedSignatureMismatch
        shouldReuse = false
        mismatchReason = "rendered_context_signature_changed"
      }
    } else if appendOnly {
      cacheMode = .invalidatedSignatureMismatch
      shouldReuse = false
      mismatchReason = "history_appended"
    } else {
      cacheMode = .invalidatedSignatureMismatch
      shouldReuse = false
      mismatchReason = "history_prefix_mismatch"
    }

    return GemmaSessionCacheDecision(
      shouldReuse: shouldReuse,
      trace: GemmaSessionCacheTrace(
        cacheMode: cacheMode,
        contextSignature: currentSignature.traceValue,
        previousContextSignature: previousSignature?.traceValue,
        appendOnly: appendOnly,
        reusedMessageCount: reusedMessageCount,
        appendedMessageCount: appendedMessageCount,
        mismatchReason: mismatchReason,
        firstMismatchIndex: mismatchReason == nil ? nil : mismatchIndex,
        systemPromptChanged: mismatchReason == nil ? nil : systemPromptChanged,
        focusedContextChanged: mismatchReason == nil ? nil : focusedContextChanged
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

  nonisolated private static func generationSettingsSignature(
    for settings: ChatGenerationSettings
  ) -> String {
    hashSignature { updateString in
      updateString(String(settings.maxTokens))
      updateString(String(settings.temperature))
      updateString(String(settings.topP))
      updateString(String(settings.topK))
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
    guard let focusedRange = focusedContextRange(in: block) else {
      return block
    }
    return String(block[..<focusedRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func focusedContextBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> String? {
    guard let block = systemInstructionBlock(from: messages),
      let focusedRange = focusedContextRange(in: block)
    else {
      return nil
    }
    return String(block[focusedRange.lowerBound...])
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

  nonisolated private static func focusedContextRange(
    in systemInstructionBlock: String
  ) -> Range<String.Index>? {
    let markers = [
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

  nonisolated private static func modelStream(
    from stream: AsyncThrowingStream<Generation, Error>,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markCancelled: @escaping @Sendable (GemmaSessionInvalidationReason) async -> Void
  ) -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    return AsyncThrowingStream(ChatModelStreamEvent.self, bufferingPolicy: .unbounded) {
      continuation in
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
                  cacheMode: cacheTrace.cacheMode.rawValue,
                  interactionMode: traceMetadata.interactionMode,
                  contextSignature: cacheTrace.contextSignature,
                  previousContextSignature: cacheTrace.previousContextSignature,
                  appendOnly: cacheTrace.appendOnly,
                  reusedMessageCount: cacheTrace.reusedMessageCount,
                  appendedMessageCount: cacheTrace.appendedMessageCount,
                  mismatchReason: cacheTrace.mismatchReason,
                  firstMismatchIndex: cacheTrace.firstMismatchIndex,
                  systemPromptChanged: cacheTrace.systemPromptChanged,
                  focusedContextChanged: cacheTrace.focusedContextChanged
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
                      ttftMs: ttftMs,
                      cacheMode: cacheTrace.cacheMode.rawValue,
                      interactionMode: traceMetadata.interactionMode,
                      contextSignature: cacheTrace.contextSignature,
                      previousContextSignature: cacheTrace.previousContextSignature,
                      appendOnly: cacheTrace.appendOnly,
                      reusedMessageCount: cacheTrace.reusedMessageCount,
                      appendedMessageCount: cacheTrace.appendedMessageCount,
                      mismatchReason: cacheTrace.mismatchReason,
                      firstMismatchIndex: cacheTrace.firstMismatchIndex,
                      systemPromptChanged: cacheTrace.systemPromptChanged,
                      focusedContextChanged: cacheTrace.focusedContextChanged
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
                    tokensPerSecond: info.tokensPerSecond,
                    cacheMode: cacheTrace.cacheMode.rawValue,
                    interactionMode: traceMetadata.interactionMode,
                    contextSignature: cacheTrace.contextSignature,
                    previousContextSignature: cacheTrace.previousContextSignature,
                    appendOnly: cacheTrace.appendOnly,
                    reusedMessageCount: cacheTrace.reusedMessageCount,
                    appendedMessageCount: cacheTrace.appendedMessageCount,
                    mismatchReason: cacheTrace.mismatchReason,
                    firstMismatchIndex: cacheTrace.firstMismatchIndex,
                    systemPromptChanged: cacheTrace.systemPromptChanged,
                    focusedContextChanged: cacheTrace.focusedContextChanged
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
            await markCancelled(.interrupted)
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
          await markCancelled(.interrupted)
          await GemmaDebugTraceStore.shared.traceResponse(
            id: traceID,
            output: output,
            metrics: completedMetrics,
            error: error.localizedDescription
          )
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  nonisolated static func templateMessages(
    from messages: [ChatModelContextMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) throws -> [Chat.Message] {
    try validatedTemplateMessages(
      normalizedChatMessages(
        renderedTemplateMessages(
          from: messages,
          attachments: attachments,
          fallbackSystemPrompt: systemPrompt
        )
      )
    )
  }

  nonisolated private static func renderedTemplateMessages(
    from messages: [ChatModelContextMessage],
    attachments: [ChatAttachment],
    fallbackSystemPrompt: String
  ) -> [Chat.Message] {
    renderedTemplateMessages(
      from: preparedContextMessages(from: messages, attachments: attachments),
      fallbackSystemPrompt: fallbackSystemPrompt
    )
  }

  nonisolated private static func preparedContextMessages(
    from messages: [ChatModelContextMessage],
    attachments: [ChatAttachment]
  ) -> [ChatModelContextMessage] {
    var contextMessages: [ChatModelContextMessage] = []

    if messages.isEmpty, !attachments.isEmpty {
      contextMessages.append(
        ChatModelContextMessage(role: .user, content: attachmentContextBlock(attachments)))
    } else if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) {
      contextMessages.append(contentsOf: messages[..<lastUserIndex])
      let lastUserMessage = messages[lastUserIndex]
      let prompt = promptWithAttachments(
        prompt: lastUserMessage.content,
        attachments: lastUserMessage.attachments + attachments
      )
      contextMessages.append(
        ChatModelContextMessage(
          id: lastUserMessage.id,
          turnID: lastUserMessage.turnID,
          sourceMessageID: lastUserMessage.sourceMessageID,
          role: .user,
          content: prompt,
          systemPromptSnapshot: lastUserMessage.systemPromptSnapshot
        )
      )
      let remainingMessages = messages[messages.index(after: lastUserIndex)...]
      contextMessages.append(contentsOf: remainingMessages)
    } else {
      contextMessages.append(contentsOf: messages)
    }

    return contextMessages
  }

  nonisolated private static func renderedTemplateMessages(
    from messages: [ChatModelContextMessage],
    fallbackSystemPrompt: String
  ) -> [Chat.Message] {
    let lastUserIndex = messages.lastIndex(where: { $0.role == .user })
    var pendingSystemContext: [String] = []
    var renderedMessages: [Chat.Message] = []

    for index in messages.indices {
      let message = messages[index]
      guard !message.content.isEmpty else {
        continue
      }

      switch message.role {
      case .system:
        if let systemMessage = normalizedSystemPrompt(message.content) {
          pendingSystemContext.append(systemMessage)
        }
      case .assistant:
        if renderedMessages.isEmpty, !pendingSystemContext.isEmpty {
          renderedMessages.append(
            .user(systemInstructionContent(pendingSystemContext.joined(separator: "\n\n"))))
          pendingSystemContext.removeAll()
        } else if !pendingSystemContext.isEmpty {
          pendingSystemContext.removeAll()
        }
        renderedMessages.append(.assistant(message.content))
      case .user:
        var systemContext: [String] = []
        if let snapshot = normalizedSystemPrompt(message.systemPromptSnapshot) {
          systemContext.append(snapshot)
        } else if index == lastUserIndex,
          let fallback = normalizedSystemPrompt(fallbackSystemPrompt)
        {
          systemContext.append(fallback)
        }
        systemContext.append(contentsOf: pendingSystemContext)
        pendingSystemContext.removeAll()

        renderedMessages.append(.user(userContent(message.content, systemContext: systemContext)))
      }
    }

    guard renderedMessages.isEmpty, !pendingSystemContext.isEmpty else {
      return renderedMessages
    }

    return [.user(systemInstructionContent(pendingSystemContext.joined(separator: "\n\n")))]
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
    from messages: ArraySlice<ChatModelContextMessage>,
    systemPrompt: String = ""
  ) throws -> [Chat.Message] {
    _ = systemPrompt
    var history = normalizedChatMessages(
      renderedTemplateMessages(from: Array(messages), fallbackSystemPrompt: "")
    )

    while history.last?.role == .user {
      history.removeLast()
    }

    return try validatedTemplateMessages(history)
  }

  nonisolated static func generationPromptMessage(
    from messages: [ChatModelContextMessage],
    lastUserIndex: Int,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) -> Chat.Message {
    let userMessage = messages[lastUserIndex]
    let prompt = promptWithAttachments(
      prompt: userMessage.content,
      attachments: userMessage.attachments + attachments
    )
    let promptSystemPrompt = userMessage.systemPromptSnapshot ?? systemPrompt
    let systemContext = systemContextForUserPrompt(
      at: lastUserIndex,
      in: messages,
      systemPrompt: promptSystemPrompt
    )

    return .user(userContent(prompt, systemContext: systemContext))
  }

  nonisolated private static func systemContextForUserPrompt(
    at userIndex: Int,
    in messages: [ChatModelContextMessage],
    systemPrompt: String
  ) -> [String] {
    var systemContext: [String] = []
    if let normalizedPrompt = normalizedSystemPrompt(systemPrompt) {
      systemContext.append(normalizedPrompt)
    }
    systemContext.append(
      contentsOf: systemMessagesImmediatelyBeforeUser(at: userIndex, in: messages))
    return systemContext
  }

  nonisolated private static func systemMessagesImmediatelyBeforeUser(
    at userIndex: Int,
    in messages: [ChatModelContextMessage]
  ) -> [String] {
    var systemMessages: [String] = []
    var cursor = userIndex

    while cursor > messages.startIndex {
      let previousIndex = messages.index(before: cursor)
      let message = messages[previousIndex]
      guard message.role == .system else {
        break
      }
      if let systemMessage = normalizedSystemPrompt(message.content) {
        systemMessages.insert(systemMessage, at: 0)
      }
      cursor = previousIndex
    }

    return systemMessages
  }

  nonisolated private static func normalizedSystemPrompt(_ systemPrompt: String) -> String? {
    let effectiveSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt
  }

  nonisolated private static func normalizedSystemPrompt(_ systemPrompt: String?) -> String? {
    guard let systemPrompt else {
      return nil
    }
    return normalizedSystemPrompt(systemPrompt)
  }

  nonisolated private static func userContent(
    _ content: String,
    systemContext: [String]
  ) -> String {
    let systemContext =
      systemContext
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    guard !systemContext.isEmpty else {
      return content
    }

    return """
      \(systemInstructionContent(systemContext))

      User request:
      \(content)
      """
  }

  nonisolated private static func systemInstructionContent(_ systemContext: String) -> String {
    """
    System instructions:
    \(systemContext)
    """
  }

}

nonisolated extension Chat.Message {
  fileprivate init?(_ message: ChatModelContextMessage) {
    guard !message.content.isEmpty else {
      return nil
    }

    switch message.role {
    case .user:
      self = .user(promptWithAttachments(prompt: message.content, attachments: message.attachments))
    case .assistant:
      self = .assistant(message.content)
    case .system:
      self = .system(message.content)
    }
  }
}

nonisolated private func promptWithAttachments(
  prompt: String,
  attachments: [ChatAttachment]
) -> String {
  guard !attachments.isEmpty else {
    return prompt
  }

  return """
    User request:
    \(prompt)

    Attached files for this request:
    \(attachmentContextBlock(attachments))

    Use the attached file contents above when answering this request.
    If the user says "file" or "the file", they mean the attached file.
    """
}

nonisolated private func attachmentContextBlock(_ attachments: [ChatAttachment]) -> String {
  attachments.enumerated().map { index, attachment in
    """
    File \(index + 1) of \(attachments.count)
    Name: \(attachment.displayName)
    Path: \(attachment.displayPath)
    <context_file path="\(attachment.displayPath)">
    \(attachment.content)
    </context_file>
    """
  }
  .joined(separator: "\n\n")
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
