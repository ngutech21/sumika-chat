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

    try await completeColdGeneration(
      diagnostics,
      fullPromptTokens: 100,
      generatedTokens: 20
    )

    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 20, generatedTokens: 5)
      )
    )

    #expect(result.decision == .exactSuffixReuse)
    #expect(result.mismatchReason == nil)
    #expect(result.fullPromptTokens == 140)
    #expect(result.expectedCachedTokens == 120)
    #expect(result.expectedSuffixTokens == 20)
    #expect(result.reusedPromptTokens == 120)
  }

  @Test
  func exactSuffixReuseAllowsAnEOSOutsideGenerationTokenCount() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    try await completeColdGeneration(
      diagnostics,
      fullPromptTokens: 100,
      generatedTokens: 20
    )

    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )

    let result = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(promptTokens: 19, generatedTokens: 5)
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

    try await completeColdGeneration(
      diagnostics,
      fullPromptTokens: 100,
      generatedTokens: 20
    )

    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
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

    try await completeColdGeneration(
      diagnostics,
      fullPromptTokens: 100,
      generatedTokens: 20
    )

    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
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

    try await completeColdGeneration(
      diagnostics,
      fullPromptTokens: 100,
      generatedTokens: 20
    )

    let generationID = UUID()
    await diagnostics.begin(
      generationID: generationID,
      expectsReuse: true,
      newMediaPresent: true
    )
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
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

    try await completeColdGeneration(
      diagnostics,
      fullPromptTokens: 100,
      generatedTokens: 20
    )

    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
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
  func invalidationDropsThePreviousTokenLedger() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )

    try await completeColdGeneration(
      diagnostics,
      fullPromptTokens: 100,
      generatedTokens: 20
    )
    await diagnostics.invalidate()

    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: false)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
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

    #expect(result.decision == .coldPrefill)
    #expect(result.expectedCachedTokens == nil)
    #expect(result.mismatchReason == nil)
  }

  @Test
  func expectedReuseWithoutATokenLedgerIsReportedAsUnavailable() async throws {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: ["MLXLMCommon.KVCacheSimple"],
      cacheTrimmable: true
    )
    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: true)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: 140,
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

    #expect(result.decision == .unavailable)
    #expect(result.mismatchReason == .missingCachedTokenLedger)
    #expect(result.expectedCachedTokens == nil)
  }

  private func completeColdGeneration(
    _ diagnostics: MLXRuntimeCacheDiagnostics,
    fullPromptTokens: Int,
    generatedTokens: Int
  ) async throws {
    let generationID = UUID()
    await diagnostics.begin(generationID: generationID, expectsReuse: false)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: fullPromptTokens,
        inputMaskPresent: false,
        preparedMediaPresent: false
      )
    )
    _ = try #require(
      await diagnostics.complete(
        generationID: generationID,
        info: completionInfo(
          promptTokens: fullPromptTokens,
          generatedTokens: generatedTokens
        )
      )
    )
  }

  private func completionInfo(
    promptTokens: Int,
    generatedTokens: Int
  ) -> GenerateCompletionInfo {
    GenerateCompletionInfo(
      promptTokenCount: promptTokens,
      generationTokenCount: generatedTokens,
      promptTime: 0.1,
      generationTime: 0.2
    )
  }
}
