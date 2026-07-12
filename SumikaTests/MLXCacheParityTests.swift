import Foundation
import MLX
import MLXLMCommon
import SumikaCore
import Testing

@testable import Sumika

@Suite
struct MLXCacheParitySupportTests {
  @Test
  func exactTokenPrefixReturnsOnlyUnprocessedSuffix() {
    let analysis = MLXCheckpointTokenPrefixAnalysis(
      checkpointTokens: [1, 2, 3],
      promptTokens: [1, 2, 3, 4, 5]
    )

    #expect(analysis.commonPrefixCount == 3)
    #expect(analysis.isExactPrefix)
    #expect(analysis.suffixTokens == [4, 5])
  }

  @Test
  func divergingTokenSequenceIsNotReusable() {
    let analysis = MLXCheckpointTokenPrefixAnalysis(
      checkpointTokens: [1, 2, 9],
      promptTokens: [1, 2, 3, 4]
    )

    #expect(analysis.commonPrefixCount == 2)
    #expect(!analysis.isExactPrefix)
    #expect(analysis.suffixTokens.isEmpty)
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
  func checkpointedDecodeMemoryReportEncodesSignedWithCopyDeltas() throws {
    let baseline = MLXCheckpointDecodeMemoryPath(
      retainsCheckpointCopy: false,
      generatedTokenCount: 16,
      memoryBeforePrefill: memorySnapshot(active: 1_000, cache: 500, peak: 0),
      memoryAfterPrefill: memorySnapshot(active: 1_200, cache: 550, peak: 1_300),
      memoryAfterCheckpointCopy: memorySnapshot(active: 1_200, cache: 550, peak: 1_300),
      memoryAfterDecode: memorySnapshot(active: 1_400, cache: 600, peak: 1_700)
    )
    let withHeldCheckpointCopy = MLXCheckpointDecodeMemoryPath(
      retainsCheckpointCopy: true,
      generatedTokenCount: 16,
      memoryBeforePrefill: memorySnapshot(active: 990, cache: 510, peak: 0),
      memoryAfterPrefill: memorySnapshot(active: 1_210, cache: 540, peak: 1_310),
      memoryAfterCheckpointCopy: memorySnapshot(active: 1_250, cache: 525, peak: 1_350),
      memoryAfterDecode: memorySnapshot(active: 1_850, cache: 500, peak: 2_250)
    )

    let report = MLXCheckpointDecodeMemoryReport(
      expectedGeneratedTokenCount: 16,
      warmupGeneratedTokenCount: 16,
      baseline: baseline,
      withHeldCheckpointCopy: withHeldCheckpointCopy
    )

    #expect(report.passed)
    #expect(report.expectedGeneratedTokenCount == 16)
    #expect(report.warmupGeneratedTokenCount == 16)
    #expect(!report.baseline.retainsCheckpointCopy)
    #expect(report.withHeldCheckpointCopy.retainsCheckpointCopy)
    #expect(report.baseline.generatedTokenCount == 16)
    #expect(report.withHeldCheckpointCopy.generatedTokenCount == 16)
    #expect(report.startingMemoryDifference.activeMemoryBytes == -10)
    #expect(report.withCopyMinusBaselineGrowth.afterPrefill.cacheMemoryBytes == -20)
    #expect(
      report.withCopyMinusBaselineGrowth.afterCheckpointCopy.activeAndCacheMemoryBytes == 25)
    #expect(report.withCopyMinusBaselineGrowth.afterDecode.activeMemoryBytes == 460)
    #expect(report.withCopyMinusBaselineGrowth.afterDecode.cacheMemoryBytes == -110)
    #expect(report.withCopyMinusBaselineGrowth.afterDecode.activeAndCacheMemoryBytes == 350)
    #expect(report.withCopyMinusBaselineGrowth.afterDecode.peakMemoryBytes == 550)

    let encoded = try JSONEncoder().encode(report)
    let json = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(json["baseline"] != nil)
    #expect(json["withHeldCheckpointCopy"] != nil)
    #expect(json["startingMemoryDifference"] != nil)
    #expect(json["baselineGrowth"] != nil)
    #expect(json["withHeldCheckpointCopyGrowth"] != nil)
    #expect(json["withCopyMinusBaselineGrowth"] != nil)
  }

