import Testing
@testable import local_coder

struct ChatContextUsageTests {
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
