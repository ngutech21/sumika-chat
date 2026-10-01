import Foundation
import MLXLMCommon
import Testing

@testable import SumikaRuntimeMLX

@Suite
struct MLXRuntimeCacheDiagnosticsTests {
  @Test
  func exactSuffixReuseReportsTheReusedTokenCount() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(
          promptTokens: 20,
          cachedPromptTokens: 120,
          generatedTokens: 5
        )
      )
    )

    #expect(result.decision == .exactSuffixReuse)
    #expect(result.mismatchReason == nil)
    #expect(result.fullPromptTokens == 140)
    #expect(result.expectedCachedTokens == 120)
    #expect(result.expectedSuffixTokens == 20)
    #expect(result.reusedPromptTokens == 120)
    #expect(result.cacheEfficiency == 120.0 / 140.0)
  }

  @Test
  func partialReusePreservesTheAuthoritativePreviousPosition() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(
          promptTokens: 40,
          cachedPromptTokens: 100,
          generatedTokens: 5
        )
      )
    )

    #expect(result.decision == .commonPrefixReuse)
    #expect(result.fullPromptTokens == 140)
    #expect(result.expectedCachedTokens == 120)
    #expect(result.expectedSuffixTokens == 20)
    #expect(result.reusedPromptTokens == 100)
    #expect(result.cacheEfficiency == 100.0 / 140.0)
  }

  @Test
  func exactSuffixReuseUsesTheRealizedPositionIncludingEOS() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 121)
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(
          promptTokens: 19,
          cachedPromptTokens: 121,
          generatedTokens: 5
        )
      )
    )

    #expect(result.decision == .exactSuffixReuse)
    #expect(result.expectedCachedTokens == 121)
    #expect(result.expectedSuffixTokens == 19)
    #expect(result.reusedPromptTokens == 121)
  }

  @Test
  func fullPrefillOnNontrimmableCacheIdentifiesPrefixOrAlignmentMismatch() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: [
        "MLXLMCommon.MambaCache",
        "MLXLMCommon.KVCacheSimple",
      ],
      cacheTrimmable: false
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 140, generatedTokens: 5)
      )
    )

    #expect(result.decision == .fullPrefill)
    #expect(result.mismatchReason == .nontrimmablePrefixOrAlignmentMismatch)
    #expect(result.fullPromptTokens == 140)
    #expect(result.expectedCachedTokens == 120)
    #expect(result.expectedSuffixTokens == 20)
    #expect(result.reusedPromptTokens == 0)
    #expect(result.cacheTrimmable == false)
    #expect(result.cacheTypes == ["MLXLMCommon.MambaCache", "MLXLMCommon.KVCacheSimple"])
  }

  @Test
  func preparedInputMaskTakesPrecedenceOverGenericPrefixMismatch() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        inputMaskPresent: true,
        preparedMediaPresent: false
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 140, generatedTokens: 5)
      )
    )

    #expect(result.decision == .fullPrefill)
    #expect(result.mismatchReason == .preparedInputMask)
    #expect(result.inputMaskPresent)
  }

  @Test
  func newMediaTakesPrecedenceOverPreparedHistoricalMedia() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120),
      newMediaPresent: true
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        inputMaskPresent: false,
        preparedMediaPresent: true
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 140, generatedTokens: 5)
      )
    )

    #expect(result.decision == .fullPrefill)
    #expect(result.mismatchReason == .newMedia)
    #expect(result.newMediaPresent)
    #expect(result.preparedMediaPresent)
  }

  @Test
  func preparedHistoricalMediaIdentifiesTheCommonPrefixGuard() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        inputMaskPresent: false,
        preparedMediaPresent: true
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 140, generatedTokens: 5)
      )
    )

    #expect(result.decision == .fullPrefill)
    #expect(result.mismatchReason == .preparedMedia)
    #expect(result.newMediaPresent == false)
    #expect(result.preparedMediaPresent)
  }

  @Test
  func reusingOneTokenLessThanThePreviousPositionIsCommonPrefixReuse() async throws {
    let diagnostics = makeDiagnostics()
    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 121)
    )
    await recordTextInput(on: diagnostics)

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 20, cachedPromptTokens: 120, generatedTokens: 5)
      )
    )

    #expect(result.decision == .commonPrefixReuse)
    #expect(result.expectedCachedTokens == 121)
    #expect(result.expectedSuffixTokens == 19)
    #expect(result.reusedPromptTokens == 120)
  }

  @Test
  func coldPrefillIgnoresASuppliedPreviousPosition() async throws {
    let diagnostics = makeDiagnostics()
    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: false,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await recordTextInput(on: diagnostics)

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 140, generatedTokens: 5)
      )
    )

    #expect(result.decision == .coldPrefill)
    #expect(result.expectedCachedTokens == nil)
    #expect(result.expectedSuffixTokens == nil)
    #expect(result.mismatchReason == nil)
    #expect(result.fullPromptTokens == 140)
    #expect(result.reusedPromptTokens == 0)
    #expect(result.cacheEfficiency == 0)
  }

  @Test
  func missingOrPlannedPreviousPositionIsReportedAsUnavailable() async throws {
    let statuses: [KVCacheStatus?] = [
      nil,
      cacheStatus(processedTokens: nil),
      cacheStatus(processedTokens: 120, phase: .planned),
    ]
    for status in statuses {
      let diagnostics = makeDiagnostics()
      let generationID = UUID()
      await diagnostics.begin(
        generationID: generationID,
        expectsReuse: true,
        previousCacheStatus: status
      )
      await recordTextInput(on: diagnostics)

      let result = try #require(
        await diagnostics.complete(
          generationID: generationID,
          info: completionInfo(promptTokens: 140, generatedTokens: 5)
        )
      )

      #expect(result.decision == .unavailable)
      #expect(result.mismatchReason == .missingProcessedTokenCount)
      #expect(result.expectedCachedTokens == nil)
      #expect(result.expectedSuffixTokens == nil)
    }
  }

  @Test
  func zeroPreviousPositionIsAvailableForFullPrefill() async throws {
    let diagnostics = makeDiagnostics()
    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 0)
    )
    await recordTextInput(on: diagnostics)

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 140, generatedTokens: 5)
      )
    )

    #expect(result.decision == .fullPrefill)
    #expect(result.mismatchReason == .prefixOrAlignmentMismatch)
    #expect(result.expectedCachedTokens == 0)
    #expect(result.expectedSuffixTokens == 140)
  }

  @Test
  func previousPositionLongerThanPromptIdentifiesTheMismatch() async throws {
    let diagnostics = makeDiagnostics()
    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 160)
    )
    await recordTextInput(on: diagnostics)

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 140, generatedTokens: 5)
      )
    )

    #expect(result.decision == .fullPrefill)
    #expect(result.mismatchReason == .previousCachePositionLongerThanPrompt)
    #expect(result.expectedCachedTokens == 160)
    #expect(result.expectedSuffixTokens == 0)
  }

  @Test
  func invalidationDiscardsTheActiveGenerationSnapshot() async {
    let diagnostics = makeDiagnostics()
    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await recordTextInput(on: diagnostics)
    await diagnostics.invalidate()

    let result = await diagnostics.complete(
      generationID: generationID,
      info: completionInfo(promptTokens: 20, cachedPromptTokens: 120, generatedTokens: 5)
    )
    #expect(result == nil)
  }

  @Test
  func staleCompletionCannotConsumeTheCurrentGenerationSnapshot() async throws {
    let diagnostics = makeDiagnostics()
    let previousID = UUID()
    await diagnostics.begin(
      generationID: previousID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 120)
    )
    await recordTextInput(on: diagnostics)
    let currentID = UUID()
    await diagnostics.begin(
      generationID: currentID,
      expectsReuse: true,
      previousCacheStatus: cacheStatus(processedTokens: 160)
    )
    await recordTextInput(on: diagnostics)

    let staleResult = await diagnostics.complete(
      generationID: previousID,
      info: completionInfo(promptTokens: 20, cachedPromptTokens: 120, generatedTokens: 5)
    )
    #expect(staleResult == nil)
    let currentResult = try #require(
      await diagnostics.complete(
        generationID: currentID,
        info: completionInfo(promptTokens: 20, cachedPromptTokens: 160, generatedTokens: 5)
      )
    )
    #expect(currentResult.decision == .exactSuffixReuse)
    #expect(currentResult.expectedCachedTokens == 160)
    #expect(currentResult.fullPromptTokens == 180)
  }

  @Test
  func completionDoesNotSupplyTheNextGenerationsPreviousPosition() async throws {
    let diagnostics = makeDiagnostics()
    let previousID = UUID()
    await diagnostics.begin(
      generationID: previousID,
      expectsReuse: false,
      previousCacheStatus: nil
    )
    await recordTextInput(on: diagnostics)
    _ = try #require(
      await diagnostics.complete(
        generationID: previousID,
        info: completionInfo(promptTokens: 100, generatedTokens: 20)
      )
    )

    let currentID = UUID()
    await diagnostics.begin(
      generationID: currentID,
      expectsReuse: true,
      previousCacheStatus: nil
    )
    await recordTextInput(on: diagnostics)
    let result = try #require(
      await diagnostics.complete(
        generationID: currentID,
        info: completionInfo(promptTokens: 20, cachedPromptTokens: 120, generatedTokens: 5)
      )
    )
    #expect(result.decision == .unavailable)
    #expect(result.mismatchReason == .missingProcessedTokenCount)
    #expect(result.expectedCachedTokens == nil)
    #expect(result.reusedPromptTokens == 120)
  }

  private func makeDiagnostics() -> MLXRuntimeCacheDiagnostics {
    MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )
  }

  private func cacheStatus(
    processedTokens: Int?,
    phase: KVCacheStatus.Phase = .realized
  ) -> KVCacheStatus {
    KVCacheStatus(cache: [], phase: phase, processedTokenCount: processedTokens)
  }

  private func recordTextInput(on diagnostics: MLXRuntimeCacheDiagnostics) async {
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(inputMaskPresent: false, preparedMediaPresent: false)
    )
  }

  private func completionInfo(
    promptTokens: Int,
    cachedPromptTokens: Int = 0,
    generatedTokens: Int
  ) -> GenerateCompletionInfo {
    GenerateCompletionInfo(
      promptTokenCount: promptTokens,
      cachedPromptTokenCount: cachedPromptTokens,
      generationTokenCount: generatedTokens,
      promptTime: 0.1,
      generationTime: 0.2
    )
  }
}
