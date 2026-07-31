import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif
@Suite()
struct MLXModelStreamProcessorTests {
  @Test
  func modelStreamMarksConsumerTerminationAsDownstreamTerminated() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    try await consumeFirstModelStreamEvent(recorder: recorder)

    try await waitUntilAsync {
      await recorder.firstReason != nil
    }
    #expect(await recorder.firstReason == .downstreamTerminated)
  }

  @Test
  func modelStreamPlanCancelsUpstreamTaskWhenConsumerTerminates() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      let task = Task {
        try? await Task.sleep(for: .seconds(5))
        continuation.yield(.chunk("late"))
      }
      continuation.yield(.chunk("tool"))
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    var plan: MLXModelStreamPlan? = MLXModelStreamProcessor.modelStreamPlan(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )
    let upstreamTask = try #require(plan?.task)
    var outputStream: AsyncThrowingStream<ChatModelStreamEvent, Error>? = try #require(plan?.stream)
    plan = nil

    let (firstEventStream, firstEventContinuation) = AsyncStream<Void>.makeStream()
    let consumerTask = consumeFirstEventAndWait(
      from: try #require(outputStream),
      firstEventContinuation: firstEventContinuation
    )
    outputStream = nil
    defer {
      consumerTask.cancel()
    }

    _ = try await withTestTimeout(.seconds(5)) {
      var firstEventIterator = firstEventStream.makeAsyncIterator()
      return await firstEventIterator.next()
    }
    consumerTask.cancel()
    try await withTestTimeout(.seconds(5)) {
      await consumerTask.value
    }
    try await waitUntilAsync {
      let firstReason = await recorder.firstReason
      return upstreamTask.isCancelled && firstReason == .downstreamTerminated
    }
  }

  @Test
  func completedModelStreamDoesNotClearMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("done"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    try await drainModelStream(stream)

    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func completedModelStreamUsesUpstreamCompletionTimesForTerminalTraces() async throws {
    let traceID = UUID()
    let tracer = CoreOnlyTurnTraceRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("done"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 5,
            promptTime: 0.1,
            generationTime: 0.25
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: traceID,
      traceMetadata: TurnTraceMetadata(
        turnID: nil,
        generationID: traceID,
        tracer: tracer
      ),
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    try await drainModelStream(stream)

    let prefillEvents = await tracer.events(for: .runtimePrefill)
    let prefill = try #require(prefillEvents.first)
    #expect(prefillEvents.count == 1)
    #expect(prefill.generationID == traceID)
    #expect(prefill.durationMs == 100)
    #expect(prefill.promptTokens == 8)
    #expect(prefill.cacheMode == "new_session")
    #expect(prefill.cacheReason == "no_cached_session")

    let decode = try #require(await tracer.firstEvent(for: .runtimeDecode))
    #expect(decode.durationMs == 250)
    #expect(decode.generatedTokenCount == 5)
    #expect(decode.generatedTokenCountIsEstimate == false)
    #expect(decode.tokensPerSecond == 20)
  }

  @Test
  func reusedModelStreamRecordsInternalFullPrefillDiagnostics() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: [
        "MLXLMCommon.MambaCache",
        "MLXLMCommon.KVCacheSimple",
      ],
      cacheTrimmable: false
    )
    let coldGenerationID = UUID()
    await diagnostics.begin(generationID: coldGenerationID, expectsReuse: false)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 100,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )
    _ = await diagnostics.complete(
      generationID: coldGenerationID,
      info: GenerateCompletionInfo(
        promptTokenCount: 100,
        generationTokenCount: 20,
        promptTime: 0.1,
        generationTime: 0.2
      )
    )

    let traceID = UUID()
    await diagnostics.begin(generationID: traceID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )
    let tracer = MLXStreamTurnTraceRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("done"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 140,
            generationTokenCount: 5,
            promptTime: 0.5,
            generationTime: 0.25
          )
        ))
      continuation.finish()
    }
    let cacheTrace = MLXSessionCacheTrace(
      cacheMode: .appendDelta,
      cacheReason: .appendOnlyDelta,
      contextSignature: "context",
      previousContextSignature: "previous",
      appendOnly: true,
      reusedMessageCount: 2,
      appendedMessageCount: 1,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: false
    )
    let stream = modelStream(
      from: source,
      traceID: traceID,
      traceMetadata: TurnTraceMetadata(
        turnID: nil,
        generationID: traceID,
        tracer: tracer
      ),
      cacheTrace: cacheTrace,
      debugTraceStore: temporaryDebugTraceStore(),
      runtimeCacheDiagnostics: diagnostics,
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    try await drainModelStream(stream)

    let prefill = try #require(await tracer.firstRuntimePrefillTrace())
    let cacheDiagnostics = try #require(prefill.cacheDiagnostics)
    #expect(prefill.event.promptTokens == 140)
    #expect(cacheDiagnostics.decision == .fullPrefill)
    #expect(
      cacheDiagnostics.mismatchReason == .nontrimmablePrefixOrAlignmentMismatch
    )
    #expect(cacheDiagnostics.fullPromptTokens == 140)
    #expect(cacheDiagnostics.expectedCachedTokens == 120)
    #expect(cacheDiagnostics.expectedSuffixTokens == 20)
    #expect(cacheDiagnostics.reusedPromptTokens == 0)
    #expect(cacheDiagnostics.inputMaskPresent == false)
    #expect(cacheDiagnostics.preparedMediaPresent == false)
    #expect(cacheDiagnostics.newMediaPresent == false)
    #expect(cacheDiagnostics.cacheTrimmable == false)
    #expect(
      cacheDiagnostics.cacheTypes == [
        "MLXLMCommon.MambaCache",
        "MLXLMCommon.KVCacheSimple",
      ])
  }

  @Test
  func tokenLimitedModelStreamReportsDiscardedToolProtocolTail() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let invalidationRecorder = MLXStreamInvalidationRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("<tool_call><function=write_file>partial"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 2_048,
            promptTime: 0.1,
            generationTime: 1,
            stopReason: .length
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in
        Issue.record("A token-limited response must not be marked complete.")
      },
      markCancelled: { reason in
        await invalidationRecorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var visibleOutput = ""
    var outputLimit: ChatGenerationOutputLimit?
    for try await event in stream {
      switch event {
      case .chunk(let chunk):
        visibleOutput += chunk
      case .outputLimitReached(let limit):
        outputLimit = limit
      case .completed:
        Issue.record("A token-limited response must not be marked complete.")
      case .thinkingChunk, .thinkingCompleted, .toolCall:
        break
      }
    }

    #expect(visibleOutput.isEmpty)
    #expect(outputLimit?.discardedToolProtocolTail == true)
    #expect(await invalidationRecorder.firstReason == .interrupted)
    #expect(await memoryClearRecorder.reasons == [.interruptedStream])
  }

  @Test
  func tokenLimitedNativeToolBatchKeepsCompleteCallsAndRejectsTrailingFragment() async throws {
    let invalidationRecorder = MLXStreamInvalidationRecorder()
    let boundaryRecorder = MLXNativeBoundaryRecorder()
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let firstToolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "write_file",
        arguments: ["path": "index.html", "content": "<main></main>"]
      )
    )
    let secondToolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "write_file",
        arguments: ["path": "style.css", "content": "main {}"]
      )
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("I will create the files."))
      continuation.yield(.toolCall(firstToolCall))
      continuation.yield(.toolCall(secondToolCall))
      continuation.yield(.chunk("<tool_call><function=write_file><"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 2_048,
            promptTime: 0.1,
            generationTime: 1,
            stopReason: .length
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in
        Issue.record("A token-limited response must not be marked complete.")
      },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { reason in
        await invalidationRecorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var visibleOutput = ""
    var emittedToolCallCount = 0
    var outputLimit: ChatGenerationOutputLimit?
    for try await event in stream {
      switch event {
      case .chunk(let chunk):
        visibleOutput += chunk
      case .toolCall:
        emittedToolCallCount += 1
      case .outputLimitReached(let limit):
        outputLimit = limit
      case .completed:
        Issue.record("A token-limited response must not be marked complete.")
      case .thinkingChunk, .thinkingCompleted:
        break
      }
    }

    #expect(visibleOutput == "I will create the files.")
    #expect(emittedToolCallCount == 2)
    #expect(outputLimit?.discardedToolProtocolTail == true)
    #expect(await invalidationRecorder.firstReason == .interrupted)
    #expect(await boundaryRecorder.firstBoundary == nil)
    #expect(await memoryClearRecorder.reasons == [.interruptedStream])
  }

  @Test
  func completedModelStreamPreservesProtocolLikeText() async throws {
    let completionRecorder = MLXStreamCompletionRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("<tool_"))
      continuation.yield(.chunk("call>not a native call"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 5,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { output in
        await completionRecorder.record(output)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    var visibleOutput = ""
    for try await event in stream {
      if case .chunk(let chunk) = event {
        visibleOutput += chunk
      }
    }

    #expect(visibleOutput == "<tool_call>not a native call")
    #expect(await completionRecorder.firstOutput == visibleOutput)
  }

  @Test
  func cancelledModelStreamInvalidatesInsteadOfCompleting() async throws {
    let completionRecorder = MLXStreamCompletionRecorder()
    let invalidationRecorder = MLXStreamInvalidationRecorder()
    let traceID = UUID()
    let tracer = MLXStreamTurnTraceRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1,
            stopReason: .cancelled
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: traceID,
      traceMetadata: TurnTraceMetadata(
        turnID: nil,
        generationID: traceID,
        tracer: tracer
      ),
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { output in
        await completionRecorder.record(output)
      },
      markCancelled: { reason in
        await invalidationRecorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected cancelled model stream to throw CancellationError.")
    } catch is CancellationError {
      #expect(await invalidationRecorder.firstReason == .cancelled)
      #expect(await completionRecorder.firstOutput == nil)
      let prefill = try #require(await tracer.firstEvent(for: .runtimePrefill))
      #expect(prefill.durationMs == 100)
      #expect(prefill.promptTokens == 8)
      #expect(await tracer.firstEvent(for: .runtimeDecode) == nil)
    } catch {
      Issue.record("Expected CancellationError, got \(error).")
    }
  }

  @Test
  func modelStreamSeparatesThoughtChannelChunks() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let completionRecorder = MLXStreamCompletionRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("<|channel>thought"))
      continuation.yield(.chunk(" The user said hey."))
      continuation.yield(.chunk("<channel|>Hello"))
      continuation.yield(.chunk(" there."))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      reasoningTraceFormat: .gemmaChannel,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { output in
        await completionRecorder.record(output)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var chunks: [String] = []
    var thinkingChunks: [String] = []
    var iterator = stream.makeAsyncIterator()
    while let event = try await iterator.next() {
      switch event {
      case .chunk(let chunk):
        chunks.append(chunk)
      case .thinkingChunk(let chunk):
        thinkingChunks.append(chunk)
      case .thinkingCompleted, .toolCall, .completed, .outputLimitReached:
        break
      }
    }

    #expect(chunks.joined() == "Hello there.")
    #expect(thinkingChunks.joined() == " The user said hey.")
    #expect(await completionRecorder.firstOutput == "Hello there.")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func modelStreamSeparatesQwenThinkTagChunks() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let completionRecorder = MLXStreamCompletionRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("The user said hey."))
      continuation.yield(.chunk("</th"))
      continuation.yield(.chunk("ink>\n\nHello"))
      continuation.yield(.chunk(" there."))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      reasoningTraceFormat: .qwenThinkTags,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { output in
        await completionRecorder.record(output)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var chunks: [String] = []
    var thinkingChunks: [String] = []
    var iterator = stream.makeAsyncIterator()
    while let event = try await iterator.next() {
      switch event {
      case .chunk(let chunk):
        chunks.append(chunk)
      case .thinkingChunk(let chunk):
        thinkingChunks.append(chunk)
      case .thinkingCompleted, .toolCall, .completed, .outputLimitReached:
        break
      }
    }

    #expect(chunks.joined() == "\n\nHello there.")
    #expect(thinkingChunks.joined() == "The user said hey.")
    #expect(await completionRecorder.firstOutput == "\n\nHello there.")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func completedQwenReasoningReachesCacheSnapshotAfterCompletionBoundary() async throws {
    let snapshotRecorder = MLXAssistantSnapshotRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("Inspect the request."))
      continuation.yield(.chunk("</think>"))
      continuation.yield(.chunk("Done."))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      reasoningTraceFormat: .qwenThinkTags,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCompletedSnapshot: { snapshot in
        await snapshotRecorder.record(snapshot)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    var eventOrder: [String] = []
    for try await event in stream {
      switch event {
      case .thinkingChunk(let chunk):
        eventOrder.append("thinking:\(chunk)")
      case .thinkingCompleted:
        eventOrder.append("thinking_completed")
      case .chunk(let chunk):
        eventOrder.append("visible:\(chunk)")
      case .completed:
        eventOrder.append("completed")
      case .toolCall, .outputLimitReached:
        break
      }
    }

    #expect(
      eventOrder == [
        "thinking:Inspect the request.",
        "thinking_completed",
        "visible:Done.",
        "completed",
      ])
    #expect(
      await snapshotRecorder.firstSnapshot
        == MLXCompletedAssistantSnapshot(
          visibleContent: "Done.",
          completedReasoningContent: "Inspect the request."
        ))
  }

  @Test
  func unclosedQwenReasoningInvalidatesCacheInsteadOfConfirmingSnapshot() async throws {
    let snapshotRecorder = MLXAssistantSnapshotRecorder()
    let invalidationRecorder = MLXStreamInvalidationRecorder()
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("Still reasoning"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 2,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      reasoningTraceFormat: .qwenThinkTags,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCompletedSnapshot: { snapshot in
        await snapshotRecorder.record(snapshot)
      },
      markCancelled: { reason in
        await invalidationRecorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var didEmitCompletion = false
    do {
      for try await event in stream {
        if case .completed = event {
          didEmitCompletion = true
        }
      }
      Issue.record("Expected unclosed Qwen reasoning to interrupt the stream.")
    } catch MLXChatRuntimeError.interruptedStream {
    } catch {
      Issue.record("Expected interrupted stream error, got \(error).")
    }

    #expect(!didEmitCompletion)
    #expect(await snapshotRecorder.firstSnapshot == nil)
    #expect(await invalidationRecorder.firstReason == .interrupted)
    #expect(await memoryClearRecorder.reasons == [.interruptedStream])
  }

  @Test
  func laterUnclosedGemmaReasoningSegmentInterruptsAfterEarlierCompletedSegment() async throws {
    let snapshotRecorder = MLXAssistantSnapshotRecorder()
    let invalidationRecorder = MLXStreamInvalidationRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("<|channel>thought"))
      continuation.yield(.chunk("First thought."))
      continuation.yield(.chunk("<channel|>Visible."))
      continuation.yield(.chunk("<|channel>thought"))
      continuation.yield(.chunk("Second thought."))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      reasoningTraceFormat: .gemmaChannel,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCompletedSnapshot: { snapshot in
        await snapshotRecorder.record(snapshot)
      },
      markCancelled: { reason in
        await invalidationRecorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    var didEmitCompletion = false
    do {
      for try await event in stream {
        if case .completed = event {
          didEmitCompletion = true
        }
      }
      Issue.record("Expected the later unclosed Gemma reasoning segment to interrupt.")
    } catch MLXChatRuntimeError.interruptedStream {
    } catch {
      Issue.record("Expected interrupted stream error, got \(error).")
    }

    #expect(!didEmitCompletion)
    #expect(await snapshotRecorder.firstSnapshot == nil)
    #expect(await invalidationRecorder.firstReason == .interrupted)
  }

  @Test
  func cancellationModelStreamDoesNotClearMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish(throwing: CancellationError())
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected cancellation to propagate from model stream.")
    } catch is CancellationError {
      #expect(await memoryClearRecorder.reasons.isEmpty)
    }
  }

  @Test
  func runtimeErrorModelStreamClearsMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish(throwing: MLXTestStreamError())
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected runtime error to propagate from model stream.")
    } catch is MLXTestStreamError {
      #expect(await memoryClearRecorder.reasons == [.runtimeError])
    }
  }

  @Test
  func interruptedModelStreamClearsMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected interrupted stream to throw.")
    } catch MLXChatRuntimeError.interruptedStream {
      #expect(await memoryClearRecorder.reasons == [.interruptedStream])
    } catch {
      Issue.record("Expected interrupted stream error, got \(error).")
    }
  }

  @Test
  func modelStreamCompletesNativeToolCallAsCleanBoundary() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    let boundaryRecorder = MLXNativeBoundaryRecorder()
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let toolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: ["path": "README.md"]
      )
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(toolCall))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in
        await recorder.record(.signatureMismatch)
      },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    guard case .toolCall(let runtimeToolCall) = firstEvent else {
      Issue.record("Expected native tool call to be forwarded to the chat runtime.")
      return
    }
    #expect(runtimeToolCall.name == "read_file")

    _ = try await iterator.next()
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 1
    }
    #expect(await recorder.firstReason == nil)
    #expect(await boundaryRecorder.firstBoundary?.output == "")
    #expect(await boundaryRecorder.firstBoundary?.nativeToolCalls.first?.name == "read_file")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func modelStreamCompletesNativeToolCallWithoutInfoAsCleanBoundary() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    let boundaryRecorder = MLXNativeBoundaryRecorder()
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )
    let previousGenerationID = UUID()
    await diagnostics.begin(generationID: previousGenerationID, expectsReuse: false)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 100,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )
    _ = await diagnostics.complete(
      generationID: previousGenerationID,
      info: GenerateCompletionInfo(
        promptTokenCount: 100,
        generationTokenCount: 20,
        promptTime: 0.1,
        generationTime: 0.2
      )
    )
    let traceID = UUID()
    await diagnostics.begin(generationID: traceID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )
    let toolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: ["path": "README.md"]
      )
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(toolCall))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: traceID,
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      runtimeCacheDiagnostics: diagnostics,
      markCompleted: { _ in
        await recorder.record(.signatureMismatch)
      },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    guard case .toolCall(let runtimeToolCall) = firstEvent else {
      Issue.record("Expected native tool call to be forwarded to the chat runtime.")
      return
    }
    #expect(runtimeToolCall.name == "read_file")
    #expect(try await iterator.next() == nil)
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 1
    }
    #expect(await recorder.firstReason == nil)
    #expect(await boundaryRecorder.firstBoundary?.output == "")
    #expect(await memoryClearRecorder.reasons.isEmpty)

    let nextGenerationID = UUID()
    await diagnostics.begin(generationID: nextGenerationID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 160,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )
    let nextResult = try #require(
      await diagnostics.complete(
        generationID: nextGenerationID,
        info: GenerateCompletionInfo(
          promptTokenCount: 160,
          generationTokenCount: 5,
          promptTime: 0.1,
          generationTime: 0.2
        )
      )
    )
    #expect(nextResult.decision == .unavailable)
    #expect(nextResult.mismatchReason == .missingCachedTokenLedger)
  }

  @Test
  func modelStreamNormalizesDuplicateNativeToolCallIDs() async throws {
    let boundaryRecorder = MLXNativeBoundaryRecorder()
    let duplicateID = "call_0123456789ABCDEF0123456789ABCDEF"
    let firstToolCall = MLXLMCommon.ToolCall(
      function: .init(name: "read_file", arguments: ["path": "README.md"]),
      id: duplicateID
    )
    let secondToolCall = MLXLMCommon.ToolCall(
      function: .init(name: "list_files", arguments: ["path": "."]),
      id: duplicateID
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(firstToolCall))
      continuation.yield(.toolCall(secondToolCall))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    let secondEvent = try await iterator.next()
    guard case .toolCall(let firstRuntimeToolCall) = firstEvent,
      case .toolCall(let secondRuntimeToolCall) = secondEvent
    else {
      Issue.record("Expected two native tool call events.")
      return
    }
    _ = try await iterator.next()
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 2
    }

    #expect(firstRuntimeToolCall.id == "call_0123456789abcdef0123456789abcdef")
    #expect(secondRuntimeToolCall.id != firstRuntimeToolCall.id)
    #expect(RuntimeToolCallID.uuid(from: secondRuntimeToolCall.id) != nil)
    #expect(
      await boundaryRecorder.firstBoundary?.nativeToolCalls.map(\.id)
        == [firstRuntimeToolCall.id, secondRuntimeToolCall.id])
  }

  private nonisolated func modelStream(
    from stream: AsyncThrowingStream<Generation, Error>,
    reasoningTraceFormat: ReasoningTraceFormat = .none,
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    cacheTrace: MLXSessionCacheTrace,
    debugTraceStore: MLXDebugTraceStore,
    runtimeCacheDiagnostics: MLXRuntimeCacheDiagnostics? = nil,
    markCompleted: @escaping @Sendable (String) async -> Void,
    markCompletedSnapshot: @escaping @Sendable (MLXCompletedAssistantSnapshot) async -> Void = {
      _ in
    },
    markNativeToolCallBoundary: @escaping @Sendable (String, [ChatRuntimeToolCall]) async -> Void =
      {
        _, _ in
      },
    markCancelled: @escaping @Sendable (MLXSessionInvalidationReason) async -> Void,
    memoryCacheClearer: MLXMemoryCacheClearer = .live
  ) -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    MLXModelStreamProcessor.modelStreamPlan(
      from: stream,
      reasoningTraceFormat: reasoningTraceFormat,
      traceID: traceID,
      traceMetadata: traceMetadata,
      cacheTrace: cacheTrace,
      debugTraceStore: debugTraceStore,
      runtimeCacheDiagnostics: runtimeCacheDiagnostics,
      markCompleted: { assistant in
        await markCompleted(assistant.visibleContent)
        await markCompletedSnapshot(assistant)
      },
      markNativeToolCallBoundary: { assistant, nativeToolCalls in
        await markNativeToolCallBoundary(assistant.visibleContent, nativeToolCalls)
      },
      markCancelled: markCancelled,
      memoryCacheClearer: memoryCacheClearer
    ).stream
  }

  private func consumeFirstEventAndWait(
    from stream: AsyncThrowingStream<ChatModelStreamEvent, Error>,
    firstEventContinuation: AsyncStream<Void>.Continuation
  ) -> Task<Void, Never> {
    Task {
      do {
        let firstEvent = try await withTestTimeout(.seconds(5)) {
          var iterator = stream.makeAsyncIterator()
          return try await iterator.next()
        }
        guard case .chunk("tool") = firstEvent else {
          Issue.record("Expected first model stream event to be the initial chunk.")
          firstEventContinuation.finish()
          return
        }
        firstEventContinuation.yield(())
        firstEventContinuation.finish()
        try await Task.sleep(for: .seconds(5))
      } catch {
        firstEventContinuation.finish()
      }
    }
  }

  private func consumeFirstModelStreamEvent(
    recorder: MLXStreamInvalidationRecorder
  ) async throws {
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      let task = Task {
        continuation.yield(.chunk("tool"))
        try? await Task.sleep(for: .seconds(5))
        continuation.yield(.chunk("late"))
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    let stream = modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    let firstEvent = try await withTestTimeout(.seconds(5)) {
      var iterator = stream.makeAsyncIterator()
      return try await iterator.next()
    }
    guard case .chunk("tool") = firstEvent else {
      Issue.record("Expected first model stream event to be the initial chunk.")
      return
    }
  }

  private func drainModelStream(
    _ stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  ) async throws {
    var iterator = stream.makeAsyncIterator()
    while try await iterator.next() != nil {}
  }

  private func temporaryDebugTraceStore() -> MLXDebugTraceStore {
    MLXDebugTraceStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
    )
  }

  private func defaultCacheTrace() -> MLXSessionCacheTrace {
    MLXSessionCacheTrace(
      cacheMode: .newSession,
      cacheReason: .newSessionNoCache,
      contextSignature: "context",
      previousContextSignature: nil,
      appendOnly: false,
      reusedMessageCount: 0,
      appendedMessageCount: 0,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil
    )
  }

  private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    condition: () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while await condition() == false {
      if ContinuousClock.now - start > timeout {
        throw MLXStreamWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private actor MLXStreamInvalidationRecorder {
    private var reasons: [MLXSessionInvalidationReason] = []

    var firstReason: MLXSessionInvalidationReason? {
      reasons.first
    }

    func record(_ reason: MLXSessionInvalidationReason) {
      reasons.append(reason)
    }
  }

  private actor MLXStreamCompletionRecorder {
    private var outputs: [String] = []

    var firstOutput: String? {
      outputs.first
    }

    func record(_ output: String) {
      outputs.append(output)
    }
  }

  private actor MLXAssistantSnapshotRecorder {
    private var snapshots: [MLXCompletedAssistantSnapshot] = []

    var firstSnapshot: MLXCompletedAssistantSnapshot? {
      snapshots.first
    }

    func record(_ snapshot: MLXCompletedAssistantSnapshot) {
      snapshots.append(snapshot)
    }
  }

  private actor MLXNativeBoundaryRecorder {
    private var boundaries: [(output: String, nativeToolCalls: [ChatRuntimeToolCall])] = []

    var firstBoundary: (output: String, nativeToolCalls: [ChatRuntimeToolCall])? {
      boundaries.first
    }

    func record(output: String, nativeToolCalls: [ChatRuntimeToolCall]) {
      boundaries.append((output, nativeToolCalls))
    }
  }

  private actor MLXMemoryClearRecorder {
    private var recordedReasons: [MLXMemoryClearReason] = []

    var reasons: [MLXMemoryClearReason] {
      recordedReasons
    }

    func record(_ reason: MLXMemoryClearReason) {
      recordedReasons.append(reason)
    }
  }

  private actor MLXStreamTurnTraceRecorder: MLXRuntimeTracing {
    private var events: [TurnTraceEvent] = []
    private var runtimePrefillTraces: [MLXRuntimePrefillTrace] = []

    func recordTurnTraceEvent(_ event: TurnTraceEvent) {
      events.append(event)
    }

    func recordRuntimePrefillTrace(_ trace: MLXRuntimePrefillTrace) {
      events.append(trace.event)
      runtimePrefillTraces.append(trace)
    }

    func firstRuntimePrefillTrace() -> MLXRuntimePrefillTrace? {
      runtimePrefillTraces.first
    }

    func firstEvent(for phase: TurnTracePhase) -> TurnTraceEvent? {
      events.first { $0.phase == phase }
    }

    func events(for phase: TurnTracePhase) -> [TurnTraceEvent] {
      events.filter { $0.phase == phase }
    }
  }

  private actor CoreOnlyTurnTraceRecorder: TurnTracing {
    private var events: [TurnTraceEvent] = []

    func recordTurnTraceEvent(_ event: TurnTraceEvent) {
      events.append(event)
    }

    func firstEvent(for phase: TurnTracePhase) -> TurnTraceEvent? {
      events.first { $0.phase == phase }
    }

    func events(for phase: TurnTracePhase) -> [TurnTraceEvent] {
      events.filter { $0.phase == phase }
    }
  }

  private struct MLXTestStreamError: Error {}

  private struct MLXStreamWaitTimeoutError: Error {}

}
