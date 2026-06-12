import Foundation
import LocalCoderCore
import MLXLMCommon

nonisolated struct GemmaModelStreamPlan {
  let stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  let task: Task<Void, Never>
}

nonisolated enum GemmaModelStreamProcessor {
  nonisolated static func modelStream(
    from stream: AsyncThrowingStream<Generation, Error>,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markNativeToolCallBoundary: @escaping @Sendable (String, [ChatRuntimeToolCall]) async -> Void =
      {
        _, _ in
      },
    markCancelled: @escaping @Sendable (GemmaSessionInvalidationReason) async -> Void,
    memoryCacheClearer: GemmaMemoryCacheClearer = .live
  ) -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    modelStreamPlan(
      from: stream,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cacheTrace,
      markCompleted: markCompleted,
      markNativeToolCallBoundary: markNativeToolCallBoundary,
      markCancelled: markCancelled,
      memoryCacheClearer: memoryCacheClearer
    ).stream
  }

  nonisolated static func modelStreamPlan(
    from stream: AsyncThrowingStream<Generation, Error>,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markNativeToolCallBoundary: @escaping @Sendable (String, [ChatRuntimeToolCall]) async -> Void =
      {
        _, _ in
      },
    markCancelled: @escaping @Sendable (GemmaSessionInvalidationReason) async -> Void,
    memoryCacheClearer: GemmaMemoryCacheClearer = .live
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
      var nativeToolCalls: [ChatRuntimeToolCall] = []

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

          if let toolCall = generation.toolCall {
            let runtimeToolCall = GemmaNativeToolSchema.chatRuntimeToolCall(from: toolCall)
            nativeToolCalls.append(runtimeToolCall)
            if case .terminated = continuation.yield(
              .toolCall(runtimeToolCall)
            ) {
              didTerminateDownstream = true
              break generationLoop
            }
          }

          if let info = generation.info {
            let decodeStartedAt = firstChunkAt ?? iterationStartedAt
            let durationMs = Date().timeIntervalSince(decodeStartedAt) * 1000
            let metrics = ChatGenerationMetrics(
              generatedTokenCount: info.generationTokenCount,
              tokensPerSecond: info.tokensPerSecond,
              durationMs: durationMs
            )
            completedMetrics = metrics
            if let traceMetadata {
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
          if let memoryClearReason = memoryClearReason(for: .interruptedStream) {
            await clearMemoryCache(
              reason: memoryClearReason,
              traceID: traceID,
              traceMetadata: traceMetadata,
              cacheTrace: cacheTrace,
              memoryCacheClearer: memoryCacheClearer
            )
          }
          await GemmaDebugTraceStore.shared.traceResponse(
            id: traceID,
            output: output,
            metrics: completedMetrics,
            error: error.localizedDescription
          )
          continuation.finish(throwing: error)
          return
        }

        if !nativeToolCalls.isEmpty {
          await markNativeToolCallBoundary(output, nativeToolCalls)
        } else {
          await markCompleted(output)
        }
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
        if let memoryClearReason = memoryClearReason(for: .runtimeError) {
          await clearMemoryCache(
            reason: memoryClearReason,
            traceID: traceID,
            traceMetadata: traceMetadata,
            cacheTrace: cacheTrace,
            memoryCacheClearer: memoryCacheClearer
          )
        }
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

  nonisolated static func memoryClearReason(
    for termination: GemmaModelStreamTermination
  ) -> GemmaMemoryClearReason? {
    switch termination {
    case .runtimeError:
      .runtimeError
    case .interruptedStream:
      .interruptedStream
    case .completed, .downstreamTerminated, .cancelled, .nativeToolCallBoundary:
      nil
    }
  }

  nonisolated static func clearMemoryCache(
    reason: GemmaMemoryClearReason,
    traceID: UUID?,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace?,
    memoryCacheClearer: GemmaMemoryCacheClearer
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
      systemPromptChanged: cacheTrace?.systemPromptChanged,
      currentPromptContextChanged: cacheTrace?.currentPromptContextChanged
    )
    if let traceMetadata {
      await traceMetadata.tracer.recordTurnTraceEvent(event)
    } else {
      await GemmaDebugTraceStore.shared.traceTurnEvent(event)
    }
  }

}
