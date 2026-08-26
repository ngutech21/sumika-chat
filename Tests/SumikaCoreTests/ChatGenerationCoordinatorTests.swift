import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ChatGenerationCoordinatorTests {
  @Test
  func interactionModeReachesRuntimeAsExplicitGenerationInput() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )

    _ = try await coordinator.streamAssistantReplyResult(
      interactionMode: .chat,
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { _ in }
    )

    #expect(await runtime.capturedInteractionModes == [.chat])
  }

  @Test
  func regularAssistantStreamingPreservesRuntimeMetrics() async throws {
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
  }

  @Test
  func completedStreamWithoutRuntimeMetricsDoesNotEstimateTokenRate() async throws {
    let coordinator = ChatGenerationCoordinator(
      runtime: MetricsOmittingRuntime(),
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var didUpdateMetrics = false
    var updatedMetrics: ChatGenerationMetrics?

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { _ in },
      updateGenerationMetrics: { metrics in
        didUpdateMetrics = true
        updatedMetrics = metrics
      })

    #expect(result.assistantContent == "hello")
    #expect(didUpdateMetrics)
    #expect(updatedMetrics == nil)
  }

  @Test
  func regularAssistantStreamingThrowsWhenRuntimeEndsWithoutCompletion() async throws {
    let runtime = InterruptedEventRuntime(events: [
      .thinkingChunk("reasoning"),
      .chunk("partial"),
    ])
    let clock = StreamingTestClock(milliseconds: [0, 10, 20])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 3600,
      streamingFlushCharacterLimit: 1_000,
      streamingNow: clock.now
    )
    var observations: [String] = []

    await #expect(throws: ChatGenerationError.streamInterrupted) {
      try await coordinator.streamAssistantReplyResult(
        transcript: ModelPromptProjection(),
        promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
        settings: .agentDefault,
        appendChunk: { observations.append("visible:\($0)") },
        appendThinkingChunk: { observations.append("thinking:\($0)") },
        updateGenerationMetrics: { _ in })
    }

    #expect(observations == ["thinking:reasoning", "visible:partial"])
    #expect(clock.readCount == 3)
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
  func outputLimitReturnsCompleteNativeCallsAndTerminationMetadata() async throws {
    let toolCall = ChatRuntimeToolCall(
      name: "write_file",
      arguments: [
        "path": .string("index.html"),
        "content": .string("<main></main>"),
      ]
    )
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [
        [
          .toolCall(toolCall),
          .outputLimitReached(
            ChatGenerationOutputLimit(
              discardedToolProtocolTail: true
            )),
        ]
      ],
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

    #expect(result.nativeToolCalls == [toolCall])
    #expect(result.termination == .outputLimit(discardedToolProtocolTail: true))
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
  func toolCallFlushesThinkingThenVisibleContentBeforeReturningBoundary() async throws {
    let toolCall = ChatRuntimeToolCall(
      name: "list_files",
      arguments: ["path": .string(".")]
    )
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [
        [
          .thinkingChunk("Inspect first."),
          .chunk("I will inspect the project."),
          .toolCall(toolCall),
        ]
      ],
      automaticallyCompletes: false
    )
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 3600,
      streamingFlushCharacterLimit: 1_000
    )
    var observations: [String] = []

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Use tools."),
      settings: .agentDefault,
      appendChunk: { observations.append("visible:\($0)") },
      appendThinkingChunk: { observations.append("thinking:\($0)") },
      updateGenerationMetrics: { _ in }
    )

    #expect(observations == ["thinking:Inspect first.", "visible:I will inspect the project."])
    #expect(result.nativeToolCalls == [toolCall])
  }

  @Test
  func outputLimitFlushesThinkingThenVisibleContentBeforeReturningBoundary() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [
        [
          .thinkingChunk("Concluding."),
          .chunk("Partial answer."),
          .outputLimitReached(ChatGenerationOutputLimit(discardedToolProtocolTail: false)),
        ]
      ],
      automaticallyCompletes: false
    )
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 3600,
      streamingFlushCharacterLimit: 1_000
    )
    var observations: [String] = []

    let result = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { observations.append("visible:\($0)") },
      appendThinkingChunk: { observations.append("thinking:\($0)") },
      updateGenerationMetrics: { _ in }
    )

    #expect(observations == ["thinking:Concluding.", "visible:Partial answer."])
    #expect(result.termination == .outputLimit(discardedToolProtocolTail: false))
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
  func explicitStreamingCadenceUsesInjectedEventTimestamps() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [[.chunk("a"), .chunk("b"), .completed(nil)]],
      automaticallyCompletes: false
    )
    let clock = StreamingTestClock(milliseconds: [0, 49, 51, 51])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0.05,
      streamingFlushCharacterLimit: 1_000,
      streamingNow: clock.now
    )
    var chunks: [String] = []

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in }
    )

    #expect(chunks == ["ab"])
    #expect(clock.readCount == 4)
  }

  @Test
  func defaultStreamingCadenceFlushesAt50Milliseconds() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [[.chunk("a"), .chunk("b"), .chunk("c"), .completed(nil)]],
      automaticallyCompletes: false
    )
    let clock = StreamingTestClock(milliseconds: [0, 49, 99, 101, 101])
    let coordinator = ChatGenerationCoordinator(
      runtimeOperations: RuntimeOperationCoordinator(runtime: runtime),
      streamingNow: clock.now
    )
    var chunks: [String] = []

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in }
    )

    #expect(chunks == ["ab", "c"])
    #expect(clock.readCount == 5)
  }

  @Test
  func candidate100MillisecondCadenceBatchesEventsUntilBoundary() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [[.chunk("a"), .chunk("b"), .chunk("c"), .completed(nil)]],
      automaticallyCompletes: false
    )
    let clock = StreamingTestClock(milliseconds: [0, 49, 99, 101, 101])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0.10,
      streamingFlushCharacterLimit: 1_000,
      streamingNow: clock.now
    )
    var chunks: [String] = []

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in }
    )

    #expect(chunks == ["abc"])
    #expect(clock.readCount == 5)
  }

  @Test
  func characterLimitFlushesBeforeCadenceWithoutCompletionDuplication() async throws {
    let content = String(repeating: "x", count: 240)
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [[.chunk(content), .completed(nil)]],
      automaticallyCompletes: false
    )
    let clock = StreamingTestClock(milliseconds: [0, 10, 10])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0.10,
      streamingFlushCharacterLimit: 240,
      streamingNow: clock.now
    )
    var chunks: [String] = []

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in }
    )

    #expect(chunks == [content])
    #expect(clock.readCount == 3)
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
  func thinkingCompletionFlushesThinkingThenVisibleContentBeforePublishingTheBoundary() async throws
  {
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [
        [
          .thinkingChunk("Reasoning"),
          .chunk("Preface. "),
          .thinkingCompleted,
          .chunk("Visible answer."),
          .completed(nil),
        ]
      ],
      automaticallyCompletes: false
    )
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 3600,
      streamingFlushCharacterLimit: 1_000
    )
    var observations: [String] = []

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { observations.append("visible:\($0)") },
      appendThinkingChunk: { observations.append("thinking:\($0)") },
      completeThinking: { observations.append("thinking-completed") },
      updateGenerationMetrics: { _ in observations.append("generation-completed") }
    )

    #expect(
      observations == [
        "thinking:Reasoning",
        "visible:Preface. ",
        "thinking-completed",
        "visible:Visible answer.",
        "generation-completed",
      ])
  }

  @Test
  func generationCompletionDoesNotConfirmUnclosedThinking() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [
        [
          .thinkingChunk("Partial reasoning"),
          .chunk("Visible answer."),
          .completed(nil),
        ]
      ],
      automaticallyCompletes: false
    )
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 3600,
      streamingFlushCharacterLimit: 1_000
    )
    var thinkingCompletionCount = 0
    var observations: [String] = []

    _ = try await coordinator.streamAssistantReplyResult(
      transcript: ModelPromptProjection(),
      promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
      settings: .agentDefault,
      appendChunk: { observations.append("visible:\($0)") },
      appendThinkingChunk: { observations.append("thinking:\($0)") },
      completeThinking: { thinkingCompletionCount += 1 },
      updateGenerationMetrics: { _ in observations.append("generation-completed") }
    )

    #expect(thinkingCompletionCount == 0)
    #expect(
      observations == [
        "thinking:Partial reasoning",
        "visible:Visible answer.",
        "generation-completed",
      ])
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
    var thinkingChunks: [String] = []

    let generationTask = Task {
      try await coordinator.streamAssistantReplyResult(
        operationID: operationID,
        transcript: ModelPromptProjection(),
        promptPlan: ChatRuntimePromptPlan(stableInstructions: "Answer normally."),
        settings: .agentDefault,
        appendChunk: { chunks.append($0) },
        appendThinkingChunk: { thinkingChunks.append($0) },
        updateGenerationMetrics: { _ in })
    }

    try await waitUntilAsync { await runtime.yieldedEventCount == 2 }
    await runtimeOperations.setCurrentOperation(UUID())
    await runtime.releaseStream()

    await #expect(throws: CancellationError.self) {
      try await generationTask.value
    }
    #expect(chunks.isEmpty)
    #expect(thinkingChunks.isEmpty)
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

