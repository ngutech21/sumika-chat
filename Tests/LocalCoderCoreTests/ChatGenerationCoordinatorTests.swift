import Foundation
import Testing

@testable import LocalCoderCore

@MainActor
struct ChatGenerationCoordinatorTests {
  @Test
  func toolActionStreamingStopsAfterCompleteActionAndDropsSurroundingText() async throws {
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
      streamingFlushInterval: 0,
      streamingFlushCharacterLimit: 1
    )
    var streamedContent = ""
    var didUpdateMetrics = false
    var contextUsageUpdateCount = 0

    try await coordinator.streamAssistantReply(
      messages: [],
      systemPrompt: "Use tools.",
      settings: .codingDefault,
      stopAfterCompleteToolAction: true,
      appendChunk: { streamedContent += $0 },
      updateGenerationMetrics: { metrics in
        #expect(metrics == nil)
        didUpdateMetrics = true
      },
      updateContextUsage: {
        contextUsageUpdateCount += 1
      }
    )

    #expect(streamedContent == action)
    #expect(didUpdateMetrics)
    #expect(contextUsageUpdateCount == 1)
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
    var didUpdateMetrics = false
    var contextUsageUpdateCount = 0

    try await coordinator.streamAssistantReply(
      messages: [],
      systemPrompt: "Use tools.",
      settings: .codingDefault,
      stopAfterCompleteToolAction: true,
      appendChunk: { streamedContent += $0 },
      updateGenerationMetrics: { metrics in
        #expect(metrics == ChatGenerationMetrics(generatedTokenCount: 1, tokensPerSecond: 100))
        didUpdateMetrics = true
      },
      updateContextUsage: {
        contextUsageUpdateCount += 1
      }
    )

    #expect(streamedContent == combined)
    #expect(didUpdateMetrics)
    #expect(contextUsageUpdateCount == 1)
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

    try await coordinator.streamAssistantReply(
      messages: [],
      systemPrompt: "Answer normally.",
      settings: .codingDefault,
      stopAfterCompleteToolAction: false,
      appendChunk: { chunks.append($0) },
      updateGenerationMetrics: { _ in },
      updateContextUsage: {}
    )

    #expect(chunks == ["hello", " world"])
  }
}
