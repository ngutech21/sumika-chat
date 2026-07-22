import Foundation
import MLXLMCommon
import SumikaCore

@testable import SumikaRuntimeMLX

extension MLXModelStreamProcessor {
  nonisolated static func modelStream(
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
  ) -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    modelStreamPlan(
      from: stream,
      reasoningTraceFormat: reasoningTraceFormat,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cacheTrace,
      debugTraceStore: debugTraceStore,
      markCompleted: markCompleted,
      markNativeToolCallBoundary: markNativeToolCallBoundary,
      markCancelled: markCancelled,
      memoryCacheClearer: memoryCacheClearer
    ).stream
  }
}

extension MLXActiveGenerationRegistry {
  var activeGenerationID: MLXGenerationID? {
    activeGeneration?.id
  }
}
