import Foundation
import MLXLMCommon
import SumikaCore

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
      let streamInterval = ChatDiagnostics.beginInterval(
        "Gemma process model stream",
        category: .generation
      )
      defer {
        ChatDiagnostics.endInterval(streamInterval)
      }
      var output = ""
      var visibleOutput = ""
      var thoughtParser = GemmaThoughtChannelParser()
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
            if yieldSegments(
              thoughtParser.append(chunk),
              to: continuation,
              visibleOutput: &visibleOutput
            ) {
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
            if yieldSegments(
              thoughtParser.finish(),
              to: continuation,
              visibleOutput: &visibleOutput
            ) {
              didTerminateDownstream = true
              break generationLoop
            }
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

        let finalizeInterval = ChatDiagnostics.beginInterval(
          "Gemma finalize model stream",
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
          didCompleteNaturally: didCompleteNaturally,
          nativeToolCalls: nativeToolCalls,
          traceID: traceID,
          traceMetadata: traceMetadata,
          cacheTrace: cacheTrace,
          markCompleted: markCompleted,
          markNativeToolCallBoundary: markNativeToolCallBoundary,
          markCancelled: markCancelled,
          memoryCacheClearer: memoryCacheClearer
        )
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

  nonisolated private static func yieldSegments(
    _ segments: [GemmaThoughtChannelSegment],
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

  nonisolated private static func finalizeStream(
    continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    output: String,
    visibleOutput: String,
    completedMetrics: ChatGenerationMetrics?,
    didTerminateDownstream: Bool,
    didCompleteNaturally: Bool,
    nativeToolCalls: [ChatRuntimeToolCall],
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: GemmaSessionCacheTrace,
    markCompleted: @Sendable (String) async -> Void,
    markNativeToolCallBoundary: @Sendable (String, [ChatRuntimeToolCall]) async -> Void,
    markCancelled: @Sendable (GemmaSessionInvalidationReason) async -> Void,
    memoryCacheClearer: GemmaMemoryCacheClearer
  ) async {
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
      await markNativeToolCallBoundary(visibleOutput, nativeToolCalls)
    } else {
      await markCompleted(visibleOutput)
    }
    await GemmaDebugTraceStore.shared.traceResponse(
      id: traceID,
      output: output,
      metrics: completedMetrics
    )
    continuation.finish()
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

nonisolated enum GemmaThoughtChannelSegment: Equatable {
  case visible(String)
  case thinking(String)
}

nonisolated struct GemmaThoughtChannelParser {
  private static let thoughtMarkers = [
    "<|channel|>thought",
    "<|channel>thought",
  ]
  private static let closeMarker = "<channel|>"

  private var pending = ""
  private var isReadingThought = false

  mutating func append(_ chunk: String) -> [GemmaThoughtChannelSegment] {
    pending += chunk
    var segments: [GemmaThoughtChannelSegment] = []

    while !pending.isEmpty {
      if isReadingThought {
        guard let closeRange = pending.range(of: Self.closeMarker) else {
          let retained = longestSuffixMatchingPrefix(in: pending, of: Self.closeMarker)
          let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
          appendSegment(.thinking(String(pending[..<emitEnd])), to: &segments)
          pending = retained
          return segments
        }
        appendSegment(.thinking(String(pending[..<closeRange.lowerBound])), to: &segments)
        pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
        isReadingThought = false
        continue
      }

      if let thoughtRange = Self.firstMarkerRange(in: pending, markers: Self.thoughtMarkers) {
        appendSegment(.visible(String(pending[..<thoughtRange.lowerBound])), to: &segments)
        pending.removeSubrange(pending.startIndex..<thoughtRange.upperBound)
        isReadingThought = true
        continue
      }

      let retained = longestSuffixMatchingAnyPrefix(in: pending, of: Self.thoughtMarkers)
      let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
      appendSegment(.visible(String(pending[..<emitEnd])), to: &segments)
      pending = retained
      return segments
    }

    return segments
  }

  mutating func finish() -> [GemmaThoughtChannelSegment] {
    defer {
      pending = ""
      isReadingThought = false
    }
    guard !pending.isEmpty else {
      return []
    }
    return [isReadingThought ? .thinking(pending) : .visible(pending)]
  }

  private func appendSegment(
    _ segment: GemmaThoughtChannelSegment,
    to segments: inout [GemmaThoughtChannelSegment]
  ) {
    switch segment {
    case .visible(let text), .thinking(let text):
      guard !text.isEmpty else {
        return
      }
      segments.append(segment)
    }
  }

  private static func firstMarkerRange(
    in value: String,
    markers: [String]
  ) -> Range<String.Index>? {
    markers
      .compactMap { value.range(of: $0) }
      .min { lhs, rhs in
        if lhs.lowerBound == rhs.lowerBound {
          return lhs.upperBound > rhs.upperBound
        }
        return lhs.lowerBound < rhs.lowerBound
      }
  }
}

nonisolated private func longestSuffixMatchingPrefix(in value: String, of marker: String) -> String
{
  guard !value.isEmpty, !marker.isEmpty else {
    return ""
  }
  let maxLength = Swift.min(value.count, marker.count - 1)
  guard maxLength > 0 else {
    return ""
  }

  for length in stride(from: maxLength, through: 1, by: -1) {
    let suffix = String(value.suffix(length))
    if marker.hasPrefix(suffix) {
      return suffix
    }
  }
  return ""
}

nonisolated private func longestSuffixMatchingAnyPrefix(
  in value: String,
  of markers: [String]
) -> String {
  markers
    .map { longestSuffixMatchingPrefix(in: value, of: $0) }
    .max { lhs, rhs in lhs.count < rhs.count } ?? ""
}
