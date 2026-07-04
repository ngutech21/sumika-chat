import Foundation

public enum ChatGenerationError: LocalizedError, Equatable, Sendable {
  case streamInterrupted
  case emptyModelResponse

  public var errorDescription: String? {
    switch self {
    case .streamInterrupted:
      "Model generation ended before completion."
    case .emptyModelResponse:
      "Model generation completed without visible text or tool calls."
    }
  }
}

public struct ChatGenerationResult: Equatable, Sendable {
  public var assistantContent: String
  public var nativeToolCalls: [ChatRuntimeToolCall]

  public init(
    assistantContent: String,
    nativeToolCalls: [ChatRuntimeToolCall] = []
  ) {
    self.assistantContent = assistantContent
    self.nativeToolCalls = nativeToolCalls
  }
}

@MainActor
public struct ChatGenerationCoordinator {
  private let runtimeOperations: RuntimeOperationCoordinator
  private let turnTracer: any TurnTracing
  private let streamingFlushInterval: TimeInterval
  private let streamingFlushCharacterLimit: Int

  public init(
    runtimeOperations: RuntimeOperationCoordinator,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    streamingFlushInterval: TimeInterval,
    streamingFlushCharacterLimit: Int
  ) {
    self.runtimeOperations = runtimeOperations
    self.turnTracer = turnTracer
    self.streamingFlushInterval = streamingFlushInterval
    self.streamingFlushCharacterLimit = streamingFlushCharacterLimit
  }

  public init(
    runtime: any ChatModelRuntime,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    streamingFlushInterval: TimeInterval,
    streamingFlushCharacterLimit: Int
  ) {
    self.init(
      runtimeOperations: RuntimeOperationCoordinator(runtime: runtime),
      turnTracer: turnTracer,
      streamingFlushInterval: streamingFlushInterval,
      streamingFlushCharacterLimit: streamingFlushCharacterLimit
    )
  }

  public func streamAssistantReply(
    turnID: ChatTurn.ID? = nil,
    operationID: UUID? = nil,
    toolLoopIteration: Int? = nil,
    interactionMode: WorkspaceInteractionMode? = nil,
    transcript: ModelPromptProjection,
    attachments: [ChatAttachment] = [],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    appendChunk: (String) -> Void,
    appendThinkingChunk: (String) -> Void = { _ in },
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateRuntimeCacheDebugSnapshot: (RuntimeCacheDebugSnapshot?) async -> Void = { _ in },
    updateContextUsage: () async -> Void
  ) async throws -> String {
    let result = try await streamAssistantReplyResult(
      turnID: turnID,
      operationID: operationID,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode,
      transcript: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt,
      settings: settings,
      toolContext: nil,
      appendChunk: appendChunk,
      appendThinkingChunk: appendThinkingChunk,
      updateGenerationMetrics: updateGenerationMetrics,
      updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
      updateContextUsage: updateContextUsage
    )
    return result.assistantContent
  }

  public func streamAssistantReplyResult(
    turnID: ChatTurn.ID? = nil,
    operationID requestedOperationID: UUID? = nil,
    toolLoopIteration: Int? = nil,
    interactionMode: WorkspaceInteractionMode? = nil,
    transcript: ModelPromptProjection,
    attachments: [ChatAttachment] = [],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext? = nil,
    appendChunk: (String) -> Void,
    appendThinkingChunk: (String) -> Void = { _ in },
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateRuntimeCacheDebugSnapshot: (RuntimeCacheDebugSnapshot?) async -> Void = { _ in },
    updateContextUsage: () async -> Void
  ) async throws -> ChatGenerationResult {
    let operationID =
      if let requestedOperationID {
        requestedOperationID
      } else {
        await runtimeOperations.currentOperation()
      }
    let generationID = UUID()
    let metadata = TurnTraceMetadata(
      turnID: turnID,
      generationID: generationID,
      tracer: turnTracer,
      toolLoopIteration: toolLoopIteration,
      interactionMode: interactionMode
    )

    return try await TurnTraceContext.$current.withValue(metadata) {
      return try await streamAssistantReplyWithTraceContext(
        turnID: turnID,
        operationID: operationID,
        generationID: generationID,
        interactionMode: interactionMode,
        transcript: transcript,
        attachments: attachments,
        systemPrompt: systemPrompt,
        settings: settings,
        toolContext: toolContext,
        appendChunk: appendChunk,
        appendThinkingChunk: appendThinkingChunk,
        updateGenerationMetrics: updateGenerationMetrics,
        updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot,
        updateContextUsage: updateContextUsage
      )
    }
  }

