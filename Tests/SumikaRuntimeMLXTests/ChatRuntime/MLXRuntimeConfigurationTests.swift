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
