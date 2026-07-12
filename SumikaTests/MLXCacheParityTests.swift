import Foundation
import MLX
import MLXLMCommon
import Testing

@Suite
struct MLXCacheParitySupportTests {
  @Test
  func exactTokenPrefixReturnsOnlyUnprocessedSuffix() {
    let analysis = MLXTokenPrefixAnalysis(prefix: [1, 2, 3], full: [1, 2, 3, 4, 5])

    #expect(analysis.commonPrefixCount == 3)
    #expect(analysis.isExactPrefix)
    #expect(analysis.suffix == [4, 5])
  }

  @Test
  func divergingTokenSequenceIsNotReusable() {
    let analysis = MLXTokenPrefixAnalysis(prefix: [1, 2, 9], full: [1, 2, 3, 4])

    #expect(analysis.commonPrefixCount == 2)
    #expect(!analysis.isExactPrefix)
    #expect(analysis.suffix.isEmpty)
  }

  @Test
  func checkpointCopyMemoryDeltaUsesSignedByteDifferences() {
    let baseline = MLXCacheParityMemorySnapshot(
      activeMemory: 1_000,
      cacheMemory: 500,
      peakMemory: 1_500
    )
    let current = MLXCacheParityMemorySnapshot(
      activeMemory: 1_600,
      cacheMemory: 350,
      peakMemory: 2_100
    )

    let delta = MLXCacheParityMemoryDelta(baseline: baseline, current: current)

    #expect(delta.activeMemoryBytes == 600)
    #expect(delta.cacheMemoryBytes == -150)
    #expect(delta.activeAndCacheMemoryBytes == 450)
    #expect(delta.peakMemoryBytes == 600)
  }

  @Test
  func fullPromptProcessorDoesNotPrimePenaltyStateWithSuffix() {
    let recorder = PromptRecordingState()
    var processor = MLXFullPromptLogitProcessor(
      base: PromptRecordingProcessor(state: recorder),
      fullPrompt: MLXArray([10, 20, 30, 40])
    )

    processor.prompt(MLXArray([30, 40]))

    #expect(recorder.promptTokens == [10, 20, 30, 40])
  }

  @Test
  func simpleKVCacheCopyIsIndependent() {
    let cache = KVCacheSimple()
    let keys = MLXArray.ones([1, 1, 2, 4], dtype: DType.float32)
    let values = keys * MLXArray(Float(2))
    _ = cache.update(keys: keys, values: values)
    eval(cache.state)

    let copy = cache.copy()
    eval(copy.state)
    let copiedKeysBeforeMutation = copy.state[0].asArray(Float.self)

    let next = MLXArray.ones([1, 1, 1, 4], dtype: DType.float32) * MLXArray(Float(3))
    _ = cache.update(keys: next, values: next)
    eval(cache.state)

    #expect(cache.offset == 3)
    #expect(copy.offset == 2)
    #expect(copy.state[0].shape == [1, 1, 2, 4])
    #expect(copy.state[0].asArray(Float.self) == copiedKeysBeforeMutation)

    let originalKeysBeforeCopyMutation = cache.state[0].asArray(Float.self)
    let copyNext = MLXArray.ones([1, 1, 1, 4], dtype: DType.float32) * MLXArray(Float(11))
    _ = copy.update(keys: copyNext, values: copyNext)
    eval(copy.state)

    #expect(cache.state[0].asArray(Float.self) == originalKeysBeforeCopyMutation)
    #expect(copy.state[0].asArray(Float.self) != copiedKeysBeforeMutation)
  }

