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
  func tokenLimitedModelStreamFailsInsteadOfCompletingTruncatedOutput() async throws {
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

    do {
      try await drainModelStream(stream)
      Issue.record("Expected token-limit failure.")
    } catch MLXChatRuntimeError.generationTokenLimitReached {
      #expect(await invalidationRecorder.firstReason == .interrupted)
      #expect(await memoryClearRecorder.reasons == [.interruptedStream])
    } catch {
      Issue.record("Expected token-limit error, got \(error).")
    }
  }

  @Test
  func cancelledModelStreamInvalidatesInsteadOfCompleting() async throws {
    let completionRecorder = MLXStreamCompletionRecorder()
    let invalidationRecorder = MLXStreamInvalidationRecorder()
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
      traceID: UUID(),
      traceMetadata: nil,
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
      case .toolCall, .completed:
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
      case .toolCall, .completed:
        break
      }
    }

    #expect(chunks.joined() == "\n\nHello there.")
    #expect(thinkingChunks.joined() == "The user said hey.")
    #expect(await completionRecorder.firstOutput == "\n\nHello there.")
    #expect(await memoryClearRecorder.reasons.isEmpty)
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
    #expect(try await iterator.next() == nil)
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 1
    }
    #expect(await recorder.firstReason == nil)
    #expect(await boundaryRecorder.firstBoundary?.output == "")
    #expect(await memoryClearRecorder.reasons.isEmpty)
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
    markCompleted: @escaping @Sendable (String) async -> Void,
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
      markCompleted: markCompleted,
      markNativeToolCallBoundary: markNativeToolCallBoundary,
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

  private struct MLXTestStreamError: Error {}

  private struct MLXStreamWaitTimeoutError: Error {}

}
