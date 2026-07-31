import Foundation
import MLXLMCommon

enum MLXRuntimeCacheDecision: String, Equatable, Sendable {
  case coldPrefill = "cold_prefill"
  case exactSuffixReuse = "exact_suffix_reuse"
  case commonPrefixReuse = "common_prefix_reuse"
  case fullPrefill = "full_prefill"
  case unavailable
  case unexpectedPromptCount = "unexpected_prompt_count"
}

enum MLXRuntimeCacheMismatchReason: String, Equatable, Sendable {
  case preparedInputMask = "prepared_input_mask"
  case newMedia = "new_media"
  case preparedMedia = "prepared_media"
  case cachedLedgerLongerThanPrompt = "cached_ledger_longer_than_prompt"
  case prefixOrAlignmentMismatch = "prefix_or_alignment_mismatch"
  case nontrimmablePrefixOrAlignmentMismatch =
    "prefix_or_alignment_mismatch_nontrimmable_cache"
  case missingCachedTokenLedger = "missing_cached_token_ledger"
  case promptTokenCountOutOfRange = "prompt_token_count_out_of_range"
}

struct MLXPreparedInputDiagnostics: Equatable, Sendable {
  let fullPromptTokens: Int
  let inputMaskPresent: Bool
  let preparedMediaPresent: Bool
}

struct MLXRuntimeCacheCapabilities: Equatable, Sendable {
  let cacheTypes: [String]
  let cacheTrimmable: Bool
}

struct MLXRuntimeCacheDiagnosticResult: Equatable, Sendable {
  let decision: MLXRuntimeCacheDecision
  let mismatchReason: MLXRuntimeCacheMismatchReason?
  let fullPromptTokens: Int
  let expectedCachedTokens: Int?
  let expectedSuffixTokens: Int?
  let reusedPromptTokens: Int
  let inputMaskPresent: Bool
  let preparedMediaPresent: Bool
  let newMediaPresent: Bool
  let cacheTrimmable: Bool
  let cacheTypes: [String]
}

