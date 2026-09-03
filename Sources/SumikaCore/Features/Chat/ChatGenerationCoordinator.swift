import Foundation

private enum StreamingFlushReason: String {
  case timeInterval = "time_interval"
  case characterLimit = "character_limit"
  case thinkingCompleted = "thinking_completed"
  case toolCall = "tool_call"
  case completed
  case outputLimit = "output_limit"
  case streamExit = "stream_exit"
}

private struct StreamingFlushBatch {
  let content: String
  let eventCount: Int

  var characterCount: Int {
    content.count
  }
}

private struct StreamingChunkBuffer {
  private(set) var content = ""
  private(set) var eventCount = 0
  private var lastFlushDate: Date
  private let flushInterval: TimeInterval
  private let characterLimit: Int

  init(startDate: Date, flushInterval: TimeInterval, characterLimit: Int) {
    lastFlushDate = startDate
    self.flushInterval = flushInterval
    self.characterLimit = characterLimit
  }

  var isEmpty: Bool {
    content.isEmpty
  }

  mutating func append(_ chunk: String) {
    content += chunk
    eventCount += 1
  }

  func automaticFlushReason(at timestamp: Date) -> StreamingFlushReason? {
    if content.count >= characterLimit {
      return .characterLimit
    }
    if timestamp.timeIntervalSince(lastFlushDate) >= flushInterval {
      return .timeInterval
    }
    return nil
  }

  mutating func drain(at timestamp: Date) -> StreamingFlushBatch? {
    guard !content.isEmpty else {
      return nil
    }
    let batch = StreamingFlushBatch(content: content, eventCount: eventCount)
    content = ""
    eventCount = 0
    lastFlushDate = timestamp
    return batch
  }

  mutating func discard() {
    content = ""
    eventCount = 0
  }
}

enum ChatGenerationError: LocalizedError, Equatable, Sendable {
  case streamInterrupted
  case emptyModelResponse
  case outputLimitReached
  case contextLimitReached

  var errorDescription: String? {
    switch self {
    case .streamInterrupted:
      "Model generation ended before completion."
    case .emptyModelResponse:
      "Model generation completed without visible text or tool calls."
    case .outputLimitReached:
      "Local model generation reached its token limit before the response was complete. Increase Max Tokens or ask the model to make a smaller change."
    case .contextLimitReached:
      "The response reached the remaining conversation context limit. Start a new chat or reduce the supplied content."
    }
  }
}

enum ChatGenerationTermination: Equatable, Sendable {
  case completed
  case outputLimit(
    discardedToolProtocolTail: Bool, reason: ChatGenerationOutputLimit.Reason = .configuredMaximum)
}

struct ChatGenerationResult: Equatable, Sendable {
  var assistantContent: String
  var nativeToolCalls: [ChatRuntimeToolCall]
  var termination: ChatGenerationTermination

  init(
    assistantContent: String,
    nativeToolCalls: [ChatRuntimeToolCall] = [],
    termination: ChatGenerationTermination = .completed
  ) {
    self.assistantContent = assistantContent
    self.nativeToolCalls = nativeToolCalls
    self.termination = termination
  }
}

@MainActor
struct ChatGenerationCoordinator {
  private let runtimeOperations: RuntimeOperationCoordinator
  private let turnTracer: any TurnTracing
  private let streamingFlushInterval: TimeInterval
  private let streamingFlushCharacterLimit: Int
  private let streamingNow: () -> Date

  init(
    runtimeOperations: RuntimeOperationCoordinator,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    streamingFlushInterval: TimeInterval = 0.05,
    streamingFlushCharacterLimit: Int = 240,
    streamingNow: @escaping () -> Date = Date.init
  ) {
    self.runtimeOperations = runtimeOperations
    self.turnTracer = turnTracer
    self.streamingFlushInterval = streamingFlushInterval
    self.streamingFlushCharacterLimit = streamingFlushCharacterLimit
    self.streamingNow = streamingNow
  }

  init(
    runtime: any ChatModelRuntime,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    streamingFlushInterval: TimeInterval,
    streamingFlushCharacterLimit: Int,
    streamingNow: @escaping () -> Date = Date.init
  ) {
    self.init(
      runtimeOperations: RuntimeOperationCoordinator(runtime: runtime),
      turnTracer: turnTracer,
      streamingFlushInterval: streamingFlushInterval,
      streamingFlushCharacterLimit: streamingFlushCharacterLimit,
      streamingNow: streamingNow
    )
  }