  @Test
  func checkpointedDecodeMemoryIntegrityParticipatesInPassStatus() {
    let snapshot = memorySnapshot(active: 1_000, cache: 500, peak: 1_500)
    let baseline = MLXCheckpointDecodeMemoryPath(
      retainsCheckpointCopy: false,
      generatedTokenCount: 16,
      memoryBeforePrefill: snapshot,
      memoryAfterPrefill: snapshot,
      memoryAfterCheckpointCopy: snapshot,
      memoryAfterDecode: snapshot
    )
    let incompleteHeldCopy = MLXCheckpointDecodeMemoryPath(
      retainsCheckpointCopy: true,
      generatedTokenCount: 15,
      memoryBeforePrefill: snapshot,
      memoryAfterPrefill: snapshot,
      memoryAfterCheckpointCopy: snapshot,
      memoryAfterDecode: snapshot
    )

    let report = MLXCheckpointDecodeMemoryReport(
      expectedGeneratedTokenCount: 16,
      warmupGeneratedTokenCount: 16,
      baseline: baseline,
      withHeldCheckpointCopy: incompleteHeldCopy
    )

    #expect(!report.passed)
  }

  @Test
  func cacheParityReportSchemaIncludesCheckpointedDecodeMemory() {
    let report = MLXCacheParityHarness.skippedReport(
      family: .gemma,
      reason: "model-free schema assertion"
    )

    #expect(report.schemaVersion == 9)
    #expect(!report.provenance.generatedAt.isEmpty)
    #expect(report.provenance.gitCommit?.count == 40)
    #expect(report.provenance.sourceDirty != nil)
    #expect(report.provenance.packageResolvedSHA256?.count == 64)
    #expect(report.provenance.mlxSwiftRevision?.count == 40)
    #expect(report.provenance.mlxSwiftLMRevision?.count == 40)
  }

