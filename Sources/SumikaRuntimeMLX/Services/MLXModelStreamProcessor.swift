import Foundation
import MLXLMCommon
import SumikaCore

nonisolated struct MLXModelStreamPlan {
  let stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  let task: Task<Void, Never>
}

nonisolated enum MLXModelStreamProcessor {
  nonisolated static func modelStreamPlan(
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
      var didCompleteNaturally = false
      var didReachTokenLimit = false
      var didTerminateDownstream = false
      var nativeToolCalls: [ChatRuntimeToolCall] = []
      var usedNativeToolCallIDs = Set<UUID>()

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
            if yieldSegments(
              reasoningParser.append(chunk),
              to: continuation,
              visibleOutput: &visibleOutput
            ) {
              didTerminateDownstream = true
              break generationLoop
            }
          }

          if let toolCall = generation.toolCall {
            let runtimeToolCall = MLXToolMapper.chatRuntimeToolCall(
              from: toolCall,
              usedIDs: &usedNativeToolCallIDs
            )
            nativeToolCalls.append(runtimeToolCall)
            if case .terminated = continuation.yield(
              .toolCall(runtimeToolCall)
            ) {
              didTerminateDownstream = true
              break generationLoop
            }
          }

          if let info = generation.info {
            switch info.stopReason {
            case .stop:
              break
            case .length:
              didReachTokenLimit = true
            case .cancelled:
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
            let decodeStartedAt = firstChunkAt ?? iterationStartedAt
            let durationMs = Date().timeIntervalSince(decodeStartedAt) * 1000
            let metrics = ChatGenerationMetrics(
              generatedTokenCount: info.generationTokenCount,
              tokensPerSecond: info.tokensPerSecond,
              durationMs: durationMs
            )
            completedMetrics = metrics
            await recordRuntimeDecode(
              traceID: traceID,
              traceMetadata: traceMetadata,
              cacheTrace: cacheTrace,
              decodeStartedAt: decodeStartedAt,
              tokensPerSecond: info.tokensPerSecond
            )
            didCompleteNaturally = true
            if case .terminated = continuation.yield(.completed(metrics)) {
              didTerminateDownstream = true
              break generationLoop
            }
          }
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
          didCompleteNaturally: didCompleteNaturally,
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

  nonisolated private static func recordRuntimeTTFT(
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

  nonisolated private static func recordRuntimeDecode(
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    decodeStartedAt: Date,
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
        durationMs: Date().timeIntervalSince(decodeStartedAt) * 1000,
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

  nonisolated private static func yieldSegments(
    _ segments: [ReasoningTraceSegment],
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

  nonisolated static func clearMemoryCache(
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

nonisolated enum ReasoningTraceSegment: Equatable {
  case visible(String)
  case thinking(String)
}

nonisolated struct ReasoningTraceParser {
  private enum Storage {
    case none(PassThroughReasoningTraceParser)
    case gemma(GemmaThoughtChannelParser)
    case qwen(QwenThinkTagParser)
  }

  private var storage: Storage

  init(format: ReasoningTraceFormat) {
    storage =
      switch format {
      case .none:
        .none(PassThroughReasoningTraceParser())
      case .gemmaChannel:
        .gemma(GemmaThoughtChannelParser())
      case .qwenThinkTags:
        .qwen(QwenThinkTagParser())
      }
  }

  mutating func append(_ chunk: String) -> [ReasoningTraceSegment] {
    switch storage {
    case .none(var parser):
      let segments = parser.append(chunk)
      storage = .none(parser)
      return segments
    case .gemma(var parser):
      let segments = parser.append(chunk)
      storage = .gemma(parser)
      return segments
    case .qwen(var parser):
      let segments = parser.append(chunk)
      storage = .qwen(parser)
      return segments
    }
  }

  mutating func finish() -> [ReasoningTraceSegment] {
    switch storage {
    case .none(var parser):
      let segments = parser.finish()
      storage = .none(parser)
      return segments
    case .gemma(var parser):
      let segments = parser.finish()
      storage = .gemma(parser)
      return segments
    case .qwen(var parser):
      let segments = parser.finish()
      storage = .qwen(parser)
      return segments
    }
  }
}

nonisolated private struct PassThroughReasoningTraceParser {
  mutating func append(_ chunk: String) -> [ReasoningTraceSegment] {
    chunk.isEmpty ? [] : [.visible(chunk)]
  }

  mutating func finish() -> [ReasoningTraceSegment] {
    []
  }
}

nonisolated struct GemmaThoughtChannelParser {
  private static let thoughtMarkers = [
    "<|channel|>thought",
    "<|channel>thought",
  ]
  private static let closeMarker = "<channel|>"

  private var pending = ""
  private var isReadingThought = false

  mutating func append(_ chunk: String) -> [ReasoningTraceSegment] {
    pending += chunk
    var segments: [ReasoningTraceSegment] = []

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

  mutating func finish() -> [ReasoningTraceSegment] {
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
    _ segment: ReasoningTraceSegment,
    to segments: inout [ReasoningTraceSegment]
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

nonisolated struct QwenThinkTagParser {
  private static let openMarker = "<think>"
  private static let closeMarker = "</think>"

  private var pending = ""
  private var isReadingThinking = true
  private var mayStartWithOpenMarker = true

  mutating func append(_ chunk: String) -> [ReasoningTraceSegment] {
    pending += chunk
    var segments: [ReasoningTraceSegment] = []

    while !pending.isEmpty {
      if isReadingThinking {
        if mayStartWithOpenMarker {
          if pending.hasPrefix(Self.openMarker) {
            pending.removeFirst(Self.openMarker.count)
            mayStartWithOpenMarker = false
            continue
          }
          if pending.count < Self.openMarker.count, Self.openMarker.hasPrefix(pending) {
            return segments
          }
          mayStartWithOpenMarker = false
        }

        guard let closeRange = pending.range(of: Self.closeMarker) else {
          let retained = longestSuffixMatchingPrefix(in: pending, of: Self.closeMarker)
          let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
          appendSegment(.thinking(String(pending[..<emitEnd])), to: &segments)
          pending = retained
          return segments
        }

        appendSegment(.thinking(String(pending[..<closeRange.lowerBound])), to: &segments)
        pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
        isReadingThinking = false
        continue
      }

      appendSegment(.visible(pending), to: &segments)
      pending = ""
    }

    return segments
  }

  mutating func finish() -> [ReasoningTraceSegment] {
    defer {
      pending = ""
      isReadingThinking = true
      mayStartWithOpenMarker = true
    }
    guard !pending.isEmpty else {
      return []
    }
    return [isReadingThinking ? .thinking(pending) : .visible(pending)]
  }

  private func appendSegment(
    _ segment: ReasoningTraceSegment,
    to segments: inout [ReasoningTraceSegment]
  ) {
    switch segment {
    case .visible(let text), .thinking(let text):
      guard !text.isEmpty else {
        return
      }
      segments.append(segment)
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
