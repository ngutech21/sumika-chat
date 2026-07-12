import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import SumikaCore

@testable import Sumika

nonisolated enum MLXCacheParityFamily: String, Codable, Sendable {
  case gemma
  case qwen
}

nonisolated struct MLXTokenPrefixAnalysis: Equatable, Sendable {
  let commonPrefixCount: Int
  let suffix: [Int]
  let isExactPrefix: Bool

  nonisolated init(prefix: [Int], full: [Int]) {
    commonPrefixCount = zip(prefix, full).prefix { $0 == $1 }.count
    isExactPrefix = commonPrefixCount == prefix.count
    suffix = isExactPrefix ? Array(full.dropFirst(prefix.count)) : []
  }
}

/// Makes the prompt seen by penalties independent of the smaller token suffix
/// passed to the model during a warm-cache parity run.
nonisolated struct MLXFullPromptLogitProcessor: LogitProcessor {
  private var base: (any LogitProcessor)?
  private let fullPrompt: MLXArray

  init(base: (any LogitProcessor)?, fullPrompt: MLXArray) {
    self.base = base
    self.fullPrompt = fullPrompt
  }

  mutating func prompt(_ prompt: MLXArray) {
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

nonisolated struct MLXCacheParityMemorySnapshot: Codable, Sendable {
  let activeMemory: Int
  let cacheMemory: Int
  let activeAndCacheMemory: Int
  let peakMemory: Int

  init(activeMemory: Int, cacheMemory: Int, peakMemory: Int) {
    self.activeMemory = activeMemory
    self.cacheMemory = cacheMemory
    activeAndCacheMemory = activeMemory + cacheMemory
    self.peakMemory = peakMemory
  }

  init(_ snapshot: Memory.Snapshot) {
    activeMemory = snapshot.activeMemory
    cacheMemory = snapshot.cacheMemory
    activeAndCacheMemory = snapshot.activeMemory + snapshot.cacheMemory
    peakMemory = snapshot.peakMemory
  }
}

nonisolated struct MLXCacheParityMemoryDelta: Codable, Equatable, Sendable {
  let activeMemoryBytes: Int
  let cacheMemoryBytes: Int
  let activeAndCacheMemoryBytes: Int
  let peakMemoryBytes: Int

  init(
    baseline: MLXCacheParityMemorySnapshot,
    current: MLXCacheParityMemorySnapshot
  ) {
    activeMemoryBytes = current.activeMemory - baseline.activeMemory
    cacheMemoryBytes = current.cacheMemory - baseline.cacheMemory
    activeAndCacheMemoryBytes =
      current.activeAndCacheMemory - baseline.activeAndCacheMemory
    peakMemoryBytes = current.peakMemory - baseline.peakMemory
  }
}

nonisolated struct MLXCacheParityCacheLayer: Codable, Equatable, Sendable {
  let index: Int
  let type: String
  let offset: Int
  let maxSize: Int?
  let stateShapes: [[Int]]
  let stateSHA256: [String]
  let metaState: [String]

  init(index: Int, cache: any KVCache, stateSHA256: [String]) {
    self.index = index
    type = String(reflecting: Swift.type(of: cache))
    offset = cache.offset
    maxSize = cache.maxSize
    stateShapes = cache.state.map(\.shape)
    self.stateSHA256 = stateSHA256
    metaState = cache.metaState
  }
}

nonisolated struct MLXCacheParityCopyIsolation: Codable, Sendable {
  let originalOffsetsBeforeCopies: [Int]
  let originalOffsetsAfterCopies: [Int]
  let originalOffsetsAfterWarmRuns: [Int]
  let originalStateSHA256BeforeCopies: [[String]]
  let originalStateSHA256AfterCopies: [[String]]
  let originalStateSHA256AfterWarmRuns: [[String]]
  let copiedStateSHA256BeforeWarmRuns: [[[String]]]
  let copiedCachesMatchOriginalBeforeWarmRuns: Bool
  let copiedCachesAdvanced: Bool
  let originalOffsetsUnchanged: Bool
  let originalStateUnchanged: Bool
  let passed: Bool
}

nonisolated enum MLXCacheParityExecutionKind: String, Codable, Sendable {
  case fullPrompt
  case directSuffix
}

nonisolated struct MLXCacheParityMeasuredPath: Codable, Sendable {
  let executionKind: MLXCacheParityExecutionKind
  let executionDurationSeconds: Double
  let prefixRecomputationDurationSeconds: Double
  let totalDurationSeconds: Double
  let processorPromptTokenCount: Int
  let reusedContinuationState: Bool
  let rawFirstLogitsSHA256: String
  let processedFirstLogitsSHA256: String
  let firstArgmaxSHA256: String
  let generatedTokenCount: Int
  let first16TokenIDsSHA256: String
  let decodedTextSHA256: String
  let memoryBefore: MLXCacheParityMemorySnapshot
  let memoryAfter: MLXCacheParityMemorySnapshot
  let cacheAfter: [MLXCacheParityCacheLayer]
}

nonisolated struct MLXCacheParityLogitComparison: Codable, Sendable {
  let referenceCount: Int
  let candidateCount: Int
  let relativeTolerance: Double
  let absoluteTolerance: Double
  let exactlyEqual: Bool
  let allClose: Bool
  let maxAbsoluteDifference: Double?
  let meanAbsoluteDifference: Double?
  let rootMeanSquareDifference: Double?
  let maxAbsoluteMagnitude: Double?
  let normalizedMaxDifference: Double?
  let normalizedRootMeanSquareDifference: Double?
  let cosineSimilarity: Double?
}

nonisolated struct MLXCacheParityBehaviorComparison: Codable, Sendable {
  let argmaxParity: Bool
  let first16TokenParity: Bool
  let decodedTextParity: Bool

  var passed: Bool {
    argmaxParity && first16TokenParity && decodedTextParity
  }
}

nonisolated struct MLXCacheParityComparison: Codable, Sendable {
  let rawFirstLogits: MLXCacheParityLogitComparison
  let processedFirstLogits: MLXCacheParityLogitComparison
  let behavior: MLXCacheParityBehaviorComparison

  /// True when behavior is identical but execution-shape changes still
  /// produce a floating-point difference.
  let chunkingNumericalDrift: Bool
}

nonisolated enum MLXCacheReuseRequirement: String, Codable, Sendable {
  case cacheOnly
  case cacheAndContinuationState
  case noPassingReusePath
}

nonisolated struct MLXCacheParityReuseModeReport: Codable, Sendable {
  let freshSplit: MLXCacheParityMeasuredPath
  let copiedWarm: MLXCacheParityMeasuredPath
  let freshSplitVsCopiedWarm: MLXCacheParityComparison
  let fullColdVsFreshSplit: MLXCacheParityComparison
  let fullColdVsCopiedWarm: MLXCacheParityComparison
  let finalCacheParity: Bool
  let strictCopyParityPassed: Bool
  let fullColdBehavioralParityPassed: Bool
  let reuseParityPassed: Bool
}

nonisolated struct MLXCacheParityScenarioReport: Codable, Sendable {
  let name: String
  let p1TokenCount: Int
  let p2TokenCount: Int
  let commonPrefixTokenCount: Int
  let suffixTokenCount: Int
  let p1IsExactPrefixOfP2: Bool
  let exceedsExpectedSlidingWindow: Bool
  let continuationStateProducedByP1: Bool
  let checkpointDurationSeconds: Double
  let checkpointMemoryBefore: MLXCacheParityMemorySnapshot
  let checkpointMemoryAfter: MLXCacheParityMemorySnapshot
  let checkpointCopyCount: Int
  let checkpointCopiesMemoryAfter: MLXCacheParityMemorySnapshot
  let checkpointCopiesMemoryDelta: MLXCacheParityMemoryDelta
  let perCopyActiveAndCacheMemoryBytes: Double
  let checkpointCache: [MLXCacheParityCacheLayer]
  let copiedCheckpointCache: [MLXCacheParityCacheLayer]
  let copyIsolation: MLXCacheParityCopyIsolation
  let reuseRequirement: MLXCacheReuseRequirement
  let fullCold: MLXCacheParityMeasuredPath
  let cacheOnly: MLXCacheParityReuseModeReport
  let cacheAndContinuationState: MLXCacheParityReuseModeReport?

  var passed: Bool {
    p1IsExactPrefixOfP2 && copyIsolation.passed
      && reuseRequirement != .noPassingReusePath
  }
}

nonisolated struct MLXCacheParityModelReport: Codable, Sendable {
  enum Status: String, Codable, Sendable {
    case passed
    case failed
    case skipped
  }

  let schemaVersion: Int
  let family: MLXCacheParityFamily
  let modelID: String?
  let modelDirectoryName: String?
  let buildConfiguration: String
  let status: Status
  let statusReason: String?
  let scenarios: [MLXCacheParityScenarioReport]
}

nonisolated enum MLXCacheParityHarnessError: Error, CustomStringConvertible {
  case promptIsNotExactPrefix(common: Int, p1Count: Int, p2Count: Int)
  case emptySuffix
  case continuationStateWasNotReproducible

  var description: String {
    switch self {
    case .promptIsNotExactPrefix(let common, let p1Count, let p2Count):
      "P1 is not an exact P2 token prefix (common: \(common), P1: \(p1Count), P2: \(p2Count))."
    case .emptySuffix:
      "P2 did not add any tokens after P1."
    case .continuationStateWasNotReproducible:
      "P1 produced continuation state once but not during the independent recomputation."
    }
  }
}

nonisolated enum MLXCacheParityEnvironment {
  static let enabled =
    ProcessInfo.processInfo.environment["SUMIKA_RUN_MLX_CACHE_PARITY"] == "1"

  static var reportDirectory: URL {
    let repositoryURL = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    guard
      let configuredPath = ProcessInfo.processInfo.environment[
        "SUMIKA_CACHE_PARITY_REPORT_DIR"
      ],
      !configuredPath.isEmpty
    else {
      return repositoryURL.appending(
        path: ".perf/cache-parity", directoryHint: .isDirectory)
    }
    if configuredPath.hasPrefix("/") {
      return URL(filePath: configuredPath, directoryHint: .isDirectory)
    }
    return repositoryURL.appending(path: configuredPath, directoryHint: .isDirectory)
  }

  static func selectedModel(for family: MLXCacheParityFamily) -> ManagedModel? {
    let environmentKey =
      switch family {
      case .gemma: "SUMIKA_CACHE_PARITY_GEMMA_MODEL_ID"
      case .qwen: "SUMIKA_CACHE_PARITY_QWEN_MODEL_ID"
      }
    if let requestedID = ProcessInfo.processInfo.environment[environmentKey],
      !requestedID.isEmpty
    {
      return ManagedModelCatalog.model(id: requestedID)
    }

    let preferredIDs =
      switch family {
      case .gemma:
        ["gemma4-e4b-qat-4bit", "gemma4-12b-qat-4bit"]
      case .qwen:
        [
          "qwen3.6-35b-a3b-4bit", "qwen3.6-35b-a3b-8bit",
          "qwen3.6-27B-4bit", "qwen3.6-27B-8bit",
        ]
      }

    return
      preferredIDs
      .compactMap(ManagedModelCatalog.model(id:))
      .first(where: isInstalled(_:))
  }

  static func isInstalled(_ model: ManagedModel) -> Bool {
    FileManager.default.fileExists(
      atPath: model.localDirectoryURL.appending(path: "config.json").path(percentEncoded: false)
    )
  }

  static func write(_ report: MLXCacheParityModelReport) throws {
    let directory = reportDirectory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    let fileURL = directory.appending(
      path: "\(report.family.rawValue)-cache-parity.json", directoryHint: .notDirectory)
    try data.write(to: fileURL, options: .atomic)
    print("MLX cache parity report: \(fileURL.path(percentEncoded: false))")
  }

  #if DEBUG
    static let buildConfiguration = "Debug"
  #else
    static let buildConfiguration = "Release"
  #endif
}

nonisolated enum MLXCacheParityHarness {
  private static let generatedTokenCount = 16
  private static let strictCopyRelativeTolerance = 0.0001
  private static let strictCopyAbsoluteTolerance = 0.00001
  private static let bfloat16RelativeTolerance = 0.001
  private static let bfloat16AbsoluteTolerance = 0.001
  private static let schemaVersion = 4

  static func skippedReport(
    family: MLXCacheParityFamily,
    reason: String
  ) -> MLXCacheParityModelReport {
    MLXCacheParityModelReport(
      schemaVersion: schemaVersion,
      family: family,
      modelID: nil,
      modelDirectoryName: nil,
      buildConfiguration: MLXCacheParityEnvironment.buildConfiguration,
      status: .skipped,
      statusReason: reason,
      scenarios: []
    )
  }

  static func failedReport(
    family: MLXCacheParityFamily,
    model: ManagedModel,
    error: any Error
  ) -> MLXCacheParityModelReport {
    MLXCacheParityModelReport(
      schemaVersion: schemaVersion,
      family: family,
      modelID: model.id,
      modelDirectoryName: model.localDirectoryName,
      buildConfiguration: MLXCacheParityEnvironment.buildConfiguration,
      status: .failed,
      statusReason: String(describing: error),
      scenarios: []
    )
  }

  static func run(
    family: MLXCacheParityFamily,
    model: ManagedModel
  ) async throws -> MLXCacheParityModelReport {
    let configuration = ModelConfiguration(directory: model.localDirectoryURL)
    let container =
      if model.supportsImageInput {
        try await VLMModelFactory.shared.loadContainer(
          from: LocalDownloader(),
          using: LocalTokenizerLoader(),
          configuration: configuration
        )
      } else {
        try await LLMModelFactory.shared.loadContainer(
          from: LocalDownloader(),
          using: LocalTokenizerLoader(),
          configuration: configuration
        )
      }

    let descriptors = scenarioDescriptors(for: family)
    let scenarios = try await container.perform(values: descriptors) { context, descriptors in
      var reports: [MLXCacheParityScenarioReport] = []
      reports.reserveCapacity(descriptors.count)
      for descriptor in descriptors {
        reports.append(try await runScenario(context: context, descriptor: descriptor))
      }
      return reports
    }
    let passed = scenarios.allSatisfy(\.passed)
    return MLXCacheParityModelReport(
      schemaVersion: schemaVersion,
      family: family,
      modelID: model.id,
      modelDirectoryName: model.localDirectoryName,
      buildConfiguration: MLXCacheParityEnvironment.buildConfiguration,
      status: passed ? .passed : .failed,
      statusReason: passed ? nil : "One or more cold/warm parity checks failed.",
      scenarios: scenarios
    )
  }

  private struct ScenarioDescriptor: Sendable {
    let name: String
    let userPrompt: String
    let expectedSlidingWindow: Int?
  }

  private struct RawPathResult {
    let executionKind: MLXCacheParityExecutionKind
    let executionDurationSeconds: Double
    let prefixRecomputationDurationSeconds: Double
    let processorPromptTokenCount: Int
    let rawFirstLogits: [Float]
    let processedFirstLogits: [Float]
    let tokens: [Int]
    let decodedText: String
    let reusedContinuationState: Bool
    let memoryBefore: MLXCacheParityMemorySnapshot
    let memoryAfter: MLXCacheParityMemorySnapshot
    let cacheAfter: [MLXCacheParityCacheLayer]

    var report: MLXCacheParityMeasuredPath {
      MLXCacheParityMeasuredPath(
        executionKind: executionKind,
        executionDurationSeconds: executionDurationSeconds,
        prefixRecomputationDurationSeconds: prefixRecomputationDurationSeconds,
        totalDurationSeconds: executionDurationSeconds + prefixRecomputationDurationSeconds,
        processorPromptTokenCount: processorPromptTokenCount,
        reusedContinuationState: reusedContinuationState,
        rawFirstLogitsSHA256: stableHash(floats: rawFirstLogits),
        processedFirstLogitsSHA256: stableHash(floats: processedFirstLogits),
        firstArgmaxSHA256: stableHash(integers: Array(tokens.prefix(1))),
        generatedTokenCount: tokens.count,
        first16TokenIDsSHA256: stableHash(integers: tokens),
        decodedTextSHA256: stableHash(data: Data(decodedText.utf8)),
        memoryBefore: memoryBefore,
        memoryAfter: memoryAfter,
        cacheAfter: cacheAfter
      )
    }
  }

  private struct CheckpointResult {
    let cache: [any KVCache]
    let output: LMOutput
    let durationSeconds: Double
  }

  private static func scenarioDescriptors(
    for family: MLXCacheParityFamily
  ) -> [ScenarioDescriptor] {
    let canonical = ScenarioDescriptor(
      name: "structured-tool-follow-up",
      userPrompt: "Inspect the local cache behavior for the requested file.",
      expectedSlidingWindow: nil
    )
    switch family {
    case .gemma:
      let longContext = Array(repeating: "prefix-window-token", count: 620)
        .joined(separator: " ")
      return [
        canonical,
        ScenarioDescriptor(
          name: "structured-tool-follow-up-beyond-sliding-window",
          userPrompt: "Inspect the local cache behavior. \(longContext)",
          expectedSlidingWindow: 512
        ),
      ]
    case .qwen:
      return [canonical]
    }
  }

  nonisolated private static func runScenario(
    context: ModelContext,
    descriptor: ScenarioDescriptor
  ) async throws -> MLXCacheParityScenarioReport {
    let toolCallID = "cache-parity-call-1"
    let toolSpec: ToolSpec = [
      "type": "function",
      "function": [
        "name": "read_file",
        "description": "Read a UTF-8 text file from the local workspace.",
        "parameters": [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Workspace-relative path"]
              as [String: any Sendable]
          ] as [String: any Sendable],
          "required": ["path"],
          "additionalProperties": false,
        ] as [String: any Sendable],
      ] as [String: any Sendable],
    ]
    let p1Messages: [Chat.Message] = [
      .system("You are a local coding assistant. Use tools when needed."),
      .user(descriptor.userPrompt),
    ]
    let toolCall = MLXLMCommon.ToolCall(
      function: .init(name: "read_file", arguments: ["path": "Sources/App.swift"]),
      id: toolCallID
    )
    let p2Messages =
      p1Messages + [
        .assistant("", toolCalls: [toolCall]),
        .tool("The requested file contains a small Swift application.", id: toolCallID),
      ]
    let additionalContext: [String: any Sendable] = ["enable_thinking": false]
    let p1Input = try await context.processor.prepare(
      input: UserInput(
        chat: p1Messages, tools: [toolSpec], additionalContext: additionalContext))
    let p2Input = try await context.processor.prepare(
      input: UserInput(
        chat: p2Messages, tools: [toolSpec], additionalContext: additionalContext))

    p1Input.text.tokens.eval()
    p2Input.text.tokens.eval()
    let p1Tokens = p1Input.text.tokens.asArray(Int.self)
    let p2Tokens = p2Input.text.tokens.asArray(Int.self)
    let prefix = MLXTokenPrefixAnalysis(prefix: p1Tokens, full: p2Tokens)
    guard prefix.isExactPrefix else {
      throw MLXCacheParityHarnessError.promptIsNotExactPrefix(
        common: prefix.commonPrefixCount,
        p1Count: p1Tokens.count,
        p2Count: p2Tokens.count
      )
    }
    guard !prefix.suffix.isEmpty else {
      throw MLXCacheParityHarnessError.emptySuffix
    }

    let parameters = GenerateParameters(
      maxTokens: generatedTokenCount,
      temperature: 0,
      repetitionPenalty: 1.05,
      repetitionContextSize: 64,
      presencePenalty: 0.1,
      presenceContextSize: 64,
      prefillStepSize: 512
    )
    Memory.peakMemory = 0
    let checkpointMemoryBefore = MLXCacheParityMemorySnapshot(Memory.snapshot())
    let checkpoint = try makeCheckpoint(
      input: p1Input,
      model: context.model,
      parameters: parameters
    )
    let checkpointMemoryAfter = MLXCacheParityMemorySnapshot(Memory.snapshot())
    let originalOffsetsBeforeCopies = checkpoint.cache.map(\.offset)
    let originalStateSHA256BeforeCopies = cacheStateHashes(checkpoint.cache)

    let copiedCacheOnly = checkpoint.cache.map { $0.copy() }
    var copiedCaches = [copiedCacheOnly]
    let copiedCacheAndState = checkpoint.output.state.map { _ in
      checkpoint.cache.map { $0.copy() }
    }
    if let copiedCacheAndState {
      copiedCaches.append(copiedCacheAndState)
    }
    eval(copiedCaches.flatMap { $0.flatMap(\.state) })
    let copiedOffsetsBeforeWarmRuns = copiedCaches.map { $0.map(\.offset) }
    let copiedStateSHA256BeforeWarmRuns = copiedCaches.map(cacheStateHashes(_:))
    let originalOffsetsAfterCopies = checkpoint.cache.map(\.offset)
    let originalStateSHA256AfterCopies = cacheStateHashes(checkpoint.cache)
    let checkpointCopyCount = copiedCaches.count
    let checkpointCopiesMemoryAfter = MLXCacheParityMemorySnapshot(Memory.snapshot())
    let checkpointCopiesMemoryDelta = MLXCacheParityMemoryDelta(
      baseline: checkpointMemoryAfter,
      current: checkpointCopiesMemoryAfter
    )
    let perCopyActiveAndCacheMemoryBytes =
      Double(checkpointCopiesMemoryDelta.activeAndCacheMemoryBytes)
      / Double(checkpointCopyCount)
    let checkpointLayerReport = cacheReport(checkpoint.cache)
    let copiedCheckpointLayerReport = cacheReport(copiedCacheOnly)

    let fullCold = try measuredFullPromptPath(
      input: p2Input,
      fullPromptTokens: p2Tokens,
      model: context.model,
      tokenizer: context.tokenizer,
      cache: context.model.newCache(parameters: parameters),
      parameters: parameters
    )
    let suffixInput = LMInput.Text(tokens: MLXArray(prefix.suffix))

    let freshCacheOnlyCheckpoint = try makeCheckpoint(
      input: p1Input,
      model: context.model,
      parameters: parameters
    )
    let freshCacheOnly = try measuredDirectSuffixPath(
      suffix: suffixInput,
      fullPromptTokens: p2Tokens,
      model: context.model,
      tokenizer: context.tokenizer,
      cache: freshCacheOnlyCheckpoint.cache,
      parameters: parameters,
      continuationState: nil,
      prefixRecomputationDurationSeconds: freshCacheOnlyCheckpoint.durationSeconds
    )
    let copiedWarmCacheOnly = try measuredDirectSuffixPath(
      suffix: suffixInput,
      fullPromptTokens: p2Tokens,
      model: context.model,
      tokenizer: context.tokenizer,
      cache: copiedCacheOnly,
      parameters: parameters,
      continuationState: nil,
      prefixRecomputationDurationSeconds: 0
    )
    let cacheOnly = reuseModeReport(
      fullCold: fullCold,
      freshSplit: freshCacheOnly,
      copiedWarm: copiedWarmCacheOnly
    )

    let cacheAndContinuationState: MLXCacheParityReuseModeReport?
    if let originalContinuationState = checkpoint.output.state,
      let copiedCacheAndState
    {
      let freshStateCheckpoint = try makeCheckpoint(
        input: p1Input,
        model: context.model,
        parameters: parameters
      )
      guard let freshContinuationState = freshStateCheckpoint.output.state else {
        throw MLXCacheParityHarnessError.continuationStateWasNotReproducible
      }
      let freshState = try measuredDirectSuffixPath(
        suffix: suffixInput,
        fullPromptTokens: p2Tokens,
        model: context.model,
        tokenizer: context.tokenizer,
        cache: freshStateCheckpoint.cache,
        parameters: parameters,
        continuationState: freshContinuationState,
        prefixRecomputationDurationSeconds: freshStateCheckpoint.durationSeconds
      )
      let copiedWarmState = try measuredDirectSuffixPath(
        suffix: suffixInput,
        fullPromptTokens: p2Tokens,
        model: context.model,
        tokenizer: context.tokenizer,
        cache: copiedCacheAndState,
        parameters: parameters,
        continuationState: originalContinuationState,
        prefixRecomputationDurationSeconds: 0
      )
      cacheAndContinuationState = reuseModeReport(
        fullCold: fullCold,
        freshSplit: freshState,
        copiedWarm: copiedWarmState
      )
    } else {
      cacheAndContinuationState = nil
    }

    let originalOffsetsAfterWarmRuns = checkpoint.cache.map(\.offset)
    let originalStateSHA256AfterWarmRuns = cacheStateHashes(checkpoint.cache)
    let copiedCachesMatchOriginalBeforeWarmRuns =
      copiedOffsetsBeforeWarmRuns.allSatisfy { $0 == originalOffsetsBeforeCopies }
      && copiedStateSHA256BeforeWarmRuns.allSatisfy {
        $0 == originalStateSHA256BeforeCopies
      }
    let copiedCachesAdvanced = zip(copiedCaches, copiedOffsetsBeforeWarmRuns)
      .allSatisfy { cache, offsetsBefore in cache.map(\.offset) != offsetsBefore }
    let originalOffsetsUnchanged =
      originalOffsetsAfterCopies == originalOffsetsBeforeCopies
      && originalOffsetsAfterWarmRuns == originalOffsetsBeforeCopies
    let originalStateUnchanged =
      originalStateSHA256AfterCopies == originalStateSHA256BeforeCopies
      && originalStateSHA256AfterWarmRuns == originalStateSHA256BeforeCopies
    let copyIsolation = MLXCacheParityCopyIsolation(
      originalOffsetsBeforeCopies: originalOffsetsBeforeCopies,
      originalOffsetsAfterCopies: originalOffsetsAfterCopies,
      originalOffsetsAfterWarmRuns: originalOffsetsAfterWarmRuns,
      originalStateSHA256BeforeCopies: originalStateSHA256BeforeCopies,
      originalStateSHA256AfterCopies: originalStateSHA256AfterCopies,
      originalStateSHA256AfterWarmRuns: originalStateSHA256AfterWarmRuns,
      copiedStateSHA256BeforeWarmRuns: copiedStateSHA256BeforeWarmRuns,
      copiedCachesMatchOriginalBeforeWarmRuns: copiedCachesMatchOriginalBeforeWarmRuns,
      copiedCachesAdvanced: copiedCachesAdvanced,
      originalOffsetsUnchanged: originalOffsetsUnchanged,
      originalStateUnchanged: originalStateUnchanged,
      passed: copiedCachesMatchOriginalBeforeWarmRuns && copiedCachesAdvanced
        && originalOffsetsUnchanged && originalStateUnchanged
    )
    let reuseRequirement: MLXCacheReuseRequirement =
      if cacheOnly.reuseParityPassed {
        .cacheOnly
      } else if cacheAndContinuationState?.reuseParityPassed == true {
        .cacheAndContinuationState
      } else {
        .noPassingReusePath
      }

    return MLXCacheParityScenarioReport(
      name: descriptor.name,
      p1TokenCount: p1Tokens.count,
      p2TokenCount: p2Tokens.count,
      commonPrefixTokenCount: prefix.commonPrefixCount,
      suffixTokenCount: prefix.suffix.count,
      p1IsExactPrefixOfP2: prefix.isExactPrefix,
      exceedsExpectedSlidingWindow: descriptor.expectedSlidingWindow.map {
        p1Tokens.count > $0
      } ?? false,
      continuationStateProducedByP1: checkpoint.output.state != nil,
      checkpointDurationSeconds: checkpoint.durationSeconds,
      checkpointMemoryBefore: checkpointMemoryBefore,
      checkpointMemoryAfter: checkpointMemoryAfter,
      checkpointCopyCount: checkpointCopyCount,
      checkpointCopiesMemoryAfter: checkpointCopiesMemoryAfter,
      checkpointCopiesMemoryDelta: checkpointCopiesMemoryDelta,
      perCopyActiveAndCacheMemoryBytes: perCopyActiveAndCacheMemoryBytes,
      checkpointCache: checkpointLayerReport,
      copiedCheckpointCache: copiedCheckpointLayerReport,
      copyIsolation: copyIsolation,
      reuseRequirement: reuseRequirement,
      fullCold: fullCold.report,
      cacheOnly: cacheOnly,
      cacheAndContinuationState: cacheAndContinuationState
    )
  }

  nonisolated private static func makeCheckpoint(
    input: LMInput,
    model: any LanguageModel,
    parameters: GenerateParameters
  ) throws -> CheckpointResult {
    let cache = model.newCache(parameters: parameters)
    let startedAt = Date.timeIntervalSinceReferenceDate
    let output = try consumePrompt(
      input,
      model: model,
      cache: cache,
      windowSize: parameters.prefillStepSize
    )
    eval(output.logits, cache.flatMap(\.state))
    return CheckpointResult(
      cache: cache,
      output: output,
      durationSeconds: Date.timeIntervalSinceReferenceDate - startedAt
    )
  }

  nonisolated private static func measuredFullPromptPath(
    input: LMInput,
    fullPromptTokens: [Int],
    model: any LanguageModel,
    tokenizer: any Tokenizer,
    cache: [any KVCache],
    parameters: GenerateParameters
  ) throws -> RawPathResult {
    try measuredPath(
      executionKind: .fullPrompt,
      fullPromptTokens: fullPromptTokens,
      model: model,
      tokenizer: tokenizer,
      cache: cache,
      parameters: parameters,
      continuationState: nil,
      prefixRecomputationDurationSeconds: 0
    ) {
      try consumePrompt(
        input,
        model: model,
        cache: cache,
        windowSize: parameters.prefillStepSize
      )
    }
  }

  /// Cache-only and cache-plus-state paths deliberately share this exact
  /// suffix execution function. The optional continuation state is their only
  /// model-input difference.
  nonisolated private static func measuredDirectSuffixPath(
    suffix: LMInput.Text,
    fullPromptTokens: [Int],
    model: any LanguageModel,
    tokenizer: any Tokenizer,
    cache: [any KVCache],
    parameters: GenerateParameters,
    continuationState: LMOutput.State?,
    prefixRecomputationDurationSeconds: Double
  ) throws -> RawPathResult {
    measuredPath(
      executionKind: .directSuffix,
      fullPromptTokens: fullPromptTokens,
      model: model,
      tokenizer: tokenizer,
      cache: cache,
      parameters: parameters,
      continuationState: continuationState,
      prefixRecomputationDurationSeconds: prefixRecomputationDurationSeconds
    ) {
      consumeSuffix(
        suffix,
        model: model,
        cache: cache,
        continuationState: continuationState
      )
    }
  }

  nonisolated private static func measuredPath(
    executionKind: MLXCacheParityExecutionKind,
    fullPromptTokens: [Int],
    model: any LanguageModel,
    tokenizer: any Tokenizer,
    cache: [any KVCache],
    parameters: GenerateParameters,
    continuationState: LMOutput.State?,
    prefixRecomputationDurationSeconds: Double,
    initialOutput: () throws -> LMOutput
  ) rethrows -> RawPathResult {
    Memory.peakMemory = 0
    let memoryBefore = MLXCacheParityMemorySnapshot(Memory.snapshot())
    let startedAt = Date.timeIntervalSinceReferenceDate
    var processor: any LogitProcessor = MLXFullPromptLogitProcessor(
      base: parameters.processor(),
      fullPrompt: MLXArray(fullPromptTokens)
    )
    processor.prompt(MLXArray(fullPromptTokens))
    var output = try initialOutput()
    var state = output.state
    let rawFirstLogits = output.logits[0..., -1, 0...].asType(DType.float32)
    var processedLogits = processor.process(logits: output.logits[0..., -1, 0...])
    let processedFirstLogits = processedLogits.asType(DType.float32)
    var token = argMax(processedLogits, axis: -1)
    processor.didSample(token: token)
    eval(rawFirstLogits, processedFirstLogits, token)

    var generatedTokens = [token.item(Int.self)]
    while generatedTokens.count < generatedTokenCount {
      let previous = LMInput.Text(tokens: token)
      output = withPreparedCache(cache, lengths: previous.sequenceLengths) {
        model(
          previous[text: MLXNewAxisIndex.newAxis],
          cache: cache.isEmpty ? nil : cache,
          state: state
        )
      }
      state = output.state
      processedLogits = processor.process(logits: output.logits[0..., -1, 0...])
      token = argMax(processedLogits, axis: -1)
      processor.didSample(token: token)
      eval(token)
      generatedTokens.append(token.item(Int.self))
    }
    eval(cache.flatMap(\.state))
    let duration = Date.timeIntervalSinceReferenceDate - startedAt
    let memoryAfter = MLXCacheParityMemorySnapshot(Memory.snapshot())
    return RawPathResult(
      executionKind: executionKind,
      executionDurationSeconds: duration,
      prefixRecomputationDurationSeconds: prefixRecomputationDurationSeconds,
      processorPromptTokenCount: fullPromptTokens.count,
      rawFirstLogits: rawFirstLogits.asArray(Float.self),
      processedFirstLogits: processedFirstLogits.asArray(Float.self),
      tokens: generatedTokens,
      decodedText: tokenizer.decode(tokenIds: generatedTokens),
      reusedContinuationState: continuationState != nil,
      memoryBefore: memoryBefore,
      memoryAfter: memoryAfter,
      cacheAfter: cacheReport(cache)
    )
  }

  nonisolated private static func reuseModeReport(
    fullCold: RawPathResult,
    freshSplit: RawPathResult,
    copiedWarm: RawPathResult
  ) -> MLXCacheParityReuseModeReport {
    let freshSplitVsCopiedWarm = comparison(
      reference: freshSplit,
      candidate: copiedWarm,
      relativeTolerance: strictCopyRelativeTolerance,
      absoluteTolerance: strictCopyAbsoluteTolerance
    )
    let fullColdVsFreshSplit = comparison(
      reference: fullCold,
      candidate: freshSplit,
      relativeTolerance: bfloat16RelativeTolerance,
      absoluteTolerance: bfloat16AbsoluteTolerance
    )
    let fullColdVsCopiedWarm = comparison(
      reference: fullCold,
      candidate: copiedWarm,
      relativeTolerance: bfloat16RelativeTolerance,
      absoluteTolerance: bfloat16AbsoluteTolerance
    )
    let finalCacheParity = freshSplit.cacheAfter == copiedWarm.cacheAfter
    let strictCopyParityPassed =
      freshSplitVsCopiedWarm.rawFirstLogits.allClose
      && freshSplitVsCopiedWarm.behavior.passed
      && finalCacheParity
    let fullColdBehavioralParityPassed =
      fullColdVsFreshSplit.behavior.passed
      && fullColdVsCopiedWarm.behavior.passed
    return MLXCacheParityReuseModeReport(
      freshSplit: freshSplit.report,
      copiedWarm: copiedWarm.report,
      freshSplitVsCopiedWarm: freshSplitVsCopiedWarm,
      fullColdVsFreshSplit: fullColdVsFreshSplit,
      fullColdVsCopiedWarm: fullColdVsCopiedWarm,
      finalCacheParity: finalCacheParity,
      strictCopyParityPassed: strictCopyParityPassed,
      fullColdBehavioralParityPassed: fullColdBehavioralParityPassed,
      reuseParityPassed: strictCopyParityPassed && fullColdBehavioralParityPassed
    )
  }

  nonisolated private static func comparison(
    reference: RawPathResult,
    candidate: RawPathResult,
    relativeTolerance: Double,
    absoluteTolerance: Double
  ) -> MLXCacheParityComparison {
    let rawFirstLogits = logitComparison(
      reference: reference.rawFirstLogits,
      candidate: candidate.rawFirstLogits,
      relativeTolerance: relativeTolerance,
      absoluteTolerance: absoluteTolerance
    )
    let processedFirstLogits = logitComparison(
      reference: reference.processedFirstLogits,
      candidate: candidate.processedFirstLogits,
      relativeTolerance: relativeTolerance,
      absoluteTolerance: absoluteTolerance
    )
    let behavior = MLXCacheParityBehaviorComparison(
      argmaxParity: reference.tokens.first == candidate.tokens.first,
      first16TokenParity: reference.tokens == candidate.tokens,
      decodedTextParity: reference.decodedText == candidate.decodedText
    )
    return MLXCacheParityComparison(
      rawFirstLogits: rawFirstLogits,
      processedFirstLogits: processedFirstLogits,
      behavior: behavior,
      chunkingNumericalDrift: behavior.passed
        && (!rawFirstLogits.exactlyEqual || !processedFirstLogits.exactlyEqual)
    )
  }

  nonisolated private static func logitComparison(
    reference: [Float],
    candidate: [Float],
    relativeTolerance: Double,
    absoluteTolerance: Double
  ) -> MLXCacheParityLogitComparison {
    let logitsHaveEqualCounts = reference.count == candidate.count
    let pairs =
      logitsHaveEqualCounts
      ? zip(reference, candidate).map { (Double($0), Double($1)) }
      : []
    let absoluteDifferences = pairs.map { abs($0 - $1) }
    let maximumLogitDifference = absoluteDifferences.max()
    let meanAbsoluteDifference = mean(absoluteDifferences)
    let rootMeanSquareDifference = rootMeanSquare(pairs.map { $0 - $1 })
    let maximumAbsoluteMagnitude =
      pairs
      .flatMap { [abs($0), abs($1)] }
      .max()
    let referenceRootMeanSquare = rootMeanSquare(pairs.map(\.0))
    let normalizedMaximumDifference = normalized(
      maximumLogitDifference, by: maximumAbsoluteMagnitude)
    let normalizedRootMeanSquareDifference = normalized(
      rootMeanSquareDifference, by: referenceRootMeanSquare)
    let dotProduct = pairs.reduce(0.0) { $0 + ($1.0 * $1.1) }
    let referenceMagnitude = sqrt(pairs.reduce(0.0) { $0 + ($1.0 * $1.0) })
    let candidateMagnitude = sqrt(pairs.reduce(0.0) { $0 + ($1.1 * $1.1) })
    let cosineSimilarity = normalized(
      dotProduct, by: referenceMagnitude * candidateMagnitude)
    let exactlyEqual =
      logitsHaveEqualCounts
      && zip(reference, candidate).allSatisfy { $0.bitPattern == $1.bitPattern }
    let allClose =
      logitsHaveEqualCounts
      && pairs.allSatisfy { referenceValue, candidateValue in
        abs(referenceValue - candidateValue)
          <= absoluteTolerance + relativeTolerance * abs(referenceValue)
      }
    return MLXCacheParityLogitComparison(
      referenceCount: reference.count,
      candidateCount: candidate.count,
      relativeTolerance: relativeTolerance,
      absoluteTolerance: absoluteTolerance,
      exactlyEqual: exactlyEqual,
      allClose: allClose,
      maxAbsoluteDifference: maximumLogitDifference,
      meanAbsoluteDifference: meanAbsoluteDifference,
      rootMeanSquareDifference: rootMeanSquareDifference,
      maxAbsoluteMagnitude: maximumAbsoluteMagnitude,
      normalizedMaxDifference: normalizedMaximumDifference,
      normalizedRootMeanSquareDifference: normalizedRootMeanSquareDifference,
      cosineSimilarity: cosineSimilarity
    )
  }

  nonisolated private static func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else {
      return nil
    }
    return values.reduce(0, +) / Double(values.count)
  }

  nonisolated private static func rootMeanSquare(_ values: [Double]) -> Double? {
    guard !values.isEmpty else {
      return nil
    }
    return sqrt(values.reduce(0) { $0 + ($1 * $1) } / Double(values.count))
  }

  nonisolated private static func normalized(
    _ numerator: Double?,
    by denominator: Double?
  ) -> Double? {
    guard let numerator, let denominator, denominator > 0 else {
      return nil
    }
    return numerator / denominator
  }

  nonisolated private static func consumePrompt(
    _ input: LMInput,
    model: any LanguageModel,
    cache: [any KVCache],
    windowSize: Int?
  ) throws -> LMOutput {
    switch try model.prepare(input, cache: cache, windowSize: windowSize) {
    case .tokens(let tokens):
      return withPreparedCache(cache, lengths: tokens.sequenceLengths) {
        model(
          tokens[text: MLXNewAxisIndex.newAxis],
          cache: cache.isEmpty ? nil : cache,
          state: nil
        )
      }
    case .logits(let output):
      return output
    }
  }

  nonisolated private static func consumeSuffix(
    _ suffix: LMInput.Text,
    model: any LanguageModel,
    cache: [any KVCache],
    continuationState: LMOutput.State?
  ) -> LMOutput {
    withPreparedCache(cache, lengths: suffix.sequenceLengths) {
      model(
        suffix[text: MLXNewAxisIndex.newAxis],
        cache: cache.isEmpty ? nil : cache,
        state: continuationState
      )
    }
  }

  nonisolated private static func cacheReport(
    _ cache: [any KVCache]
  ) -> [MLXCacheParityCacheLayer] {
    let stateHashes = cacheStateHashes(cache)
    return cache.enumerated().map {
      MLXCacheParityCacheLayer(
        index: $0.offset,
        cache: $0.element,
        stateSHA256: stateHashes[$0.offset]
      )
    }
  }

  nonisolated private static func cacheStateHashes(
    _ cache: [any KVCache]
  ) -> [[String]] {
    cache.map { layer in
      let state = layer.state
      eval(state)
      return state.map(stableHash(array:))
    }
  }

  nonisolated private static func stableHash(array: MLXArray) -> String {
    stableHash(data: array.asData(access: .noCopyIfContiguous).data)
  }

  nonisolated private static func stableHash(integers: [Int]) -> String {
    var data = Data(capacity: integers.count * MemoryLayout<Int64>.size)
    for integer in integers {
      var value = Int64(integer).littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return stableHash(data: data)
  }

  nonisolated private static func stableHash(floats: [Float]) -> String {
    floats.withUnsafeBytes { buffer in
      stableHash(data: Data(buffer))
    }
  }

  nonisolated private static func stableHash(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