  private func streamAssistantReplyWithTraceContext(
    turnID: ChatTurn.ID?,
    operationID: UUID,
    generationID: UUID,
    interactionMode: WorkspaceInteractionMode?,
    transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?,
    appendChunk: (String) -> Void,
    appendThinkingChunk: (String) -> Void,
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateRuntimeCacheDebugSnapshot: (RuntimeCacheDebugSnapshot?) async -> Void,
    updateContextUsage: () async -> Void
  ) async throws -> ChatGenerationResult {
    let streamReplyInterval = ChatDiagnostics.beginInterval(
      "Generation stream reply",
      category: .generation,
      metadata: ChatDiagnostics.Metadata(
        "messageCount=\(transcript.entries.count) attachmentCount=\(attachments.count) mode=\(interactionMode?.rawValue ?? "unknown")"
      )
    )
    defer {
      ChatDiagnostics.endInterval(streamReplyInterval)
    }

    let generationStartedAt = Date()
    let stream = try await requestRuntimeStream(
      transcript: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt,
      settings: settings,
      toolContext: toolContext,
      operationID: operationID
    )
    try await refreshRuntimeCacheDebugSnapshot(
      operationID: operationID,
      updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot
    )

    var bufferedChunk = ""
    var bufferedThinkingChunk = ""
    var bufferedChunkEventCount = 0
    var bufferedThinkingChunkEventCount = 0
    var generatedContent = ""
    var generatedThinkingContentLength = 0
    var nativeToolCalls: [ChatRuntimeToolCall] = []
    var lastFlushDate = Date()
    var lastThinkingFlushDate = Date()
    var didComplete = false
    var shouldFlushBufferedChunksOnExit = true

    func flushBufferedChunks() {
      guard !bufferedChunk.isEmpty else {
        return
      }
      guard !Task.isCancelled else {
        bufferedChunk = ""
        bufferedChunkEventCount = 0
        return
      }

      let startedAt = Date()
      let batchCharacterCount = bufferedChunk.count
      let batchEventCount = bufferedChunkEventCount
      #if DEBUG
        ChatDiagnostics.measure(
          "Generation visible UI flush",
          category: .generation,
          metadata: ChatDiagnostics.Metadata(
            "batchTokenEvents=\(batchEventCount) batchChars=\(batchCharacterCount) visibleChars=\(generatedContent.count) thinkingChars=\(generatedThinkingContentLength)"
          )
        ) {
          appendChunk(bufferedChunk)
        }
      #else
        appendChunk(bufferedChunk)
      #endif
      let durationMs = Date().timeIntervalSince(startedAt) * 1000
      Task {
        await turnTracer.recordTurnTraceEvent(
          TurnTraceEvent(
            turnID: turnID,
            generationID: generationID,
            phase: .uiFlush,
            durationMs: durationMs,
            messageCount: transcript.entries.count,
            toolLoopIteration: TurnTraceContext.current?.toolLoopIteration,
            interactionMode: interactionMode
          )
        )
      }
      bufferedChunk = ""
      bufferedChunkEventCount = 0
      lastFlushDate = Date()
    }

    func flushBufferedThinkingChunks() {
      guard !bufferedThinkingChunk.isEmpty else {
        return
      }
      guard !Task.isCancelled else {
        bufferedThinkingChunk = ""
        bufferedThinkingChunkEventCount = 0
        return
      }

      let batchCharacterCount = bufferedThinkingChunk.count
      let batchEventCount = bufferedThinkingChunkEventCount
      #if DEBUG
        ChatDiagnostics.measure(
          "Generation thinking UI flush",
          category: .generation,
          metadata: ChatDiagnostics.Metadata(
            "batchTokenEvents=\(batchEventCount) batchChars=\(batchCharacterCount) visibleChars=\(generatedContent.count) thinkingChars=\(generatedThinkingContentLength)"
          )
        ) {
          appendThinkingChunk(bufferedThinkingChunk)
        }
      #else
        appendThinkingChunk(bufferedThinkingChunk)
      #endif
      bufferedThinkingChunk = ""
      bufferedThinkingChunkEventCount = 0
      lastThinkingFlushDate = Date()
    }

    func shouldFlushBufferedChunks() -> Bool {
      bufferedChunk.count >= streamingFlushCharacterLimit
        || Date().timeIntervalSince(lastFlushDate) >= streamingFlushInterval
    }

    func shouldFlushBufferedThinkingChunks() -> Bool {
      bufferedThinkingChunk.count >= streamingFlushCharacterLimit
        || Date().timeIntervalSince(lastThinkingFlushDate) >= streamingFlushInterval
    }

    defer {
      if shouldFlushBufferedChunksOnExit {
        flushBufferedThinkingChunks()
        flushBufferedChunks()
      }
    }

    do {
      for try await event in stream {
        try Task.checkCancellation()
        try await runtimeOperations.checkCurrentOperation(operationID)
        switch event {
        case .chunk(let chunk):
          generatedContent += chunk
          bufferedChunk += chunk
          bufferedChunkEventCount += 1
          if shouldFlushBufferedChunks() {
            flushBufferedChunks()
          }
        case .thinkingChunk(let chunk):
          bufferedThinkingChunk += chunk
          bufferedThinkingChunkEventCount += 1
          generatedThinkingContentLength += chunk.count
          if shouldFlushBufferedThinkingChunks() {
            flushBufferedThinkingChunks()
          }
        case .toolCall(let toolCall):
          flushBufferedThinkingChunks()
          flushBufferedChunks()
          nativeToolCalls.append(toolCall)
        case .completed(let metrics):
          flushBufferedThinkingChunks()
          flushBufferedChunks()
          let completedMetrics = try await generationMetrics(
            from: metrics,
            generatedContent: generatedContent,
            startedAt: generationStartedAt,
            operationID: operationID
          )
          try await runtimeOperations.checkCurrentOperation(operationID)
          ChatDiagnostics.measure("Generation metrics update", category: .generation) {
            updateGenerationMetrics(completedMetrics)
          }
          await refreshContextUsage(updateContextUsage)
          didComplete = true
        }
      }
    } catch is CancellationError {
      shouldFlushBufferedChunksOnExit = false
      bufferedChunk = ""
      bufferedThinkingChunk = ""
      bufferedChunkEventCount = 0
      bufferedThinkingChunkEventCount = 0
      throw CancellationError()
    }

    if !didComplete, nativeToolCalls.isEmpty {
      throw ChatGenerationError.streamInterrupted
    }
    try await runtimeOperations.checkCurrentOperation(operationID)
    return ChatGenerationResult(
      assistantContent: generatedContent,
      nativeToolCalls: nativeToolCalls
    )
  }