private actor InterruptedEventRuntime: ChatModelRuntime {
  private let events: [ChatModelStreamEvent]

  init(events: [ChatModelStreamEvent]) {
    self.events = events
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    _ = interactionMode

    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}

@MainActor
private final class StreamingTestClock {
  private let dates: [Date]
  private var index = 0

  init(milliseconds: [Double]) {
    dates = milliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
  }

  var readCount: Int {
    index
  }

  func now() -> Date {
    precondition(index < dates.count, "Streaming test clock exhausted")
    defer { index += 1 }
    return dates[index]
  }
}

private actor MetricsOmittingRuntime: ChatModelRuntime {
  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings

    return AsyncThrowingStream { continuation in
      continuation.yield(.chunk("hello"))
      continuation.yield(.completed(nil))
      continuation.finish()
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
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.yield(.chunk("hello"))
      continuation.yield(
        .completed(
          ChatGenerationMetrics(generatedTokenCount: 1, tokensPerSecond: 100)
        )
      )
      continuation.finish()
    }
  }
}

private actor OperationLaneControlledRuntime: ChatModelRuntime {
  private var streamContinuation: CheckedContinuation<Void, Never>?
  private var didReleaseStream = false
  private(set) var yieldedEventCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings

    return AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield(.thinkingChunk("reasoning"))
        recordYieldedEvent()
        continuation.yield(.chunk("first"))
        recordYieldedEvent()
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

  private func recordYieldedEvent() {
    yieldedEventCount += 1
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
