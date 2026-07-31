import Foundation
import Testing

@testable import SumikaCore

struct ChatContextUsageTests {
  @Test
  func defaultInitCreatesExactFreshUsage() {
    let usage = ChatContextUsage(usedTokens: 42, tokenLimit: nil)

    #expect(usage.accuracy == .exact)
    #expect(!usage.isStale)
  }

  @Test
  func fractionIsNilWithoutPositiveLimit() {
    #expect(ChatContextUsage(usedTokens: 42, tokenLimit: nil).fraction == nil)
    #expect(ChatContextUsage(usedTokens: 42, tokenLimit: 0).fraction == nil)
  }

  @Test
  func fractionIsClampedAtOne() {
    let usage = ChatContextUsage(usedTokens: 300, tokenLimit: 100)

    #expect(usage.fraction == 1)
  }

}

struct ContextUsageSnapshotTests {
  @Test
  func estimatedUsageSumsSystemPromptAndTranscriptBytes() throws {
    let snapshot = try makeSnapshot()

    let usage = snapshot.estimatedUsage(isStale: false)

    // "system" (6 bytes) + "hello" (5 bytes) = 11 bytes -> ceil(11 / 4) = 3 tokens.
    #expect(
      usage
        == ChatContextUsage(usedTokens: 3, tokenLimit: 100, accuracy: .estimate, isStale: false))
  }

  @Test
  func estimatedUsageCountsTextAttachmentsAndIgnoresImages() throws {
    let snapshot = try makeSnapshot(attachments: [
      makeTextChatAttachment(
        displayName: "notes.txt",
        content: "0123456789"
      ),
      makeImageChatAttachment(
        displayName: "photo.png",
        byteSize: 19
      ),
    ])

    let usage = snapshot.estimatedUsage(isStale: false)

    // 11 transcript bytes + 10 text-attachment bytes; the image is excluded.
    #expect(usage.usedTokens == 6)
  }

  @Test
  func estimatedUsageDefaultsToStale() throws {
    let snapshot = try makeSnapshot()

    #expect(snapshot.estimatedUsage().isStale)
  }

  @Test
  func estimatedUsageCountsProjectedHistoricalReasoning() throws {
    let snapshot = ContextUsageSnapshot(
      modelState: .ready,
      transcript: ModelPromptProjection(entries: [
        try ModelFacingPromptRenderer.assistantOutputEntry(
          content: "answer",
          historicalReasoning: HistoricalAssistantReasoning(content: "reasoning")
        )
      ]),
      attachments: [],
      systemPrompt: "",
      contextTokenLimit: 100
    )

    let usage = snapshot.estimatedUsage(isStale: false)

    // "answer" (6 bytes) + "reasoning" (9 bytes) = 15 bytes -> 4 tokens.
    #expect(usage.usedTokens == 4)
  }

  private func makeSnapshot(attachments: [ChatAttachment] = []) throws -> ContextUsageSnapshot {
    ContextUsageSnapshot(
      modelState: .ready,
      transcript: ModelPromptProjection(entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "hello")
      ]),
      attachments: attachments,
      systemPrompt: "system",
      contextTokenLimit: 100
    )
  }
}
