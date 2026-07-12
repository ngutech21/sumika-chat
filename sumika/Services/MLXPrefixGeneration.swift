import MLX
import MLXLMCommon
import SumikaCore
import Synchronization

/// Single-owner storage for a materialized prompt cache. The non-Sendable MLX
/// cache is protected by a standard mutex and can be leased exactly once.
/// MLX cache elements are reference types without `Sendable` conformance. This
/// narrow one-shot lease mirrors MLXLMCommon's internal transfer box while the
/// mutex enforces exclusive consumption at runtime.
nonisolated final class MLXPrefixCacheLease: @unchecked Sendable {
  private let lock = Mutex(())
  private var cache: [KVCache]?

  init(cache: consuming [KVCache]) {
    self.cache = cache
  }

  func take() -> [KVCache] {
    lock.withLock { _ in
      guard let cache else {
        preconditionFailure("MLX prefix cache lease was consumed more than once")
      }
      self.cache = nil
      return cache
    }
  }
}

nonisolated struct MLXPrefixGenerationCheckpoint: Sendable {
  let tokenIDs: [Int]
  let identity: MLXSessionCacheIdentity
  let messageSnapshot: [MLXMessageSnapshot]
  let cacheLease: MLXPrefixCacheLease
}

nonisolated enum MLXPrefixGenerationMode: Equatable, Sendable {
  case cold(reason: MLXPrefixColdReason)
  case suffix(reusedTokenCount: Int, suffixTokenCount: Int)
}

nonisolated enum MLXPrefixColdReason: String, Equatable, Sendable {
  case noCheckpoint = "prefix_checkpoint_missing"
  case identityChanged = "prefix_checkpoint_identity_changed"
  case tokenPrefixMismatch = "token_prefix_mismatch"
  case emptySuffix = "token_prefix_empty_suffix"
}

nonisolated struct MLXPrefixTokenTelemetry: Equatable, Sendable {
  let fullPromptTokens: Int
  let reusedPrefixTokens: Int
  let suffixTokens: Int

  init(fullPromptTokens: Int, mode: MLXPrefixGenerationMode) {
    self.fullPromptTokens = fullPromptTokens
    switch mode {
    case .cold:
      reusedPrefixTokens = 0
      suffixTokens = fullPromptTokens
    case .suffix(let reusedTokenCount, let suffixTokenCount):
      reusedPrefixTokens = reusedTokenCount
      suffixTokens = suffixTokenCount
    }
  }
}

nonisolated struct MLXPrefixGenerationPlan: Sendable {
  let stream: AsyncThrowingStream<Generation, Error>
  let producerTask: Task<Void, Never>
  let checkpoint: MLXPrefixGenerationCheckpoint
  let mode: MLXPrefixGenerationMode
  let fullPromptTokenCount: Int
  let commonPrefixTokenCount: Int

  var tokenTelemetry: MLXPrefixTokenTelemetry {
    MLXPrefixTokenTelemetry(fullPromptTokens: fullPromptTokenCount, mode: mode)
  }
}

/// Makes repetition and presence penalties observe the canonical full prompt,
/// even when the model only evaluates a warm-cache token suffix.
nonisolated struct MLXPrefixFullPromptLogitProcessor: LogitProcessor {
  private var base: (any LogitProcessor)?
  private let fullPrompt: MLXArray

  init(base: (any LogitProcessor)?, fullPrompt: MLXArray) {
    self.base = base
    self.fullPrompt = fullPrompt
  }

  mutating func prompt(_ prompt: MLXArray) {
    _ = prompt
    let fullPrompt = self.fullPrompt
    base?.prompt(fullPrompt)
  }

  func process(logits: MLXArray) -> MLXArray {
    base?.process(logits: logits) ?? logits
  }

  mutating func didSample(token: MLXArray) {
    base?.didSample(token: token)
  }
}

