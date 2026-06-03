import Testing

@testable import LocalCoderCore

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
