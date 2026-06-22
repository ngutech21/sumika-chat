import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ChatGenerationCoordinatorTests {
  @Test
  func regularAssistantStreamingAddsDurationToCompletedMetrics() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello", " world"])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var updatedMetrics: ChatGenerationMetrics?

    let assistantContent = try await coordinator.streamAssistantReply(
      transcript: ModelContextSnapshot(),
      systemPrompt: "Answer normally.",
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { metrics in
        updatedMetrics = metrics
      },
      updateContextUsage: {}
    )

    #expect(assistantContent == "hello world")
    #expect(updatedMetrics?.generatedTokenCount == 2)
    #expect(updatedMetrics?.tokensPerSecond == 100)
    #expect(try #require(updatedMetrics).durationMs > 0)
  }

  @Test
  func regularAssistantStreamingThrowsWhenRuntimeEndsWithoutCompletion() async throws {
    let runtime = InterruptedStreamingRuntime(chunks: ["partial"])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var chunks: [String] = []

    await #expect(throws: ChatGenerationError.streamInterrupted) {
      try await coordinator.streamAssistantReply(
        transcript: ModelContextSnapshot(),
        systemPrompt: "Answer normally.",
        settings: .agentDefault,
        appendChunk: { chunks.append($0) },
        updateGenerationMetrics: { _ in },
        updateContextUsage: {}
      )
    }

    #expect(chunks == ["partial"])
  }

  @Test
  func regularAssistantStreamingStillFlushesIncrementally() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello", " world"])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var chunks: [String] = []

    _ = try await coordinator.streamAssistantReply(
      transcript: ModelContextSnapshot(),
      systemPrompt: "Answer normally.",
      settings: .agentDefault,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in },
      updateContextUsage: {}
    )

    #expect(chunks == ["hello", " world"])
  }

  @Test
  func streamingPublishesRuntimeCacheDebugSnapshotAfterStreamStarts() async throws {
    let generationID = UUID()
    let runtimeSnapshot = RuntimeCacheDebugSnapshot(
      generationID: generationID,
      recordedAt: Date(timeIntervalSince1970: 10),
      cacheMode: "session_reused",
      cacheReason: "append_only_delta_reused",
      reuseStrategy: "append_history_delta",
      appendDeltaStartIndex: 2,
      contextSignature: "ctx-new",
      previousContextSignature: "ctx-old",
      appendOnly: true,
      reusedMessageCount: 2,
      appendedMessageCount: 1
    )
    let runtime = RuntimeCacheSnapshotRuntime(snapshot: runtimeSnapshot)
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var publishedSnapshot: RuntimeCacheDebugSnapshot?

    _ = try await coordinator.streamAssistantReply(
      transcript: ModelContextSnapshot(),
      systemPrompt: "Answer normally.",
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { _ in },
      updateRuntimeCacheDebugSnapshot: { snapshot in
        publishedSnapshot = snapshot
      },
      updateContextUsage: {}
    )

    #expect(publishedSnapshot == runtimeSnapshot)
  }

  @Test
  func regularAssistantStreamingTracesUIFlushWithTurnAndGenerationID() async throws {
    let turnID = UUID()
    let tracer = RecordingTurnTracer()
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello"])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      turnTracer: tracer,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )

    _ = try await coordinator.streamAssistantReply(
      turnID: turnID,
      toolLoopIteration: 2,
      transcript: ModelContextSnapshot(entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "hi")
      ]),
      systemPrompt: "Answer normally.",
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { _ in },
      updateContextUsage: {}
    )

    try await waitUntilAsync {
      await tracer.events.contains { $0.phase == .uiFlush }
    }
    let event = try #require(await tracer.events.first { $0.phase == .uiFlush })
    #expect(event.turnID == turnID)
    #expect(event.generationID != nil)
    #expect(event.messageCount == 1)
    #expect(event.toolLoopIteration == 2)
  }

  @Test
  func streamCancelsWhenRuntimeOperationBecomesStale() async throws {
    let operationID = UUID()
    let runtime = OperationLaneControlledRuntime()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: operationID
    )
    let coordinator = ChatGenerationCoordinator(
      runtimeOperations: runtimeOperations,
      streamingFlushInterval: 3600,
      streamingFlushCharacterLimit: 100
    )
    var chunks: [String] = []

    let generationTask = Task {
      try await coordinator.streamAssistantReply(
        operationID: operationID,
        transcript: ModelContextSnapshot(),
        systemPrompt: "Answer normally.",
        settings: .agentDefault,
        appendChunk: { chunks.append($0) },
        updateGenerationMetrics: { _ in },
        updateContextUsage: {}
      )
    }

    try await waitUntilAsync { await runtime.yieldedChunkCount == 1 }
    await runtimeOperations.setCurrentOperation(UUID())
    await runtime.releaseStream()

    await #expect(throws: CancellationError.self) {
      try await generationTask.value
    }
    #expect(chunks.isEmpty)
  }

  @Test
  func staleGeneratedTokenCountDoesNotCallRuntime() async throws {
    let operationID = UUID()
    let runtime = OperationLaneControlledRuntime()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: UUID()
    )

    await #expect(throws: CancellationError.self) {
      _ = try await runtimeOperations.generatedTokenCount(for: "stale", operationID: operationID)
    }

    #expect(await runtime.generatedTokenCountRequestCount == 0)
  }

  private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    _ condition: @escaping () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
      if start.duration(to: .now) > timeout {
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor RuntimeCacheSnapshotRuntime: ChatModelRuntime {
  let snapshot: RuntimeCacheDebugSnapshot

  init(snapshot: RuntimeCacheDebugSnapshot) {
    self.snapshot = snapshot
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    snapshot
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.yield(.chunk("hello"))
      continuation.yield(
        .completed(
          ChatGenerationMetrics(generatedTokenCount: 1, tokensPerSecond: 100, durationMs: 10)
        )
      )
      continuation.finish()
    }
  }
}

private actor OperationLaneControlledRuntime: ChatModelRuntime {
  private var streamContinuation: CheckedContinuation<Void, Never>?
  private var didReleaseStream = false
  private(set) var yieldedChunkCount = 0
  private(set) var generatedTokenCountRequestCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func generatedTokenCount(for text: String) async throws -> Int {
    _ = text
    generatedTokenCountRequestCount += 1
    return 1
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings

    return AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield(.chunk("first"))
        recordYieldedChunk()
        await waitForStreamRelease()
        guard !Task.isCancelled else {
          continuation.finish(throwing: CancellationError())
          return
        }
        continuation.yield(.chunk("second"))
        continuation.yield(.completed(nil))
        continuation.finish()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  func releaseStream() {
    didReleaseStream = true
    streamContinuation?.resume()
    streamContinuation = nil
  }

  private func recordYieldedChunk() {
    yieldedChunkCount += 1
  }

  private func waitForStreamRelease() async {
    await withCheckedContinuation { continuation in
      if didReleaseStream {
        continuation.resume()
      } else {
        streamContinuation = continuation
      }
    }
  }
}

private actor RecordingTurnTracer: TurnTracing {
  private(set) var events: [TurnTraceEvent] = []

  func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    events.append(event)
  }
}