nonisolated enum MLXPrefixGenerator {
  static func prepare(
    isolation: isolated (any Actor),
    modelContainer: ModelContainer,
    userInput: consuming sending UserInput,
    previousCheckpoint: MLXPrefixGenerationCheckpoint?,
    identity: MLXSessionCacheIdentity,
    messageSnapshot: [MLXMessageSnapshot],
    parameters: GenerateParameters,
    tools: [ToolSpec]
  ) async throws -> MLXPrefixGenerationPlan {
    _ = isolation
    let fullInput = try await modelContainer.prepare(input: userInput)
    try Task.checkCancellation()
    fullInput.text.tokens.eval()
    try Task.checkCancellation()
    let fullPromptTokenIDs = fullInput.text.tokens.asArray(Int.self)

    let preparation = prefixPreparation(
      previousCheckpoint: previousCheckpoint,
      identity: identity,
      fullPromptTokenIDs: fullPromptTokenIDs
    )
    let effectiveInput: LMInput
    let workingCache: [KVCache]?
    switch preparation.mode {
    case .cold:
      effectiveInput = fullInput
      workingCache = nil
    case .suffix:
      effectiveInput = LMInput(
        text: LMInput.Text(tokens: MLXArray(preparation.suffix))
      )
      workingCache = previousCheckpoint?.cacheLease.take()
    }

    let work = MLXPrefixGenerationWork(
      input: effectiveInput,
      cache: workingCache,
      fullPromptTokenIDs: fullPromptTokenIDs,
      parameters: parameters,
      tools: tools,
      usesTokenSuffix: preparation.mode.isSuffix
    )
    let start = try await modelContainer.perform(nonSendable: work) { context, work in
      try Task.checkCancellation()
      let cache = work.cache ?? context.model.newCache(parameters: work.parameters)
      let iterator: TokenIterator
      if work.usesTokenSuffix {
        let processor = MLXPrefixFullPromptLogitProcessor(
          base: work.parameters.processor(),
          fullPrompt: MLXArray(work.fullPromptTokenIDs)
        )
        iterator = try TokenIterator(
          input: work.input,
          model: context.model,
          cache: cache,
          processor: processor,
          sampler: work.parameters.sampler(),
          prefillStepSize: work.parameters.prefillStepSize,
          maxTokens: work.parameters.maxTokens
        )
      } else {
        iterator = try TokenIterator(
          input: work.input,
          model: context.model,
          cache: cache,
          parameters: work.parameters
        )
      }

      try checkCancellationDrainingMLX()
      eval(cache.flatMap(\.state))
      let checkpointCache = cache.map { $0.copy() }
      eval(checkpointCache.flatMap(\.state))
      try checkCancellationDrainingMLX()
      let cacheLease = MLXPrefixCacheLease(cache: checkpointCache)
      let (source, producerTask) = generateTask(
        promptTokenCount: work.input.text.tokens.size,
        modelConfiguration: context.configuration,
        tokenizer: context.tokenizer,
        iterator: iterator,
        tools: work.tools
      )
      return MLXPrefixGenerationStart(
        stream: throwingStream(from: source, producerTask: producerTask),
        producerTask: producerTask,
        cacheLease: cacheLease
      )
    }

    return MLXPrefixGenerationPlan(
      stream: start.stream,
      producerTask: start.producerTask,
      checkpoint: MLXPrefixGenerationCheckpoint(
        tokenIDs: fullPromptTokenIDs,
        identity: identity,
        messageSnapshot: messageSnapshot,
        cacheLease: start.cacheLease
      ),
      mode: preparation.mode,
      fullPromptTokenCount: fullPromptTokenIDs.count,
      commonPrefixTokenCount: preparation.commonPrefixTokenCount
    )
  }

  private static func checkCancellationDrainingMLX() throws {
    guard Task.isCancelled else {
      return
    }
    Stream().synchronize()
    throw CancellationError()
  }

  private static func prefixPreparation(
    previousCheckpoint: MLXPrefixGenerationCheckpoint?,
    identity: MLXSessionCacheIdentity,
    fullPromptTokenIDs: [Int]
  ) -> MLXPrefixPreparation {
    guard let previousCheckpoint else {
      return MLXPrefixPreparation(
        mode: .cold(reason: .noCheckpoint),
        suffix: [],
        commonPrefixTokenCount: 0
      )
    }
    guard previousCheckpoint.identity == identity else {
      return MLXPrefixPreparation(
        mode: .cold(reason: .identityChanged),
        suffix: [],
        commonPrefixTokenCount: 0
      )
    }

    let analysis = MLXCheckpointTokenPrefixAnalysis(
      checkpointTokens: previousCheckpoint.tokenIDs,
      promptTokens: fullPromptTokenIDs
    )
    guard analysis.isExactPrefix else {
      return MLXPrefixPreparation(
        mode: .cold(reason: .tokenPrefixMismatch),
        suffix: [],
        commonPrefixTokenCount: analysis.firstMismatchIndex ?? analysis.commonPrefixCount
      )
    }
    guard analysis.isStrictExtension else {
      return MLXPrefixPreparation(
        mode: .cold(reason: .emptySuffix),
        suffix: [],
        commonPrefixTokenCount: analysis.commonPrefixCount
      )
    }
    return MLXPrefixPreparation(
      mode: .suffix(
        reusedTokenCount: previousCheckpoint.tokenIDs.count,
        suffixTokenCount: analysis.suffixTokens.count
      ),
      suffix: analysis.suffixTokens,
      commonPrefixTokenCount: analysis.commonPrefixCount
    )
  }

  private static func throwingStream(
    from source: AsyncStream<Generation>,
    producerTask: Task<Void, Never>
  ) -> AsyncThrowingStream<Generation, Error> {
    let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
    let relayTask = Task {
      for await generation in source {
        if case .terminated = continuation.yield(generation) {
          break
        }
      }
      await producerTask.value
      continuation.finish()
    }
    continuation.onTermination = { _ in
      relayTask.cancel()
      producerTask.cancel()
    }
    return stream
  }
}

nonisolated private struct MLXPrefixPreparation {
  let mode: MLXPrefixGenerationMode
  let suffix: [Int]
  let commonPrefixTokenCount: Int
}

nonisolated private struct MLXPrefixGenerationWork {
  let input: LMInput
  let cache: [KVCache]?
  let fullPromptTokenIDs: [Int]
  let parameters: GenerateParameters
  let tools: [ToolSpec]
  let usesTokenSuffix: Bool
}

nonisolated private struct MLXPrefixGenerationStart: Sendable {
  let stream: AsyncThrowingStream<Generation, Error>
  let producerTask: Task<Void, Never>
  let cacheLease: MLXPrefixCacheLease
}

extension MLXPrefixGenerationMode {
  nonisolated fileprivate var isSuffix: Bool {
    if case .suffix = self {
      return true
    }
    return false
  }
}