  @Test
  func fullPromptProcessorDoesNotPrimePenaltyStateWithSuffix() {
    let recorder = PromptRecordingState()
    var processor = MLXPrefixFullPromptLogitProcessor(
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

  private func memorySnapshot(
    active: Int,
    cache: Int,
    peak: Int
  ) -> MLXCacheParityMemorySnapshot {
    MLXCacheParityMemorySnapshot(
      activeMemory: active,
      cacheMemory: cache,
      peakMemory: peak
    )
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
    func gemmaE4BColdAndWarmCacheParity() async throws {
      try await run(
        family: .gemma,
        modelID: "gemma4-e4b-qat-4bit",
        reportFileStem: "gemma-e4b"
      )
    }

    @Test(.enabled(if: MLXCacheParityEnvironment.enabled))
    func gemma12BColdAndWarmCacheParity() async throws {
      try await run(
        family: .gemma,
        modelID: "gemma4-12b-qat-4bit",
        reportFileStem: "gemma-12b",
        requiresImageInput: true
      )
    }

    @Test(.enabled(if: MLXCacheParityEnvironment.enabled))
    func qwenColdAndWarmCacheParity() async throws {
      try await run(family: .qwen)
    }

    private func run(
      family: MLXCacheParityFamily,
      modelID: String? = nil,
      reportFileStem: String? = nil,
      requiresImageInput: Bool = false
    ) async throws {
      let selectedModel: ManagedModel?
      if let modelID {
        selectedModel = ManagedModelCatalog.model(id: modelID)
      } else {
        selectedModel = MLXCacheParityEnvironment.selectedModel(for: family)
      }
      guard let model = selectedModel,
        MLXCacheParityEnvironment.isInstalled(model)
      else {
        let report = MLXCacheParityHarness.skippedReport(
          family: family,
          reason: modelID.map { "Configured local model \($0) is not installed." }
            ?? "No configured local \(family.rawValue) model is installed."
        )
        try MLXCacheParityEnvironment.write(report, reportFileStem: reportFileStem)
        return
      }
      if requiresImageInput {
        #expect(
          model.supportsImageInput,
          "The exact-model parity test must exercise the VLM loader path."
        )
      }

      Memory.clearCache()
      Memory.peakMemory = 0
      defer {
        Memory.clearCache()
      }

      do {
        let report = try await MLXCacheParityHarness.run(family: family, model: model)
        try MLXCacheParityEnvironment.write(report, reportFileStem: reportFileStem)
        #expect(report.status == .passed)
        if let modelID {
          #expect(report.modelID == modelID)
        }
        switch family {
        case .gemma:
          if model.id == "gemma4-e4b-qat-4bit" {
            #expect(model.prefixReusePolicy == .cacheOnly)
            #expect(
              report.scenarios.map(\.name) == [
                "structured-tool-follow-up",
                "structured-tool-follow-up-reasoning-on",
                "structured-tool-follow-up-beyond-sliding-window",
              ]
            )
            #expect(report.scenarios.map(\.reasoningEnabled) == [false, true, false])
            let productionPath = try #require(report.prefixGeneratorPath)
            #expect(productionPath.validationScope == "prefix_generator_only")
            #expect(productionPath.coldP1Mode == "cold:prefix_checkpoint_missing")
            #expect(productionPath.coldP2Mode == "cold:prefix_checkpoint_missing")
            #expect(productionPath.warmP2Mode == "suffix")
            #expect(productionPath.coldP1ProducerDrained)
            #expect(productionPath.coldP2ProducerDrained)
            #expect(productionPath.warmP2ProducerDrained)
            #expect(productionPath.checkpointSurvivedProducerLifecycle)
            #expect(
              productionPath.coldP1Output.promptTokenCount
                == productionPath.coldP1FullPromptTokenCount
            )
            #expect(
              productionPath.reusedPrefixTokenCount
                == productionPath.coldP1FullPromptTokenCount
            )
            #expect(
              productionPath.fullPromptTokenCount
                == productionPath.reusedPrefixTokenCount + productionPath.suffixTokenCount
            )
            #expect(
              productionPath.coldP2Output.promptTokenCount
                == productionPath.fullPromptTokenCount
            )
            #expect(
              productionPath.warmP2Output.promptTokenCount
                == productionPath.suffixTokenCount
            )
            #expect(
              productionPath.coldP2Output.generatedTokenCount
                == productionPath.warmP2Output.generatedTokenCount
            )
            #expect(
              productionPath.coldP2Output.stopReason
                == productionPath.warmP2Output.stopReason
            )
            #expect(
              productionPath.coldP2Output.textSHA256
                == productionPath.warmP2Output.textSHA256
            )
            #expect(
              productionPath.coldP2Output.toolCallsSHA256
                == productionPath.warmP2Output.toolCallsSHA256
            )
            #expect(productionPath.toolCallParity)
            #expect(productionPath.outputParity)
            #expect(productionPath.passed)
          } else {
            #expect(
              report.scenarios.map(\.name) == [
                "structured-tool-follow-up",
                "structured-tool-follow-up-beyond-sliding-window",
              ]
            )
            #expect(report.scenarios.allSatisfy { !$0.reasoningEnabled })
            #expect(report.prefixGeneratorPath.map { _ in true } == nil)
          }
          #expect(report.scenarios.last?.exceedsExpectedSlidingWindow == true)
          #expect((report.scenarios.last?.p1TokenCount ?? 0) > 512)
        case .qwen:
          #expect(report.scenarios.map(\.name) == ["structured-tool-follow-up"])
          #expect(report.prefixGeneratorPath.map { _ in true } == nil)
        }
        for scenario in report.scenarios {
          if model.id == "gemma4-e4b-qat-4bit" {
            let memory = try #require(scenario.checkpointedDecodeMemory)
            #expect(!memory.baseline.retainsCheckpointCopy)
            #expect(memory.withHeldCheckpointCopy.retainsCheckpointCopy)
            #expect(memory.passed)
            #expect(memory.expectedGeneratedTokenCount == 16)
            #expect(memory.warmupGeneratedTokenCount == 16)
            #expect(memory.baseline.generatedTokenCount == 16)
            #expect(memory.withHeldCheckpointCopy.generatedTokenCount == 16)
            #expect(
              memory.baselineGrowth
                == MLXCheckpointDecodeMemoryGrowth(path: memory.baseline)
            )
            #expect(
              memory.withHeldCheckpointCopyGrowth
                == MLXCheckpointDecodeMemoryGrowth(
                  path: memory.withHeldCheckpointCopy
                )
            )
            #expect(
              memory.withCopyMinusBaselineGrowth
                == MLXCheckpointDecodeMemoryGrowth(
                  baseline: memory.baselineGrowth,
                  current: memory.withHeldCheckpointCopyGrowth
                )
            )
            for path in [memory.baseline, memory.withHeldCheckpointCopy] {
              #expect(
                path.memoryBeforePrefill.peakMemory
                  <= path.memoryAfterPrefill.peakMemory
              )
              #expect(
                path.memoryAfterPrefill.peakMemory
                  <= path.memoryAfterCheckpointCopy.peakMemory
              )
              #expect(
                path.memoryAfterCheckpointCopy.peakMemory
                  <= path.memoryAfterDecode.peakMemory
              )
            }
          } else {
            #expect(scenario.checkpointedDecodeMemory.map { _ in true } == nil)
          }
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
          MLXCacheParityHarness.failedReport(family: family, model: model, error: error),
          reportFileStem: reportFileStem
        )
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
