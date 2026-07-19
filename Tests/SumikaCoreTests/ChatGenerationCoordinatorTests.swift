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

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { metrics in
        updatedMetrics = metrics
      })

    #expect(result.assistantContent == "hello world")
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
      try await coordinator.streamAssistantReplyResult(
        transcript: ModelPromptProjection(),
        promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
        settings: .agentDefault,
        appendChunk: { chunks.append($0) },
        updateGenerationMetrics: { _ in })
    }

    #expect(chunks == ["partial"])
  }

  @Test
  func nativeToolCallWithoutCompletedEventReturnsToolCall() async throws {
    let toolCall = ChatRuntimeToolCall(
      name: "read_file",
      arguments: ["path": .string("README.md")]
    )
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [[.toolCall(toolCall)]],
      automaticallyCompletes: false
    )
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Use tools."),
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { _ in })

    #expect(result.assistantContent == "")
    #expect(result.nativeToolCalls == [toolCall])
  }

  @Test
  func completedThinkingOnlyReturnsNoVisibleAssistantContent() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.thinkingChunk("Reasoning only.")]
    ])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var visibleChunks: [String] = []
    var thinkingChunks: [String] = []

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { visibleChunks.append($0) },
      appendThinkingChunk: { thinkingChunks.append($0) },
      updateGenerationMetrics: { _ in })

    #expect(result.assistantContent == "")
    #expect(result.nativeToolCalls.isEmpty)
    #expect(visibleChunks.isEmpty)
    #expect(thinkingChunks == ["Reasoning only."])
  }

  @Test
  func visibleTextAndNativeToolCallAreBothReturned() async throws {
    let toolCall = ChatRuntimeToolCall(
      name: "list_files",
      arguments: ["path": .string(".")]
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("I will inspect the project."), .toolCall(toolCall)]
    ])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var visibleChunks: [String] = []

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Use tools."),
      settings: .agentDefault,
      appendChunk: { visibleChunks.append($0) },
      updateGenerationMetrics: { _ in })

    #expect(result.assistantContent == "I will inspect the project.")
    #expect(result.nativeToolCalls == [toolCall])
    #expect(visibleChunks == ["I will inspect the project."])
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

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in })

    #expect(chunks == ["hello", " world"])
  }

  @Test
  func thinkingChunksStreamSeparatelyFromAssistantContent() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.thinkingChunk("I should inspect this."), .chunk("Visible answer.")]
    ])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var visibleChunks: [String] = []
    var thinkingChunks: [String] = []

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { visibleChunks.append($0) },
      appendThinkingChunk: { thinkingChunks.append($0) },
      updateGenerationMetrics: { _ in }
    )

    #expect(result.assistantContent == "Visible answer.")
    #expect(visibleChunks == ["Visible answer."])
    #expect(thinkingChunks == ["I should inspect this."])
  }

  @Test
  func streamingPublishesRuntimeCacheDebugSnapshotAfterStreamStarts() async throws {
    let generationID = UUID()
    let runtimeSnapshot = RuntimeCacheDebugSnapshot(
      generationID: generationID,
      recordedAt: Date(timeIntervalSince1970: 10),
      cacheMode: "append_delta",
      cacheReason: "append_only_delta",
      reuseStrategy: "append_delta",
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

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { _ in },
      updateRuntimeCacheDebugSnapshot: { snapshot in
        publishedSnapshot = snapshot
      })

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

    _ = try await coordinator.streamAssistantReplyResult(
      turnID: turnID,
      toolLoopIteration: 2,
      transcript: ModelPromptProjection(entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "hi")
      ]),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { _ in })

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
      try await coordinator.streamAssistantReplyResult(
        operationID: operationID,
        transcript: ModelPromptProjection(),
        promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
        settings: .agentDefault,
        appendChunk: { chunks.append($0) },
        updateGenerationMetrics: { _ in })
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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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
