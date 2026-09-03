import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif
@Suite()
struct MLXRuntimeConfigurationTests {
  @Test(arguments: [
    (16_384, 12_224, 2_048, 1_024, 4_096),
    (4_096, 512, 1_024, 512, 3_520),
    (4_096, 512, 2_048, 1_024, 3_520),
  ])
  func contextClampPreservesQwenThinkingAndAnswerBudgets(
    capacity: Int, promptTokens: Int, thinkingMaximum: Int,
    minimumAnswer: Int, expectedMaximum: Int
  ) throws {
    let original = GenerateParameters(maxTokens: 32_768)
    let components = try MLXThinkingBudgetPlanner.makeComponents(
      maximumTokenCount: thinkingMaximum, minimumAnswerTokenCount: minimumAnswer,
      reasoning: QwenReasoningProtocol.tagged,
      tokenizer: ThinkingBudgetTestTokenizer(),
      generateParameters: original,
      enforcementState: MLXThinkingBudgetEnforcementState()
    )
    let budget = MLXContextBudget(capacity: capacity, configuredMaximum: 32_768)
    var adjusted = original
    adjusted.maxTokens = try budget.measure(promptTokens: promptTokens)
    #expect(adjusted.maxTokens == expectedMaximum)
    try components.validate(parameters: adjusted)
    #expect(original.maxTokens == 32_768)
  }

  @Test(arguments: [(1_024, 512), (2_048, 1_024)])
  func contextReserveDoesNotBypassQwenThinkingAndAnswerBudgets(
    thinkingMaximum: Int, minimumAnswer: Int
  ) throws {
    let original = GenerateParameters(maxTokens: 32_768)
    let components = try MLXThinkingBudgetPlanner.makeComponents(
      maximumTokenCount: thinkingMaximum, minimumAnswerTokenCount: minimumAnswer,
      reasoning: QwenReasoningProtocol.tagged,
      tokenizer: ThinkingBudgetTestTokenizer(),
      generateParameters: original,
      enforcementState: MLXThinkingBudgetEnforcementState()
    )
    let budget = MLXContextBudget(capacity: 4_096, configuredMaximum: 32_768)
    var adjusted = original
    adjusted.maxTokens = try budget.measure(promptTokens: 3_008)
    #expect(adjusted.maxTokens == 1_024)
    do {
      try components.validate(parameters: adjusted)
      Issue.record("Expected insufficient space for Qwen thinking and answer budgets")
    } catch ThinkingBudgetError.insufficientGenerationTokenLimit(let required, let actual) {
      #expect(required > thinkingMaximum + minimumAnswer)
      #expect(actual == 1_024)
    }
    #expect(original.maxTokens == 32_768)
  }