  private func requestRuntimeStream(
    transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?,
    operationID: UUID
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    let interval = ChatDiagnostics.beginInterval(
      "Generation runtime stream request",
      category: .generation
    )
    defer {
      ChatDiagnostics.endInterval(interval)
    }
    return try await runtimeOperations.streamReply(
      for: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt,
      settings: settings,
      toolContext: toolContext,
      operationID: operationID
    )
  }

  private func refreshRuntimeCacheDebugSnapshot(
    operationID: UUID,
    updateRuntimeCacheDebugSnapshot: (RuntimeCacheDebugSnapshot?) async -> Void
  ) async throws {
    let interval = ChatDiagnostics.beginInterval(
      "Generation runtime cache snapshot",
      category: .generation
    )
    defer {
      ChatDiagnostics.endInterval(interval)
    }
    let snapshot = try await runtimeOperations.runtimeCacheDebugSnapshot(operationID: operationID)
    await updateRuntimeCacheDebugSnapshot(snapshot)
  }

  private func refreshContextUsage(_ updateContextUsage: () async -> Void) async {
    let interval = ChatDiagnostics.beginInterval(
      "Generation context usage refresh",
      category: .generation
    )
    defer {
      ChatDiagnostics.endInterval(interval)
    }
    await updateContextUsage()
  }

  private func generationMetrics(
    from metrics: ChatGenerationMetrics?,
    generatedContent: String,
    startedAt: Date,
    operationID: UUID
  ) async throws -> ChatGenerationMetrics? {
    let durationMs = Date().timeIntervalSince(startedAt) * 1000
    if let metrics {
      return ChatGenerationMetrics(
        generatedTokenCount: metrics.generatedTokenCount,
        tokensPerSecond: metrics.tokensPerSecond,
        durationMs: durationMs
      )
    }

    return try await partialGenerationMetrics(
      generatedContent: generatedContent,
      durationMs: durationMs,
      operationID: operationID
    )
  }

  private func partialGenerationMetrics(
    generatedContent: String,
    durationMs: Double,
    operationID: UUID
  ) async throws -> ChatGenerationMetrics? {
    guard !generatedContent.isEmpty else {
      return nil
    }

    let tokenCountInterval = ChatDiagnostics.beginInterval(
      "Generation partial token count",
      category: .generation
    )
    defer {
      ChatDiagnostics.endInterval(tokenCountInterval)
    }
    let generatedTokenCount = try await runtimeOperations.generatedTokenCount(
      for: generatedContent,
      operationID: operationID
    )
    let durationSeconds = max(durationMs / 1000, 0.001)
    return ChatGenerationMetrics(
      generatedTokenCount: generatedTokenCount,
      tokensPerSecond: Double(generatedTokenCount) / durationSeconds,
      durationMs: durationMs
    )
  }
}
