import Foundation
import MLXLMCommon
import SumikaCore

struct MLXModelStreamPlan {
  let stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  let task: Task<Void, Never>
}

struct MLXCompletedAssistantSnapshot: Equatable, Sendable {
  let visibleContent: String
  let completedReasoningContent: String?
}

enum MLXModelStreamProcessor {
  private enum ReasoningBoundaryState {
    case absent
    case open
    case closed

    var isOpen: Bool {
      if case .open = self {
        return true
      }
      return false
    }

    var isClosed: Bool {
      if case .closed = self {
        return true
      }
      return false
    }
  }

  private struct StreamTerminationState {
    var reachedTokenLimit = false
    var discardedToolProtocolTail = false
    var terminatedDownstream = false
  }

  // This function owns the single streaming lifecycle; splitting it would duplicate
  // cancellation, cache invalidation, and terminal trace coordination.
  // swiftlint:disable:next function_body_length
  static func modelStreamPlan(
    from stream: AsyncThrowingStream<Generation, Error>,
    reasoningTraceFormat: ReasoningTraceFormat = .none,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    debugTraceStore: MLXDebugTraceStore,
    runtimeCacheDiagnostics: MLXRuntimeCacheDiagnostics? = nil,
    generationProgressTracer: MLXGenerationProgressTracer = .disabled,
    thinkingBudgetTrace: MLXThinkingBudgetTrace? = nil,
    thinkingBudgetEnforcementState: MLXThinkingBudgetEnforcementState? = nil,
    markCompleted: @escaping @Sendable (MLXCompletedAssistantSnapshot) async -> Void,
    markNativeToolCallBoundary:
      @escaping @Sendable (
        MLXCompletedAssistantSnapshot, [ChatRuntimeToolCall]
      ) async -> Void =
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
      var reasoningOutput = ""
      var reasoningBoundaryState = ReasoningBoundaryState.absent
      var reasoningParser = ReasoningTraceParser(format: reasoningTraceFormat)
      var completedMetrics: ChatGenerationMetrics?
      let iterationStartedAt = Date()
      var firstChunkAt: Date?
      var termination = StreamTerminationState()
      var nativeToolCalls: [ChatRuntimeToolCall] = []
      var usedNativeToolCallIDs = Set<UUID>()
      var pendingChunk: String?
      var generationProgressTracer = generationProgressTracer
      var thinkingBudgetGuard = thinkingBudgetEnforcementState.map { state in
        MLXQwenThinkingBudgetGuard(responseStopStrings: state.responseStopStrings)
      }

      do {
        generationLoop: for try await generation in stream {
          try Task.checkCancellation()
          try thinkingBudgetEnforcementState?.checkAuthoritative()

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
            let safeChunk = try thinkingBudgetGuard?.consume(chunk) ?? chunk
            guard !safeChunk.isEmpty else {
              continue
            }
            if yieldModelChunk(
              safeChunk,
              pendingChunk: &pendingChunk,
              reasoningParser: &reasoningParser,
              to: continuation,
              visibleOutput: &visibleOutput,
              reasoningOutput: &reasoningOutput,
              reasoningBoundaryState: &reasoningBoundaryState
            ) {
              termination.terminatedDownstream = true
              break generationLoop
            }
          }

          if let toolCall = generation.toolCall {
            thinkingBudgetGuard?.observeToolCall()
            let terminatedAtToolCallBoundary =
              closeReasoningAtNativeToolCallBoundary(
                pendingChunk: &pendingChunk,
                reasoningParser: &reasoningParser,
                to: continuation,
                visibleOutput: &visibleOutput,
                reasoningOutput: &reasoningOutput,
                reasoningBoundaryState: &reasoningBoundaryState
              )
              || yieldToolCall(
                toolCall,
                usedIDs: &usedNativeToolCallIDs,
                nativeToolCalls: &nativeToolCalls,
                to: continuation
              )
            if terminatedAtToolCallBoundary {
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
              let finalGuardChunk = try thinkingBudgetGuard?.finish() ?? ""
              if !finalGuardChunk.isEmpty,
                yieldModelChunk(
                  finalGuardChunk,
                  pendingChunk: &pendingChunk,
                  reasoningParser: &reasoningParser,
                  to: continuation,
                  visibleOutput: &visibleOutput,
                  reasoningOutput: &reasoningOutput,
                  reasoningBoundaryState: &reasoningBoundaryState
                )
              {
                termination.terminatedDownstream = true
                break generationLoop
              }
              if flushPendingChunk(
                &pendingChunk,
                reasoningParser: &reasoningParser,
                to: continuation,
                visibleOutput: &visibleOutput,
                reasoningOutput: &reasoningOutput,
                reasoningBoundaryState: &reasoningBoundaryState
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
              visibleOutput: &visibleOutput,
              reasoningOutput: &reasoningOutput,
              reasoningBoundaryState: &reasoningBoundaryState
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
          }
        }

        try thinkingBudgetEnforcementState?.checkAuthoritative()

        let finalGuardChunk =
          if termination.reachedTokenLimit {
            ""
          } else {
            try thinkingBudgetGuard?.finish() ?? ""
          }
        if !termination.terminatedDownstream, !finalGuardChunk.isEmpty,
          yieldModelChunk(
            finalGuardChunk,
            pendingChunk: &pendingChunk,
            reasoningParser: &reasoningParser,
            to: continuation,
            visibleOutput: &visibleOutput,
            reasoningOutput: &reasoningOutput,
            reasoningBoundaryState: &reasoningBoundaryState
          )
        {
          termination.terminatedDownstream = true
        }

        if !termination.terminatedDownstream,
          flushPendingChunk(
            &pendingChunk,
            reasoningParser: &reasoningParser,
            to: continuation,
            visibleOutput: &visibleOutput,
            reasoningOutput: &reasoningOutput,
            reasoningBoundaryState: &reasoningBoundaryState
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
          assistantSnapshot: completedAssistantSnapshot(
            visibleOutput: visibleOutput,
            reasoningOutput: reasoningOutput,
            reasoningBoundaryState: reasoningBoundaryState
          ),
          hasUnconfirmedReasoning: reasoningBoundaryState.isOpen,
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
          thinkingBudgetTrace: thinkingBudgetTrace,
          thinkingBudgetEnforcementState: thinkingBudgetEnforcementState,
          markCompleted: markCompleted,
          markNativeToolCallBoundary: markNativeToolCallBoundary,
          markCancelled: markCancelled,
          memoryCacheClearer: memoryCacheClearer
        )
      } catch is CancellationError {
        await handleCancellation(
          output: output,
          completedMetrics: completedMetrics,
          continuation: continuation,
          traceID: traceID,
          debugTraceStore: debugTraceStore,
          thinkingBudgetTrace: thinkingBudgetTrace,
          thinkingBudgetEnforcementState: thinkingBudgetEnforcementState,
          markCancelled: markCancelled
        )
      } catch {
        await handleRuntimeFailure(
          error,
          output: output,
          completedMetrics: completedMetrics,
          continuation: continuation,
          traceID: traceID,
          traceMetadata: traceMetadata,
          cacheTrace: cacheTrace,
          debugTraceStore: debugTraceStore,
          thinkingBudgetTrace: thinkingBudgetTrace,
          thinkingBudgetEnforcementState: thinkingBudgetEnforcementState,
          markCancelled: markCancelled,
          memoryCacheClearer: memoryCacheClearer
        )
      }
    }

    observeDownstreamCancellation(
      of: continuation,
      task: task,
      markCancelled: markCancelled
    )

    return MLXModelStreamPlan(stream: outputStream, task: task)
  }
}

