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
  func summaryWithoutTokenLimitShowsUsedTokens() {
    let usage = ChatContextUsage(usedTokens: 42, tokenLimit: nil)

    #expect(usage.summary == "42 tokens")
  }

  @Test
  func summaryWithTokenLimitShowsUsedAndLimit() {
    let usage = ChatContextUsage(usedTokens: 42, tokenLimit: 128)

    #expect(usage.summary == "42/128 tokens")
  }

  @Test
  func estimatedSummaryUsesTildePrefix() {
    let usage = ChatContextUsage(
      usedTokens: 42,
      tokenLimit: 128,
      accuracy: .estimate,
      isStale: true
    )

    #expect(usage.summary == "~42/128 tokens")
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

  @Test
  func availableTokensUsesRemainingPositiveBudget() {
    let usage = ChatContextUsage(usedTokens: 42, tokenLimit: 128)

    #expect(usage.availableTokens == 86)
  }

  @Test
  func availableTokensIsNilWithoutLimitAndClampedAtZero() {
    #expect(ChatContextUsage(usedTokens: 42, tokenLimit: nil).availableTokens == nil)
    #expect(ChatContextUsage(usedTokens: 300, tokenLimit: 100).availableTokens == 0)
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
      ChatAttachment(
        url: URL(filePath: "/tmp/notes.txt"),
        displayName: "notes.txt",
        kind: .text,
        content: "0123456789"
      ),
      ChatAttachment(
        url: URL(filePath: "/tmp/photo.png"),
        displayName: "photo.png",
        kind: .image,
        content: "ignored image bytes"
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