actor MLXRuntimeCacheDiagnostics {
  private struct CachedTokenLedger {
    let lowerBound: Int
    let upperBound: Int

    func contains(_ tokenCount: Int) -> Bool {
      lowerBound...upperBound ~= tokenCount
    }
  }

  private struct ActiveGeneration {
    let id: UUID
    let expectsReuse: Bool
    let newMediaPresent: Bool
    var preparedInput: MLXPreparedInputDiagnostics?
  }

  private var cacheTypes: [String]
  private var cacheTrimmable: Bool

  private var activeGeneration: ActiveGeneration?
  private var cachedTokenLedger: CachedTokenLedger?

  init(cacheTypes: [String], cacheTrimmable: Bool) {
    self.cacheTypes = cacheTypes
    self.cacheTrimmable = cacheTrimmable
  }

  static func install(on modelContainer: ModelContainer) async -> MLXRuntimeCacheDiagnostics {
    let diagnostics = MLXRuntimeCacheDiagnostics(
      cacheTypes: [],
      cacheTrimmable: false
    )
    await modelContainer.update { context in
      context.processor = MLXDiagnosingInputProcessor(
        base: context.processor,
        diagnostics: diagnostics
      )
    }
    return diagnostics
  }

  static func capabilities(
    of modelContainer: ModelContainer,
    parameters: GenerateParameters
  ) async -> MLXRuntimeCacheCapabilities {
    await modelContainer.perform(values: parameters) { context, parameters in
      let caches = context.model.newCache(parameters: parameters)
      var cacheTypes: [String] = []
      for cache in caches {
        let typeName = String(reflecting: type(of: cache))
        if !cacheTypes.contains(typeName) {
          cacheTypes.append(typeName)
        }
      }
      return MLXRuntimeCacheCapabilities(
        cacheTypes: cacheTypes,
        cacheTrimmable: caches.allSatisfy(\.isTrimmable)
      )
    }
  }

  func begin(
    generationID: UUID,
    expectsReuse: Bool,
    newMediaPresent: Bool = false,
    capabilities: MLXRuntimeCacheCapabilities? = nil
  ) {
    if let capabilities {
      cacheTypes = capabilities.cacheTypes
      cacheTrimmable = capabilities.cacheTrimmable
    }
    if !expectsReuse {
      cachedTokenLedger = nil
    }
    activeGeneration = ActiveGeneration(
      id: generationID,
      expectsReuse: expectsReuse,
      newMediaPresent: newMediaPresent,
      preparedInput: nil
    )
  }

  func recordPreparedInput(_ preparedInput: MLXPreparedInputDiagnostics) {
    activeGeneration?.preparedInput = preparedInput
  }

  func complete(
    generationID: UUID,
    info: GenerateCompletionInfo
  ) -> MLXRuntimeCacheDiagnosticResult? {
    guard let activeGeneration,
      activeGeneration.id == generationID,
      let preparedInput = activeGeneration.preparedInput
    else {
      return nil
    }

    let previousCachedTokens =
      activeGeneration.expectsReuse ? cachedTokenLedger : nil
    let result = Self.result(
      preparedInput: preparedInput,
      info: info,
      expectsReuse: activeGeneration.expectsReuse,
      newMediaPresent: activeGeneration.newMediaPresent,
      expectedCachedTokens: previousCachedTokens,
      cacheTypes: cacheTypes,
      cacheTrimmable: cacheTrimmable
    )

    switch info.stopReason {
    case .stop, .length:
      let lowerBound = preparedInput.fullPromptTokens + info.generationTokenCount
      cachedTokenLedger = CachedTokenLedger(
        lowerBound: lowerBound,
        // `generationTokenCount` excludes an EOS token, but includes a token
        // that completes a textual stop string. ChatSession's private token
        // ledger includes whichever token was evaluated into the cache.
        upperBound: lowerBound + (info.stopReason == .stop ? 1 : 0)
      )
    case .cancelled:
      cachedTokenLedger = nil
    }
    self.activeGeneration = nil
    return result
  }

  func invalidate() {
    activeGeneration = nil
    cachedTokenLedger = nil
  }

  private static func result(
    preparedInput: MLXPreparedInputDiagnostics,
    info: GenerateCompletionInfo,
    expectsReuse: Bool,
    newMediaPresent: Bool,
    expectedCachedTokens: CachedTokenLedger?,
    cacheTypes: [String],
    cacheTrimmable: Bool
  ) -> MLXRuntimeCacheDiagnosticResult {
    let fullPromptTokens = preparedInput.fullPromptTokens
    let reusedPromptTokens = max(fullPromptTokens - info.promptTokenCount, 0)
    let matchedCachedTokens = expectedCachedTokens.map { ledger in
      ledger.contains(reusedPromptTokens) ? reusedPromptTokens : ledger.lowerBound
    }
    let expectedSuffixTokens = matchedCachedTokens.map {
      max(fullPromptTokens - $0, 0)
    }
    let decision: MLXRuntimeCacheDecision
    if !expectsReuse {
      decision = .coldPrefill
    } else if expectedCachedTokens == nil {
      decision = .unavailable
    } else if info.promptTokenCount > fullPromptTokens {
      decision = .unexpectedPromptCount
    } else if info.promptTokenCount == fullPromptTokens {
      decision = .fullPrefill
    } else if expectedCachedTokens?.contains(reusedPromptTokens) == true {
      decision = .exactSuffixReuse
    } else {
      decision = .commonPrefixReuse
    }

    let mismatchReason = mismatchReason(
      decision: decision,
      preparedInput: preparedInput,
      newMediaPresent: newMediaPresent,
      expectedCachedTokens: expectedCachedTokens,
      cacheTrimmable: cacheTrimmable
    )
    return MLXRuntimeCacheDiagnosticResult(
      decision: decision,
      mismatchReason: mismatchReason,
      fullPromptTokens: fullPromptTokens,
      expectedCachedTokens: matchedCachedTokens,
      expectedSuffixTokens: expectedSuffixTokens,
      reusedPromptTokens: reusedPromptTokens,
      inputMaskPresent: preparedInput.inputMaskPresent,
      preparedMediaPresent: preparedInput.preparedMediaPresent,
      newMediaPresent: newMediaPresent,
      cacheTrimmable: cacheTrimmable,
      cacheTypes: cacheTypes
    )
  }

  private static func mismatchReason(
    decision: MLXRuntimeCacheDecision,
    preparedInput: MLXPreparedInputDiagnostics,
    newMediaPresent: Bool,
    expectedCachedTokens: CachedTokenLedger?,
    cacheTrimmable: Bool
  ) -> MLXRuntimeCacheMismatchReason? {
    guard
      decision == .fullPrefill
        || decision == .unavailable
        || decision == .unexpectedPromptCount
    else {
      return nil
    }
    if decision == .unavailable {
      return .missingCachedTokenLedger
    }
    if decision == .unexpectedPromptCount {
      return .promptTokenCountOutOfRange
    }
    if preparedInput.inputMaskPresent {
      return .preparedInputMask
    }
    if newMediaPresent {
      return .newMedia
    }
    if preparedInput.preparedMediaPresent {
      return .preparedMedia
    }
    if let expectedCachedTokens,
      expectedCachedTokens.lowerBound > preparedInput.fullPromptTokens
    {
      return .cachedLedgerLongerThanPrompt
    }
    return cacheTrimmable
      ? .prefixOrAlignmentMismatch
      : .nontrimmablePrefixOrAlignmentMismatch
  }
}

private struct MLXDiagnosingInputProcessor: UserInputProcessor {
  let base: any UserInputProcessor
  let diagnostics: MLXRuntimeCacheDiagnostics

  func prepare(input: UserInput) async throws -> LMInput {
    let preparedInput = try await base.prepare(input: input)
    await diagnostics.recordPreparedInput(
      MLXPreparedInputDiagnostics(
        fullPromptTokens: preparedInput.text.tokens.size,
        inputMaskPresent: preparedInput.text.mask != nil,
        preparedMediaPresent: preparedInput.image != nil
          || preparedInput.video != nil
          || preparedInput.audio != nil
      )
    )
    return preparedInput
  }
}
