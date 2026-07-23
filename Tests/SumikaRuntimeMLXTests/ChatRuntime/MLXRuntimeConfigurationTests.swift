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
  func mlxToolCallFormatInferenceDocumentsGemmaAndQwenCoverage() {
    #expect(ToolCallFormat.infer(from: "gemma4_unified") == .gemma4)
    #expect(ToolCallFormat.infer(from: "qwen3_5") == .xmlFunction)
    #expect(ToolCallFormat.infer(from: "qwen3_5_moe") == .xmlFunction)
    #expect(ToolCallFormat.infer(from: "qwen3_next") == .xmlFunction)
    #expect(ToolCallFormat.infer(from: "qwen3") == nil)
    #expect(ToolCallFormat.infer(from: "qwen2") == nil)
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
