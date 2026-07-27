import Foundation
import MLXLMCommon
import SumikaCore

struct MLXModelStreamPlan {
  let stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  let task: Task<Void, Never>
}

enum MLXModelStreamProcessor {
  static func modelStreamPlan(
    from stream: AsyncThrowingStream<Generation, Error>,
    reasoningTraceFormat: ReasoningTraceFormat = .none,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    debugTraceStore: MLXDebugTraceStore,
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
      defer {
        ChatDiagnostics.endInterval(streamInterval)
      }
      var output = ""
      var visibleOutput = ""
      var reasoningParser = ReasoningTraceParser(format: reasoningTraceFormat)
      var completedMetrics: ChatGenerationMetrics?
      let iterationStartedAt = Date()
      var firstChunkAt: Date?
      var didReachTokenLimit = false
      var didTerminateDownstream = false
      var nativeToolCalls: [ChatRuntimeToolCall] = []
      var usedNativeToolCallIDs = Set<UUID>()
      var pendingChunk: String?

      do {
        generationLoop: for try await generation in stream {
          try Task.checkCancellation()

          if let chunk = generation.chunk {
            if firstChunkAt == nil {
              let now = Date()
              firstChunkAt = now
              await recordRuntimeTTFT(
                traceID: traceID,
                traceMetadata: traceMetadata,
                cacheTrace: cacheTrace,
                iterationStartedAt: iterationStartedAt,
                firstChunkAt: now
              )
            }
            output += chunk
            if yieldModelChunk(
              chunk,
              pendingChunk: &pendingChunk,
              reasoningParser: &reasoningParser,
              to: continuation,
              visibleOutput: &visibleOutput
            ) {
              didTerminateDownstream = true
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
              didTerminateDownstream = true
              break generationLoop
            }
          }

          if let info = generation.info {
            switch info.stopReason {
            case .stop:
              if flushPendingChunk(
                &pendingChunk,
                reasoningParser: &reasoningParser,
                to: continuation,
                visibleOutput: &visibleOutput
              ) {
                didTerminateDownstream = true
                break generationLoop
              }
            case .length:
              didReachTokenLimit = true
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
              didTerminateDownstream = true
              break generationLoop
            }
            let metrics = ChatGenerationMetrics(
              generatedTokenCount: info.generationTokenCount,
              tokensPerSecond: info.tokensPerSecond
            )
            completedMetrics = metrics
            await recordRuntimeDecode(
              traceID: traceID,
              traceMetadata: traceMetadata,
              cacheTrace: cacheTrace,
              durationMs: info.generateTime * 1000,
              tokensPerSecond: info.tokensPerSecond
            )
            if !didReachTokenLimit {
              if case .terminated = continuation.yield(.completed(metrics)) {
                didTerminateDownstream = true
                break generationLoop
              }
            }
          }
        }

        if !didTerminateDownstream,
          flushPendingChunk(
            &pendingChunk,
            reasoningParser: &reasoningParser,
            to: continuation,
            visibleOutput: &visibleOutput
          )
        {
          didTerminateDownstream = true
        }

        let finalizeInterval = ChatDiagnostics.beginInterval(
          "MLX finalize model stream",
          category: .generation
        )
        defer {
          ChatDiagnostics.endInterval(finalizeInterval)
        }
        await finalizeStream(
          continuation: continuation,
          output: output,
          visibleOutput: visibleOutput,
          completedMetrics: completedMetrics,
          didTerminateDownstream: didTerminateDownstream,
          didCompleteNaturally: completedMetrics != nil && !didReachTokenLimit,
          didReachTokenLimit: didReachTokenLimit,
          nativeToolCalls: nativeToolCalls,
          traceID: traceID,
          traceMetadata: traceMetadata,
          cacheTrace: cacheTrace,
          debugTraceStore: debugTraceStore,
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

  private static func recordRuntimeDecode(
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    durationMs: Double,
    tokensPerSecond: Double
  ) async {
    guard let traceMetadata else {
      return
    }
    await traceMetadata.tracer.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: traceMetadata.turnID,
        generationID: traceID,
        phase: .runtimeDecode,
        durationMs: durationMs,
        toolLoopIteration: traceMetadata.toolLoopIteration,
        tokensPerSecond: tokensPerSecond,
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
    nativeToolCalls: [ChatRuntimeToolCall],
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    debugTraceStore: MLXDebugTraceStore,
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
      continuation.finish(throwing: error)
      return
    }

    if !nativeToolCalls.isEmpty {
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