  func streamAssistantReplyResult(
    turnID: ChatTurn.ID? = nil,
    operationID requestedOperationID: UUID? = nil,
    toolLoopIteration: Int? = nil,
    interactionMode: WorkspaceInteractionMode? = nil,
    transcript: ModelPromptProjection,
    attachments: [ChatAttachment] = [],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    appendChunk: (String) -> Void,
    appendThinkingChunk: (String) -> Void = { _ in },
    completeThinking: () -> Void = {},
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateRuntimeCacheDebugSnapshot: (RuntimeCacheDebugSnapshot?) async -> Void = { _ in }
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
        promptPlan: promptPlan,
        settings: settings,
        appendChunk: appendChunk,
        appendThinkingChunk: appendThinkingChunk,
        completeThinking: completeThinking,
        updateGenerationMetrics: updateGenerationMetrics,
        updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot
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
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    appendChunk: (String) -> Void,
    appendThinkingChunk: (String) -> Void,
    completeThinking: () -> Void,
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateRuntimeCacheDebugSnapshot: (RuntimeCacheDebugSnapshot?) async -> Void
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

    let stream = try await requestRuntimeStream(
      transcript: transcript,
      attachments: attachments,
      promptPlan: promptPlan,
      settings: settings,
      interactionMode: interactionMode,
      operationID: operationID
    )
    try await refreshRuntimeCacheDebugSnapshot(
      operationID: operationID,
      updateRuntimeCacheDebugSnapshot: updateRuntimeCacheDebugSnapshot
    )

    var generatedContent = ""
    var generatedThinkingContentLength = 0
    var nativeToolCalls: [ChatRuntimeToolCall] = []
    let streamingStartDate = streamingNow()
    var visibleBuffer = StreamingChunkBuffer(
      startDate: streamingStartDate,
      flushInterval: streamingFlushInterval,
      characterLimit: streamingFlushCharacterLimit
    )
    var thinkingBuffer = StreamingChunkBuffer(
      startDate: streamingStartDate,
      flushInterval: streamingFlushInterval,
      characterLimit: streamingFlushCharacterLimit
    )
    var lastEventDate = streamingStartDate
    var didComplete = false
    var outputLimit: ChatGenerationOutputLimit?
    var shouldFlushBufferedChunksOnExit = true

    func flushBufferedChunks(at timestamp: Date, reason: StreamingFlushReason) {
      guard !visibleBuffer.isEmpty else {
        return
      }
      guard !Task.isCancelled else {
        visibleBuffer.discard()
        return
      }
      guard let batch = visibleBuffer.drain(at: timestamp) else {
        return
      }

      let startedAt = Date()
      #if DEBUG
        ChatDiagnostics.measure(
          "Generation visible UI flush",
          category: .generation,
          metadata: ChatDiagnostics.Metadata(
            "channel=visible reason=\(reason.rawValue) batchTokenEvents=\(batch.eventCount) batchChars=\(batch.characterCount) visibleChars=\(generatedContent.count) thinkingChars=\(generatedThinkingContentLength)"
          )
        ) {
          appendChunk(batch.content)
        }
      #else
        appendChunk(batch.content)
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
    }

    func flushBufferedThinkingChunks(at timestamp: Date, reason: StreamingFlushReason) {
      guard !thinkingBuffer.isEmpty else {
        return
      }
      guard !Task.isCancelled else {
        thinkingBuffer.discard()
        return
      }
      guard let batch = thinkingBuffer.drain(at: timestamp) else {
        return
      }

      #if DEBUG
        ChatDiagnostics.measure(
          "Generation thinking UI flush",
          category: .generation,
          metadata: ChatDiagnostics.Metadata(
            "channel=thinking reason=\(reason.rawValue) batchTokenEvents=\(batch.eventCount) batchChars=\(batch.characterCount) visibleChars=\(generatedContent.count) thinkingChars=\(generatedThinkingContentLength)"
          )
        ) {
          appendThinkingChunk(batch.content)
        }
      #else
        appendThinkingChunk(batch.content)
      #endif
    }

    defer {
      if shouldFlushBufferedChunksOnExit,
        !thinkingBuffer.isEmpty || !visibleBuffer.isEmpty
      {
        flushBufferedThinkingChunks(at: lastEventDate, reason: .streamExit)
        flushBufferedChunks(at: lastEventDate, reason: .streamExit)
      }
    }

    do {
      for try await event in stream {
        try Task.checkCancellation()
        try await runtimeOperations.checkCurrentOperation(operationID)
        let eventDate = streamingNow()
        lastEventDate = eventDate
        switch event {
        case .chunk(let chunk):
          generatedContent += chunk
          visibleBuffer.append(chunk)
          if let reason = visibleBuffer.automaticFlushReason(at: eventDate) {
            flushBufferedChunks(at: eventDate, reason: reason)
          }
        case .thinkingChunk(let chunk):
          thinkingBuffer.append(chunk)
          generatedThinkingContentLength += chunk.count
          if let reason = thinkingBuffer.automaticFlushReason(at: eventDate) {
            flushBufferedThinkingChunks(at: eventDate, reason: reason)
          }
        case .thinkingCompleted:
          flushBufferedThinkingChunks(at: eventDate, reason: .thinkingCompleted)
          flushBufferedChunks(at: eventDate, reason: .thinkingCompleted)
          completeThinking()
        case .toolCall(let toolCall):
          flushBufferedThinkingChunks(at: eventDate, reason: .toolCall)
          flushBufferedChunks(at: eventDate, reason: .toolCall)
          nativeToolCalls.append(toolCall)
        case .completed(let metrics):
          flushBufferedThinkingChunks(at: eventDate, reason: .completed)
          flushBufferedChunks(at: eventDate, reason: .completed)
          try await runtimeOperations.checkCurrentOperation(operationID)
          ChatDiagnostics.measure("Generation metrics update", category: .generation) {
            updateGenerationMetrics(metrics)
          }
          didComplete = true
        case .outputLimitReached(let limit):
          flushBufferedThinkingChunks(at: eventDate, reason: .outputLimit)
          flushBufferedChunks(at: eventDate, reason: .outputLimit)
          outputLimit = limit
        }
      }
    } catch is CancellationError {
      shouldFlushBufferedChunksOnExit = false
      visibleBuffer.discard()
      thinkingBuffer.discard()
      throw CancellationError()
    }

    if !didComplete, outputLimit == nil, nativeToolCalls.isEmpty {
      throw ChatGenerationError.streamInterrupted
    }
    try await runtimeOperations.checkCurrentOperation(operationID)
    return ChatGenerationResult(
      assistantContent: generatedContent,
      nativeToolCalls: nativeToolCalls,
      termination: outputLimit.map {
        .outputLimit(discardedToolProtocolTail: $0.discardedToolProtocolTail, reason: $0.reason)
      } ?? .completed
    )
  }

  private func requestRuntimeStream(
    transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?,
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
      promptPlan: promptPlan,
      settings: settings,
      interactionMode: interactionMode,
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

}