extension MLXModelStreamProcessor {
  private static func handleCancellation(
    output: String,
    completedMetrics: ChatGenerationMetrics?,
    continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    traceID: UUID,
    debugTraceStore: MLXDebugTraceStore,
    thinkingBudgetTrace: MLXThinkingBudgetTrace?,
    thinkingBudgetEnforcementState: MLXThinkingBudgetEnforcementState?,
    markCancelled: @Sendable (MLXSessionInvalidationReason) async -> Void
  ) async {
    await markCancelled(.cancelled)
    await debugTraceStore.traceResponse(
      id: traceID,
      output: output,
      metrics: completedMetrics,
      error: CancellationError().localizedDescription,
      thinkingBudget: thinkingBudgetTrace,
      thinkingBudgetOutcome: thinkingBudgetEnforcementState == nil
        ? "not_applied" : "cancelled"
    )
    continuation.finish(throwing: CancellationError())
  }

  private static func observeDownstreamCancellation(
    of continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    task: Task<Void, Never>,
    markCancelled: @escaping @Sendable (MLXSessionInvalidationReason) async -> Void
  ) {
    continuation.onTermination = { termination in
      guard case .cancelled = termination else {
        return
      }
      Task {
        await markCancelled(.downstreamTerminated)
        task.cancel()
      }
    }
  }

