import Testing

@testable import Sumika

@Suite
struct MLXPrefixCheckpointReuseTests {
  @Test
  func exactPrefixAnalysisReturnsOnlyTheStrictSuffix() {
    let analysis = MLXCheckpointTokenPrefixAnalysis(
      checkpointTokens: [1, 2, 3],
      promptTokens: [1, 2, 3, 4, 5]
    )

    #expect(analysis.commonPrefixCount == 3)
    #expect(analysis.firstMismatchIndex == nil)
    #expect(analysis.isExactPrefix)
    #expect(analysis.isStrictExtension)
    #expect(analysis.suffixTokens == [4, 5])
  }

  @Test
  func prefixAnalysisRejectsDivergenceAndLongerCheckpoints() {
    let divergent = MLXCheckpointTokenPrefixAnalysis(
      checkpointTokens: [1, 2, 9],
      promptTokens: [1, 2, 3, 4]
    )
    let longer = MLXCheckpointTokenPrefixAnalysis(
      checkpointTokens: [1, 2, 3],
      promptTokens: [1, 2]
    )

    #expect(divergent.commonPrefixCount == 2)
    #expect(divergent.firstMismatchIndex == 2)
    #expect(!divergent.isExactPrefix)
    #expect(divergent.suffixTokens.isEmpty)
    #expect(longer.commonPrefixCount == 2)
    #expect(longer.firstMismatchIndex == 2)
    #expect(!longer.isExactPrefix)
    #expect(longer.suffixTokens.isEmpty)
  }
}