  @Test
  func rotatingKVCacheCopyPreservesMetadataAndIsIndependent() {
    let cache = RotatingKVCache(maxSize: 4, keep: 1, step: 4)
    let keys = MLXArray.ones([1, 1, 3, 4], dtype: DType.float32)
    _ = cache.update(keys: keys, values: keys * MLXArray(Float(2)))
    eval(cache.state)

    let copy = cache.copy()
    eval(copy.state)
    let copiedMetaState = copy.metaState
    let copiedKeysBeforeMutation = copy.state[0].asArray(Float.self)

    let next = MLXArray.ones([1, 1, 1, 4], dtype: DType.float32) * MLXArray(Float(7))
    _ = cache.update(keys: next, values: next)
    eval(cache.state)

    #expect(cache.offset == 4)
    #expect(copy.offset == 3)
    #expect(copy.metaState == copiedMetaState)
    #expect(copy.state[0].asArray(Float.self) == copiedKeysBeforeMutation)

    let originalKeysBeforeCopyMutation = cache.state[0].asArray(Float.self)
    let copyNext = MLXArray.ones([1, 1, 1, 4], dtype: DType.float32) * MLXArray(Float(13))
    _ = copy.update(keys: copyNext, values: copyNext)
    eval(copy.state)

    #expect(cache.state[0].asArray(Float.self) == originalKeysBeforeCopyMutation)
    #expect(copy.state[0].asArray(Float.self) != copiedKeysBeforeMutation)
  }

  @Test
  func mambaCacheCopyPreservesSparseSlotsAndIsIndependent() throws {
    let cache = MambaCache()
    cache[0] = MLXArray([Float(1), 2, 3, 4]).reshaped(1, 4)
    cache.offset = 4
    eval(cache.state)

    let copy = cache.copy()
    eval(copy.state)
    let copiedStateBeforeMutation = copy.state[0].asArray(Float.self)

    cache[0] = MLXArray([Float(9), 8, 7, 6]).reshaped(1, 4)
    cache[1] = MLXArray([Float(5), 4]).reshaped(1, 2)
    cache.offset = 6
    eval(cache.state)

    #expect(cache.offset == 6)
    #expect(copy.offset == 4)
    #expect(copy.state.count == 1)
    #expect(copy.state[0].asArray(Float.self) == copiedStateBeforeMutation)

    let originalStateBeforeCopyMutation = cache.state.map { $0.asArray(Float.self) }
    let typedCopy = try #require(copy as? MambaCache)
    typedCopy[0] = MLXArray([Float(12), 11, 10, 9]).reshaped(1, 4)
    typedCopy[1] = MLXArray([Float(8), 7]).reshaped(1, 2)
    eval(typedCopy.state)

    #expect(cache.state.map { $0.asArray(Float.self) } == originalStateBeforeCopyMutation)
    #expect(typedCopy.state[0].asArray(Float.self) != copiedStateBeforeMutation)
  }
}

