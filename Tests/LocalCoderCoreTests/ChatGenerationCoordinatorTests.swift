import Foundation
import Testing

@testable import LocalCoderCore

@Suite(.serialized)
@MainActor
struct ChatGenerationCoordinatorTests {
  @Test
  func toolActionStreamingStopsAfterCompleteActionAndDropsSurroundingText() async throws {
    let turnID = UUID()
    let tracer = RecordingTurnTracer()
    let action = """
      <action name="read_file">
      <path>README.md</path>
      </action>
      """
    let runtime = ChatSessionFakeChatModelRuntime(
      chunks: [
        "I will inspect the file first.\n",
        action,
        "\nNow I will read it.",
      ]
    )
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      turnTracer: tracer,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var streamedContent = ""
    var updatedMetrics: ChatGenerationMetrics?
    var contextUsageUpdateCount = 0

    let assistantContent = try await coordinator.streamAssistantReply(
      turnID: turnID,
      transcript: ModelContextSnapshot(),
      systemPrompt: "Use tools.",
      settings: .codingDefault,
      stopAfterCompleteToolAction: true,
      appendChunk: { streamedContent += $0 },
      updateGenerationMetrics: { metrics in
        updatedMetrics = metrics
      },
      updateContextUsage: {
        contextUsageUpdateCount += 1
      }
    )

    #expect(streamedContent == action)
    #expect(assistantContent == action)
    #expect(await runtime.completedPartialReplies == [action])
    #expect(updatedMetrics?.generatedTokenCount == 4)
    #expect(try #require(updatedMetrics).durationMs > 0)
    #expect(contextUsageUpdateCount == 1)
    let event = try #require(await tracer.events.first { $0.phase == .runtimePartialDecode })
    #expect(event.turnID == turnID)
    #expect(event.generationID != nil)
  }

  @Test
  func toolActionStreamingDoesNotSilentlyDropSecondActionInSameChunk() async throws {
    let firstAction = """
      <action name="read_file">
      <path>README.md</path>
      </action>
      """
    let secondAction = """
      <action name="list_files">
      <path>.</path>
      </action>
      """
    let combined = firstAction + "\n" + secondAction
    let runtime = ChatSessionFakeChatModelRuntime(chunks: [combined])
    let coordinator = ChatGenerationCoordinator(
      runtime: runtime,
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var streamedContent = ""
    var updatedMetrics: ChatGenerationMetrics?
    var contextUsageUpdateCount = 0

    let assistantContent = try await coordinator.streamAssistantReply(
      transcript: ModelContextSnapshot(),
      systemPrompt: "Use tools.",
      settings: .codingDefault,
      stopAfterCompleteToolAction: true,
      appendChunk: { streamedContent += $0 },
      updateGenerationMetrics: { metrics in
        updatedMetrics = metrics
      },
      updateContextUsage: {
        contextUsageUpdateCount += 1
      }
    )

    #expect(streamedContent == combined)
    #expect(assistantContent == combined)
    #expect(updatedMetrics?.generatedTokenCount == 1)
    #expect(updatedMetrics?.tokensPerSecond == 100)
    #expect(try #require(updatedMetrics).durationMs > 0)
    #expect(contextUsageUpdateCount == 1)
  }

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
      settings: .codingDefault,
      stopAfterCompleteToolAction: false,
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
        settings: .codingDefault,
        stopAfterCompleteToolAction: false,
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
      settings: .codingDefault,
      stopAfterCompleteToolAction: false,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in },
      updateContextUsage: {}
    )

    #expect(chunks == ["hello", " world"])
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
      settings: .codingDefault,
      stopAfterCompleteToolAction: false,
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

private actor RecordingTurnTracer: TurnTracing {
  private(set) var events: [TurnTraceEvent] = []

  func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    events.append(event)
  }
}
