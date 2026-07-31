import Foundation
import MLXLMCommon
import SumikaCore

struct MLXModelStreamPlan {
  let stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  let task: Task<Void, Never>
}

enum MLXModelStreamProcessor {
  private struct StreamTerminationState {
    var reachedTokenLimit = false
    var discardedToolProtocolTail = false
    var terminatedDownstream = false
  }

  static func modelStreamPlan(
    from stream: AsyncThrowingStream<Generation, Error>,
    reasoningTraceFormat: ReasoningTraceFormat = .none,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    debugTraceStore: MLXDebugTraceStore,
    runtimeCacheDiagnostics: MLXRuntimeCacheDiagnostics? = nil,
    generationProgressTracer: MLXGenerationProgressTracer = .disabled,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markNativeToolCallBoundary: @escaping @Sendable (String, [ChatRuntimeToolCall]) async -> Void =
      {
        _, _ in
      },
    markCancelled: @escaping @Sendable (MLXSessionInvalidationReason) async -> Void,
    memoryCacheClearer: MLXMemoryCacheClearer = .live
  ) -> MLXModelStreamPlan {
    let (outputStream, continuation) = AsyncThrowingStream<ChatModelStreamEvent, Error>
      .makeStream(bufferingPolicy: .unbounded)
    let task = Task {
      let streamInterval = ChatDiagnostics.beginInterval(
        "MLX process model stream",
        category: .generation
      )
      defer { ChatDiagnostics.endInterval(streamInterval) }
      var output = ""
      var visibleOutput = ""
      var reasoningParser = ReasoningTraceParser(format: reasoningTraceFormat)
      var completedMetrics: ChatGenerationMetrics?
      let iterationStartedAt = Date()
      var firstChunkAt: Date?
      var termination = StreamTerminationState()
      var nativeToolCalls: [ChatRuntimeToolCall] = []
      var usedNativeToolCallIDs = Set<UUID>()
      var pendingChunk: String?
      var generationProgressTracer = generationProgressTracer

      do {
        generationLoop: for try await generation in stream {
          try Task.checkCancellation()

          if let chunk = generation.chunk {
            firstChunkAt = await recordRuntimeTTFTIfNeeded(
              firstChunkAt,
              traceID: traceID,
              traceMetadata: traceMetadata,
              cacheTrace: cacheTrace,
              iterationStartedAt: iterationStartedAt
            )
            output += chunk
            await generationProgressTracer.record(output: output)
            if yieldModelChunk(
              chunk,
              pendingChunk: &pendingChunk,
              reasoningParser: &reasoningParser,
              to: continuation,
              visibleOutput: &visibleOutput
            ) {
              termination.terminatedDownstream = true
              break generationLoop
            }
          }

          if let toolCall = generation.toolCall {
            if yieldToolCall(
              toolCall,
              usedIDs: &usedNativeToolCallIDs,
              nativeToolCalls: &nativeToolCalls,
              to: continuation
            ) {
              termination.terminatedDownstream = true
              break generationLoop
            }
          }

          if let info = generation.info {
            await recordRuntimePrefill(
              info,
              traceID: traceID,
              traceMetadata: traceMetadata,
              cacheTrace: cacheTrace,
              runtimeCacheDiagnostics: runtimeCacheDiagnostics
            )
            switch info.stopReason {
            case .stop:
              if flushPendingChunk(
                &pendingChunk,
                reasoningParser: &reasoningParser,
                to: continuation,
                visibleOutput: &visibleOutput
              ) {
                termination.terminatedDownstream = true
                break generationLoop
              }
            case .length:
              termination.reachedTokenLimit = true
              termination.discardedToolProtocolTail = pendingChunk != nil
              pendingChunk = nil
            case .cancelled:
              pendingChunk = nil
              throw CancellationError()
            }
            if yieldSegments(
              reasoningParser.finish(),
              to: continuation,
              visibleOutput: &visibleOutput
            ) {
              termination.terminatedDownstream = true
              break generationLoop
            }
            let metrics = await recordRuntimeDecode(
              info,
              traceID: traceID,
              traceMetadata: traceMetadata,
              cacheTrace: cacheTrace
            )
            completedMetrics = metrics
            if !termination.reachedTokenLimit {
              if case .terminated = continuation.yield(.completed(metrics)) {
                termination.terminatedDownstream = true
                break generationLoop
              }
            }
          }
        }

        if !termination.terminatedDownstream,
          flushPendingChunk(
            &pendingChunk,
            reasoningParser: &reasoningParser,
            to: continuation,
            visibleOutput: &visibleOutput
          )
        {
          termination.terminatedDownstream = true
        }

        let finalizeInterval = ChatDiagnostics.beginInterval(
          "MLX finalize model stream",
          category: .generation
        )
        defer { ChatDiagnostics.endInterval(finalizeInterval) }
        await finalizeStream(
          continuation: continuation,
          output: output,
          visibleOutput: visibleOutput,
          completedMetrics: completedMetrics,
          didTerminateDownstream: termination.terminatedDownstream,
          didCompleteNaturally: completedMetrics != nil && !termination.reachedTokenLimit,
          didReachTokenLimit: termination.reachedTokenLimit,
          didDiscardToolProtocolTail: termination.discardedToolProtocolTail,
          nativeToolCalls: nativeToolCalls,
          traceID: traceID,
          traceMetadata: traceMetadata,
          cacheTrace: cacheTrace,
          debugTraceStore: debugTraceStore,
          runtimeCacheDiagnostics: runtimeCacheDiagnostics,
          markCompleted: markCompleted,
          markNativeToolCallBoundary: markNativeToolCallBoundary,
          markCancelled: markCancelled,
          memoryCacheClearer: memoryCacheClearer
        )
      } catch is CancellationError {
        await markCancelled(.cancelled)
        await debugTraceStore.traceResponse(
          id: traceID,
          output: output,
          metrics: completedMetrics,
          error: CancellationError().localizedDescription
        )
        continuation.finish(throwing: CancellationError())
      } catch {
        await markCancelled(.runtimeError)
        await clearMemoryCache(
          reason: .runtimeError,
          traceID: traceID,
          traceMetadata: traceMetadata,
          cacheTrace: cacheTrace,
          debugTraceStore: debugTraceStore,
          memoryCacheClearer: memoryCacheClearer
        )
        await debugTraceStore.traceResponse(
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

    return MLXModelStreamPlan(stream: outputStream, task: task)
  }

  private static func recordRuntimeTTFTIfNeeded(
    _ firstChunkAt: Date?,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    iterationStartedAt: Date
  ) async -> Date? {
    guard firstChunkAt == nil else {
      return firstChunkAt
    }
    let now = Date()
    await recordRuntimeTTFT(
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cacheTrace,
      iterationStartedAt: iterationStartedAt,
      firstChunkAt: now
    )
    return now
  }

  private static func recordRuntimeTTFT(
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    iterationStartedAt: Date,
    firstChunkAt: Date
  ) async {
    guard let traceMetadata else {
      return
    }
    let ttftMs = firstChunkAt.timeIntervalSince(iterationStartedAt) * 1000
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
        systemPromptChanged: cacheTrace.systemPromptChanged
      )
    )
  }

  private static func recordRuntimePrefill(
    _ info: GenerateCompletionInfo,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    runtimeCacheDiagnostics: MLXRuntimeCacheDiagnostics?
  ) async {
    let cacheDiagnostics = await runtimeCacheDiagnostics?.complete(
      generationID: traceID,
      info: info
    )
    guard let traceMetadata else {
      return
    }
    let event = TurnTraceEvent(
      turnID: traceMetadata.turnID,
      generationID: traceID,
      phase: .runtimePrefill,
      durationMs: info.promptTime * 1000,
      promptTokens: info.promptTokenCount,
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
      systemPromptChanged: cacheTrace.systemPromptChanged
    )
    let runtimeTrace = MLXRuntimePrefillTrace(
      event: event,
      cacheDiagnostics: cacheDiagnostics
    )
    if let runtimeTracer = traceMetadata.tracer as? any MLXRuntimeTracing {
      await runtimeTracer.recordRuntimePrefillTrace(runtimeTrace)
    } else {
      await traceMetadata.tracer.recordTurnTraceEvent(event)
    }
  }

  private static func recordRuntimeDecode(
    _ info: GenerateCompletionInfo,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace
  ) async -> ChatGenerationMetrics {
    let metrics = ChatGenerationMetrics(
      generatedTokenCount: info.generationTokenCount,
      tokensPerSecond: info.tokensPerSecond
    )
    guard let traceMetadata else {
      return metrics
    }
    await traceMetadata.tracer.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: traceMetadata.turnID,
        generationID: traceID,
        phase: .runtimeDecode,
        durationMs: info.generateTime * 1000,
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
        generatedTokenCount: info.generationTokenCount,
        generatedTokenCountIsEstimate: false
      )
    )
    return metrics
  }

  private static func yieldSegments(
    _ segments: [ReasoningTraceParser.Segment],
    to continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    visibleOutput: inout String
  ) -> Bool {
    for segment in segments {
      switch segment {
      case .visible(let visibleChunk):
        visibleOutput += visibleChunk
        if case .terminated = continuation.yield(.chunk(visibleChunk)) {
          return true
        }
      case .thinking(let thinkingChunk):
        if case .terminated = continuation.yield(.thinkingChunk(thinkingChunk)) {
          return true
        }
      }
    }
    return false
  }

  private static func yieldModelChunk(
    _ chunk: String,
    pendingChunk: inout String?,
    reasoningParser: inout ReasoningTraceParser,
    to continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    visibleOutput: inout String
  ) -> Bool {
    if isPotentialToolProtocolResidual(chunk) {
      pendingChunk = (pendingChunk ?? "") + chunk
      return false
    }
    if flushPendingChunk(
      &pendingChunk,
      reasoningParser: &reasoningParser,
      to: continuation,
      visibleOutput: &visibleOutput
    ) {
      return true
    }
    return yieldSegments(
      reasoningParser.append(chunk),
      to: continuation,
      visibleOutput: &visibleOutput
    )
  }

  private static func flushPendingChunk(
    _ pendingChunk: inout String?,
    reasoningParser: inout ReasoningTraceParser,
    to continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    visibleOutput: inout String
  ) -> Bool {
    guard let chunk = pendingChunk else {
      return false
    }
    pendingChunk = nil
    return yieldSegments(
      reasoningParser.append(chunk),
      to: continuation,
      visibleOutput: &visibleOutput
    )
  }

  private static func yieldToolCall(
    _ toolCall: MLXLMCommon.ToolCall,
    usedIDs: inout Set<UUID>,
    nativeToolCalls: inout [ChatRuntimeToolCall],
    to continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation
  ) -> Bool {
    let runtimeToolCall = MLXToolMapper.chatRuntimeToolCall(
      from: toolCall,
      usedIDs: &usedIDs
    )
    nativeToolCalls.append(runtimeToolCall)
    if case .terminated = continuation.yield(.toolCall(runtimeToolCall)) {
      return true
    }
    return false
  }

  private static let toolProtocolStartTags = ToolCallFormat.allCases.compactMap {
    $0.createParser().startTag
  }

  private static func isPotentialToolProtocolResidual(_ chunk: String) -> Bool {
    let content = chunk.drop(while: \.isWhitespace)
    guard !content.isEmpty else {
      return false
    }
    return toolProtocolStartTags.contains {
      content.hasPrefix($0) || $0.hasPrefix(content)
    }
  }

  private static func finalizeStream(
    continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    output: String,
    visibleOutput: String,
    completedMetrics: ChatGenerationMetrics?,
    didTerminateDownstream: Bool,
    didCompleteNaturally: Bool,
    didReachTokenLimit: Bool,
    didDiscardToolProtocolTail: Bool,
    nativeToolCalls: [ChatRuntimeToolCall],
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    debugTraceStore: MLXDebugTraceStore,
    runtimeCacheDiagnostics: MLXRuntimeCacheDiagnostics?,
    markCompleted: @Sendable (String) async -> Void,
    markNativeToolCallBoundary: @Sendable (String, [ChatRuntimeToolCall]) async -> Void,
    markCancelled: @Sendable (MLXSessionInvalidationReason) async -> Void,
    memoryCacheClearer: MLXMemoryCacheClearer
  ) async {
    if didTerminateDownstream {
      await markCancelled(.downstreamTerminated)
      continuation.finish()
      return
    }

    if didReachTokenLimit {
      let error = MLXChatRuntimeError.generationTokenLimitReached
      await markCancelled(.interrupted)
      await clearMemoryCache(
        reason: .interruptedStream,
        traceID: traceID,
        traceMetadata: traceMetadata,
        cacheTrace: cacheTrace,
        debugTraceStore: debugTraceStore,
        memoryCacheClearer: memoryCacheClearer
      )
      await debugTraceStore.traceResponse(
        id: traceID,
        output: output,
        metrics: completedMetrics,
        error: error.localizedDescription
      )
      _ = continuation.yield(
        .outputLimitReached(
          ChatGenerationOutputLimit(
            discardedToolProtocolTail: didDiscardToolProtocolTail
          )))
      continuation.finish()
      return
    }

    if !nativeToolCalls.isEmpty {
      if completedMetrics == nil {
        await runtimeCacheDiagnostics?.invalidate()
      }
      await markNativeToolCallBoundary(visibleOutput, nativeToolCalls)
      await debugTraceStore.traceResponse(
        id: traceID,
        output: output,
        metrics: completedMetrics
      )
      continuation.finish()
      return
    }

    if !didCompleteNaturally {
      let error = MLXChatRuntimeError.interruptedStream
      await markCancelled(.interrupted)
      await clearMemoryCache(
        reason: .interruptedStream,
        traceID: traceID,
        traceMetadata: traceMetadata,
        cacheTrace: cacheTrace,
        debugTraceStore: debugTraceStore,
        memoryCacheClearer: memoryCacheClearer
      )
      await debugTraceStore.traceResponse(
        id: traceID,
        output: output,
        metrics: completedMetrics,
        error: error.localizedDescription
      )
      continuation.finish(throwing: error)
      return
    }

    await markCompleted(visibleOutput)
    await debugTraceStore.traceResponse(
      id: traceID,
      output: output,
      metrics: completedMetrics
    )
    continuation.finish()
  }

  static func clearMemoryCache(
    reason: MLXMemoryClearReason,
    traceID: UUID?,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace?,
    debugTraceStore: MLXDebugTraceStore,
    memoryCacheClearer: MLXMemoryCacheClearer
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
      systemPromptChanged: cacheTrace?.systemPromptChanged
    )
    if let traceMetadata {
      await traceMetadata.tracer.recordTurnTraceEvent(event)
    } else {
      await debugTraceStore.recordTurnTraceEvent(event)
    }
  }

}