  @Test
  func allQwenCatalogEntriesEnableThinkingBudget() throws {
    let qwenModels = ManagedModelCatalog.models.filter {
      $0.reasoningTraceFormat == .qwenThinkTags
    }
    let gemma = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))

    #expect(!qwenModels.isEmpty)
    #expect(qwenModels.allSatisfy { $0.thinkingBudgetPolicy == .hardLimitImmediate })
    #expect(gemma.thinkingBudgetPolicy == .unmanaged)
  }

  @Test
  func unsupportedThinkingBudgetMessageIsModelNeutral() {
    #expect(
      MLXThinkingBudgetFailure.unsupportedModel.errorDescription
        == "Hard thinking limits are not enabled for this model. Disable reasoning or select a model that supports hard thinking limits."
    )
  }

  @Test
  func qwenThinkingBudgetTraceUsesFixedPerInvocationModeLimits() {
    let chat = MLXThinkingBudgetPlanner.trace(
      policy: .hardLimitImmediate,
      reasoningEnabled: true,
      interactionMode: .chat
    )
    let agent = MLXThinkingBudgetPlanner.trace(
      policy: .hardLimitImmediate,
      reasoningEnabled: true,
      interactionMode: .agent
    )

    #expect(chat.maximumTokenCount == 1_024)
    #expect(chat.minimumAnswerTokenCount == 512)
    #expect(chat.transitionMode == .immediate)
    #expect(agent.maximumTokenCount == 2_048)
    #expect(agent.minimumAnswerTokenCount == 1_024)
    #expect(agent.transitionMode == .immediate)
  }

  @Test
  func everyReasoningLevelUsesTheSameBudgetIdentityPerMode() throws {
    let levels: [ReasoningSelection] = [
      .effort(.low),
      .effort(.medium),
      .effort(.xhigh),
    ]

    for mode in [WorkspaceInteractionMode.chat, .agent] {
      let traces = levels.map { selection in
        MLXThinkingBudgetPlanner.trace(
          policy: .hardLimitImmediate,
          reasoningEnabled: selection.isEnabled,
          interactionMode: mode
        )
      }
      let first = try #require(traces.first)

      #expect(traces.allSatisfy { $0 == first })
      switch mode {
      case .chat:
        #expect(first.maximumTokenCount == 1_024)
        #expect(first.minimumAnswerTokenCount == 512)
      case .agent:
        #expect(first.maximumTokenCount == 2_048)
        #expect(first.minimumAnswerTokenCount == 1_024)
      }
    }
  }

  @Test
  func reasoningOffLeavesQwenUnbudgetedAndUnsupportedQwenFailsPreflight() async throws {
    let tokenizer = ThinkingBudgetTestTokenizer()
    let state = MLXThinkingBudgetEnforcementState()
    let components = try MLXThinkingBudgetPlanner.makeComponents(
      maximumTokenCount: 1_024,
      minimumAnswerTokenCount: 512,
      reasoning: QwenReasoningProtocol.tagged,
      tokenizer: tokenizer,
      generateParameters: GenerateParameters(maxTokens: 1_540),
      enforcementState: state
    )
    try components.validate(parameters: GenerateParameters(maxTokens: 1_540))

    let disabledTrace = MLXThinkingBudgetPlanner.trace(
      policy: .unsupported,
      reasoningEnabled: false,
      interactionMode: .agent
    )
    let unsupportedTrace = MLXThinkingBudgetPlanner.trace(
      policy: .unsupported,
      reasoningEnabled: true,
      interactionMode: .agent
    )
    #expect(disabledTrace.validationStatus == .notApplied)
    #expect(unsupportedTrace.validationStatus == .rejected(.unsupportedModel))
  }

  @Test
  func thinkingBudgetFailsBeforeGenerationWhenAnswerHeadroomIsInsufficient() throws {
    let tokenizer = ThinkingBudgetTestTokenizer()
    let state = MLXThinkingBudgetEnforcementState()

    do {
      _ = try MLXThinkingBudgetPlanner.makeComponents(
        maximumTokenCount: 1_024,
        minimumAnswerTokenCount: 512,
        reasoning: QwenReasoningProtocol.tagged,
        tokenizer: tokenizer,
        generateParameters: GenerateParameters(maxTokens: 1_000),
        enforcementState: state
      )
      Issue.record("Expected insufficient generation headroom to fail preflight.")
    } catch {
      guard
        case .configurationFailure(.insufficientGenerationTokenLimit) =
          MLXThinkingBudgetPlanner.diagnostic(for: error)
      else {
        Issue.record("Expected insufficient generation token limit diagnostic.")
        return
      }
    }
  }

  @Test
  func neutralRepetitionPenaltyDoesNotEnableMLXProcessor() {
    #expect(MLXChatRuntime.mlxRepetitionPenalty(from: .agentDefault) == nil)

    var settings = ChatGenerationSettings.agentDefault
    settings.repetitionPenalty = 1.15

    #expect(MLXChatRuntime.mlxRepetitionPenalty(from: settings) == 1.15)
  }

  @Test
  func minPFlowsIntoMLXGenerationParameters() {
    var settings = ChatGenerationSettings.chatDefault
    settings.minP = 0.08

    let parameters = MLXChatRuntime.generateParameters(from: settings)

    #expect(parameters.minP == 0.08)
  }

  @Test
  func legacyMaxKVSizeDoesNotLimitMLXGeneration() throws {
    let data = Data(
      """
      {
        "temperature": 0.2,
        "topP": 0.8,
        "topK": 10,
        "maxTokens": 256,
        "maxKVSize": 4096
      }
      """.utf8)
    let settings = try JSONDecoder().decode(ChatGenerationSettings.self, from: data)

    let parameters = MLXChatRuntime.generateParameters(from: settings)

    #expect(parameters.maxKVSize == nil)
  }

  @Test
  func chatSessionMediaProcessingDelegatesSizingToModelProcessor() {
    let processing = MLXChatRuntime.modelNativeMediaProcessing

    #expect(processing.resize == nil)
    #expect(processing.minPixels == nil)
    #expect(processing.maxPixels == nil)
  }

  @Test
  func gemma4GenerationConfigFixtureCarriesEOTTokenID() throws {
    let data = Data(
      """
      {
        "eos_token_id": [1, 106, 50]
      }
      """.utf8)

    let generationConfig = try JSONDecoder().decode(GenerationConfigFile.self, from: data)
    var modelConfiguration = ModelConfiguration(directory: URL(filePath: "/tmp/gemma-4-fixture"))
    modelConfiguration.eosTokenIds = Set(generationConfig.eosTokenIds?.values ?? [])

    #expect(modelConfiguration.extraEOSTokens.isEmpty)
    #expect(modelConfiguration.eosTokenIds.contains(106))
  }

  @Test
  func productSourceDoesNotHardCodeModelStopTokens() throws {
    var repositoryURL = URL(filePath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(
      atPath: repositoryURL.appending(path: "Package.swift").path()
    ) {
      let parentURL = repositoryURL.deletingLastPathComponent()
      guard parentURL != repositoryURL else {
        Issue.record("Could not locate the package root from \(#filePath).")
        return
      }
      repositoryURL = parentURL
    }
    let searchedDirectories = [
      repositoryURL.appending(path: "Sources", directoryHint: .isDirectory),
      repositoryURL.appending(path: "sumika", directoryHint: .isDirectory),
    ]
    let forbiddenTokens = [
      "<end" + "_of_turn>",
      "<turn" + "|>",
      "<|" + "im_end" + "|>",
    ]

    var matches: [String] = []
    for directoryURL in searchedDirectories {
      guard
        let enumerator = FileManager.default.enumerator(
          at: directoryURL,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }
      for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        for token in forbiddenTokens where contents.contains(token) {
          matches.append("\(path): \(token)")
        }
      }
    }

    #expect(matches.isEmpty, "Model stop tokens must come from MLX/model config: \(matches)")
  }

}

private struct ThinkingBudgetTestTokenizer: Tokenizer {
  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    switch text {
    case "<think>": [1]
    case "</think>": [2]
    case "<tool_call>": [3]
    default: Array(text.utf8).map { 1_000 + Int($0) }
    }
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    tokenIds.map { id in
      switch id {
      case 1: "<think>"
      case 2: "</think>"
      case 3: "<tool_call>"
      default: String(UnicodeScalar(id - 1_000) ?? "?")
      }
    }.joined()
  }

  func convertTokenToId(_ token: String) -> Int? { nil }
  func convertIdToToken(_ id: Int) -> String? { nil }
  var bosToken: String? { nil }
  var eosToken: String? { nil }
  var unknownToken: String? { nil }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    []
  }
}