  private static func handleRuntimeFailure(
    _ error: Error,
    output: String,
    completedMetrics: ChatGenerationMetrics?,
    continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    debugTraceStore: MLXDebugTraceStore,
    thinkingBudgetTrace: MLXThinkingBudgetTrace?,
    thinkingBudgetEnforcementState: MLXThinkingBudgetEnforcementState?,
    markCancelled: @Sendable (MLXSessionInvalidationReason) async -> Void,
    memoryCacheClearer: MLXMemoryCacheClearer
  ) async {
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
      error: error.localizedDescription,
      thinkingBudget: thinkingBudgetTrace,
      thinkingBudgetOutcome: thinkingBudgetEnforcementState == nil
        ? "not_applied" : "failed_closed",
      thinkingBudgetDiagnostic: (error as? MLXThinkingBudgetFailure)?.diagnosticCode
        ?? thinkingBudgetEnforcementState?.failure?.diagnosticCode
    )
    continuation.finish(throwing: error)
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
    visibleOutput: inout String,
    reasoningOutput: inout String,
    reasoningBoundaryState: inout ReasoningBoundaryState
  ) -> Bool {
    for segment in segments {
      switch segment {
      case .visible(let visibleChunk):
        visibleOutput += visibleChunk
        if case .terminated = continuation.yield(.chunk(visibleChunk)) {
          return true
        }
      case .thinking(let thinkingChunk):
        reasoningOutput += thinkingChunk
        reasoningBoundaryState = .open
        if case .terminated = continuation.yield(.thinkingChunk(thinkingChunk)) {
          return true
        }
      case .thinkingCompleted:
        reasoningBoundaryState = .closed
        if case .terminated = continuation.yield(.thinkingCompleted) {
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
    visibleOutput: inout String,
    reasoningOutput: inout String,
    reasoningBoundaryState: inout ReasoningBoundaryState
  ) -> Bool {
    if isPotentialToolProtocolResidual(chunk) {
      pendingChunk = (pendingChunk ?? "") + chunk
      return false
    }
    if flushPendingChunk(
      &pendingChunk,
      reasoningParser: &reasoningParser,
      to: continuation,
      visibleOutput: &visibleOutput,
      reasoningOutput: &reasoningOutput,
      reasoningBoundaryState: &reasoningBoundaryState
    ) {
      return true
    }
    return yieldSegments(
      reasoningParser.append(chunk),
      to: continuation,
      visibleOutput: &visibleOutput,
      reasoningOutput: &reasoningOutput,
      reasoningBoundaryState: &reasoningBoundaryState
    )
  }

  private static func flushPendingChunk(
    _ pendingChunk: inout String?,
    reasoningParser: inout ReasoningTraceParser,
    to continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    visibleOutput: inout String,
    reasoningOutput: inout String,
    reasoningBoundaryState: inout ReasoningBoundaryState
  ) -> Bool {
    guard let chunk = pendingChunk else {
      return false
    }
    pendingChunk = nil
    return yieldSegments(
      reasoningParser.append(chunk),
      to: continuation,
      visibleOutput: &visibleOutput,
      reasoningOutput: &reasoningOutput,
      reasoningBoundaryState: &reasoningBoundaryState
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

  private static func closeReasoningAtNativeToolCallBoundary(
    pendingChunk: inout String?,
    reasoningParser: inout ReasoningTraceParser,
    to continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation,
    visibleOutput: inout String,
    reasoningOutput: inout String,
    reasoningBoundaryState: inout ReasoningBoundaryState
  ) -> Bool {
    if flushPendingChunk(
      &pendingChunk,
      reasoningParser: &reasoningParser,
      to: continuation,
      visibleOutput: &visibleOutput,
      reasoningOutput: &reasoningOutput,
      reasoningBoundaryState: &reasoningBoundaryState
    ) {
      return true
    }
    guard !reasoningBoundaryState.isClosed else {
      return false
    }
    if yieldSegments(
      reasoningParser.finish(),
      to: continuation,
      visibleOutput: &visibleOutput,
      reasoningOutput: &reasoningOutput,
      reasoningBoundaryState: &reasoningBoundaryState
    ) {
      return true
    }
    guard reasoningBoundaryState.isOpen else {
      return false
    }
    reasoningBoundaryState = .closed
    if case .terminated = continuation.yield(.thinkingCompleted) {
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
    assistantSnapshot: MLXCompletedAssistantSnapshot,
    hasUnconfirmedReasoning: Bool,
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
    thinkingBudgetTrace: MLXThinkingBudgetTrace?,
    thinkingBudgetEnforcementState: MLXThinkingBudgetEnforcementState?,
    markCompleted: @Sendable (MLXCompletedAssistantSnapshot) async -> Void,
    markNativeToolCallBoundary:
      @Sendable (
        MLXCompletedAssistantSnapshot, [ChatRuntimeToolCall]
      ) async -> Void,
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
        error: error.localizedDescription,
        thinkingBudget: thinkingBudgetTrace,
        thinkingBudgetOutcome: thinkingBudgetEnforcementState == nil
          ? "not_applied" : "output_limit"
      )
      _ = continuation.yield(
        .outputLimitReached(
          ChatGenerationOutputLimit(
            discardedToolProtocolTail: didDiscardToolProtocolTail
          )))
      continuation.finish()
      return
    }

    let isInterrupted =
      hasUnconfirmedReasoning || (!didCompleteNaturally && nativeToolCalls.isEmpty)
    if isInterrupted {
      let error = MLXChatRuntimeError.interruptedStream
      await runtimeCacheDiagnostics?.invalidate()
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
        error: error.localizedDescription,
        thinkingBudget: thinkingBudgetTrace,
        thinkingBudgetOutcome: thinkingBudgetEnforcementState == nil
          ? "not_applied" : "interrupted"
      )
      continuation.finish(throwing: error)
      return
    }

    if !nativeToolCalls.isEmpty {
      if completedMetrics == nil {
        await runtimeCacheDiagnostics?.invalidate()
      }
      if yieldCompletion(completedMetrics, to: continuation) {
        await markCancelled(.downstreamTerminated)
        continuation.finish()
        return
      }
      await markNativeToolCallBoundary(assistantSnapshot, nativeToolCalls)
      await debugTraceStore.traceResponse(
        id: traceID,
        output: output,
        metrics: completedMetrics,
        thinkingBudget: thinkingBudgetTrace,
        thinkingBudgetOutcome: thinkingBudgetEnforcementState == nil
          ? "not_applied" : "completed_authoritative"
      )
      continuation.finish()
      return
    }

    if yieldCompletion(completedMetrics, to: continuation) {
      await markCancelled(.downstreamTerminated)
      continuation.finish()
      return
    }

    await markCompleted(assistantSnapshot)
    await debugTraceStore.traceResponse(
      id: traceID,
      output: output,
      metrics: completedMetrics,
      thinkingBudget: thinkingBudgetTrace,
      thinkingBudgetOutcome: thinkingBudgetEnforcementState == nil
        ? "not_applied" : "completed_authoritative"
    )
    continuation.finish()
  }

  private static func completedAssistantSnapshot(
    visibleOutput: String,
    reasoningOutput: String,
    reasoningBoundaryState: ReasoningBoundaryState
  ) -> MLXCompletedAssistantSnapshot {
    let completedReasoningContent: String? =
      if reasoningBoundaryState.isClosed,
        !reasoningOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        reasoningOutput
      } else {
        nil
      }
    return MLXCompletedAssistantSnapshot(
      visibleContent: visibleOutput,
      completedReasoningContent: completedReasoningContent
    )
  }

  private static func yieldCompletion(
    _ metrics: ChatGenerationMetrics?,
    to continuation: AsyncThrowingStream<ChatModelStreamEvent, Error>.Continuation
  ) -> Bool {
    guard let metrics else {
      return false
    }
    if case .terminated = continuation.yield(.completed(metrics)) {
      return true
    }
    return false
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