#if SUMIKA_CACHE_PARITY_TARGET
  @Suite(.serialized)
  struct MLXCacheParityIntegrationTests {
    @Test(.enabled(if: MLXCacheParityEnvironment.enabled))
    func gemmaColdAndWarmCacheParity() async throws {
      try await run(family: .gemma)
    }

    @Test(.enabled(if: MLXCacheParityEnvironment.enabled))
    func qwenColdAndWarmCacheParity() async throws {
      try await run(family: .qwen)
    }

    private func run(family: MLXCacheParityFamily) async throws {
      guard let model = MLXCacheParityEnvironment.selectedModel(for: family),
        MLXCacheParityEnvironment.isInstalled(model)
      else {
        let report = MLXCacheParityHarness.skippedReport(
          family: family,
          reason: "No configured local \(family.rawValue) model is installed."
        )
        try MLXCacheParityEnvironment.write(report)
        return
      }

      Memory.clearCache()
      Memory.peakMemory = 0
      defer {
        Memory.clearCache()
      }

      do {
        let report = try await MLXCacheParityHarness.run(family: family, model: model)
        try MLXCacheParityEnvironment.write(report)
        #expect(report.status == .passed)
        switch family {
        case .gemma:
          #expect(
            report.scenarios.map(\.name) == [
              "structured-tool-follow-up",
              "structured-tool-follow-up-beyond-sliding-window",
            ]
          )
          #expect(report.scenarios.last?.exceedsExpectedSlidingWindow == true)
          #expect((report.scenarios.last?.p1TokenCount ?? 0) > 512)
        case .qwen:
          #expect(report.scenarios.map(\.name) == ["structured-tool-follow-up"])
        }
        for scenario in report.scenarios {
          #expect(scenario.p1IsExactPrefixOfP2)
          #expect(scenario.copyIsolation.passed)
          #expect(scenario.copyIsolation.originalOffsetsUnchanged)
          #expect(scenario.copyIsolation.originalStateUnchanged)
          #expect(scenario.copyIsolation.copiedCachesMatchOriginalBeforeWarmRuns)
          #expect(
            scenario.checkpointCopyCount
              == (scenario.continuationStateProducedByP1 ? 2 : 1)
          )
          #expect(
            scenario.checkpointCopiesMemoryDelta
              == MLXCacheParityMemoryDelta(
                baseline: scenario.checkpointMemoryAfter,
                current: scenario.checkpointCopiesMemoryAfter
              )
          )
          #expect(
            scenario.perCopyActiveAndCacheMemoryBytes
              == Double(scenario.checkpointCopiesMemoryDelta.activeAndCacheMemoryBytes)
              / Double(scenario.checkpointCopyCount)
          )
          #expect(scenario.reuseRequirement != .noPassingReusePath)
          #expect(scenario.fullCold.executionKind == .fullPrompt)
          #expect(scenario.fullCold.processorPromptTokenCount == scenario.p2TokenCount)
          #expect(!scenario.fullCold.reusedContinuationState)
          #expect(scenario.cacheOnly.freshSplit.executionKind == .directSuffix)
          #expect(scenario.cacheOnly.copiedWarm.executionKind == .directSuffix)
          #expect(
            scenario.cacheOnly.freshSplit.processorPromptTokenCount
              == scenario.p2TokenCount
          )
          #expect(
            scenario.cacheOnly.copiedWarm.processorPromptTokenCount
              == scenario.p2TokenCount
          )
          #expect(!scenario.cacheOnly.freshSplit.reusedContinuationState)
          #expect(!scenario.cacheOnly.copiedWarm.reusedContinuationState)
          #expect(scenario.cacheOnly.finalCacheParity)
          #expect(scenario.cacheOnly.strictCopyParityPassed)
          #expect(
            scenario.cacheOnly.freshSplitVsCopiedWarm.rawFirstLogits.relativeTolerance
              == 0.0001
          )
          #expect(
            scenario.cacheOnly.freshSplitVsCopiedWarm.rawFirstLogits.absoluteTolerance
              == 0.00001
          )
          #expect(
            scenario.cacheOnly.fullColdVsCopiedWarm.rawFirstLogits.relativeTolerance
              == 0.001
          )
          #expect(
            scenario.cacheOnly.fullColdVsCopiedWarm.rawFirstLogits.absoluteTolerance
              == 0.001
          )
          if scenario.continuationStateProducedByP1 {
            let stateMode = try #require(scenario.cacheAndContinuationState)
            #expect(stateMode.finalCacheParity)
            #expect(stateMode.strictCopyParityPassed)
            #expect(stateMode.freshSplit.executionKind == .directSuffix)
            #expect(stateMode.copiedWarm.executionKind == .directSuffix)
            #expect(stateMode.freshSplit.reusedContinuationState)
            #expect(stateMode.copiedWarm.reusedContinuationState)
            #expect(
              stateMode.freshSplit.processorPromptTokenCount
                == scenario.p2TokenCount
            )
            #expect(
              stateMode.copiedWarm.processorPromptTokenCount
                == scenario.p2TokenCount
            )
          } else {
            #expect(scenario.cacheAndContinuationState == nil)
          }
          switch family {
          case .gemma:
            #expect(scenario.cacheOnly.reuseParityPassed)
            #expect(scenario.reuseRequirement == .cacheOnly)
          case .qwen:
            #expect(!scenario.cacheOnly.fullColdBehavioralParityPassed)
            #expect(!scenario.cacheOnly.reuseParityPassed)
            #expect(scenario.cacheAndContinuationState?.reuseParityPassed == true)
            #expect(scenario.reuseRequirement == .cacheAndContinuationState)
          }
        }
      } catch {
        try? MLXCacheParityEnvironment.write(
          MLXCacheParityHarness.failedReport(family: family, model: model, error: error))
        throw error
      }
    }
  }
#endif

private final class PromptRecordingState {
  var promptTokens: [Int] = []
}

private struct PromptRecordingProcessor: LogitProcessor {
  let state: PromptRecordingState

  mutating func prompt(_ prompt: MLXArray) {
    state.promptTokens = prompt.asArray(Int.self)
  }

  func process(logits: MLXArray) -> MLXArray {
    logits
  }

  mutating func didSample(token: MLXArray) {}
}
