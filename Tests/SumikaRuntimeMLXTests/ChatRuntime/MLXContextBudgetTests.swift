import Foundation
import MLXLMCommon
import Testing

@testable import SumikaRuntimeMLX

struct MLXContextBudgetTests {
  @Test(arguments: [
    (4_096, 512, 32_768, 3_520),
    (4_096, 3_008, 32_768, 1_024),
    (4_096, 512, 512, 512),
    (4_096, 3_520, 512, 512),
    (8_192, 6_080, 32_768, 2_048),
    (16_384, 0, 32_768, 16_320),
    (16_384, 8_000, 32_768, 8_320),
    (16_384, 12_224, 32_768, 4_096),
    (16_384, 14_272, 2_048, 2_048),
    (16_384, 100, 2_048, 2_048),
    (32_768, 28_608, 32_768, 4_096),
  ])
  func allowsMeasuredPromptsAndFitsResponseMaximum(
    capacity: Int, promptTokens: Int, configuredMaximum: Int, expectedMaximum: Int
  ) throws {
    let budget = MLXContextBudget(capacity: capacity, configuredMaximum: configuredMaximum)
    #expect(try budget.measure(promptTokens: promptTokens) == expectedMaximum)
    #expect(budget.trace.promptTokens == promptTokens)
    #expect(budget.trace.effectiveResponseMaximum == expectedMaximum)
    #expect(!budget.trace.rejected)
  }

  @Test(arguments: [
    (4_096, 3_009, 32_768, 1_024),
    (4_096, 3_521, 512, 512),
    (8_192, 6_081, 32_768, 2_048),
    (16_384, 12_225, 32_768, 4_096),
    (16_384, 14_273, 2_048, 2_048),
    (16_384, 16_384, 32_768, 4_096),
    (32_768, 28_609, 32_768, 4_096),
  ])
  func rejectsWhenMinimumReplyDoesNotFit(
    capacity: Int, promptTokens: Int, configuredMaximum: Int, minimumReply: Int
  ) {
    let budget = MLXContextBudget(capacity: capacity, configuredMaximum: configuredMaximum)
    #expect(
      throws: MLXContextBudgetError.insufficientSpace(
        promptTokens: promptTokens, capacity: capacity, minimumReply: minimumReply)
    ) {
      try budget.measure(promptTokens: promptTokens)
    }
    #expect(budget.trace.rejected)
  }
}
