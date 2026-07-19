import Foundation
import Testing

@testable import SumikaCore

struct LocalModelDirectoryTests {
  @Test
  func readContextTokenLimitReadsKnownTopLevelKeys() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      configJSON: #"{"max_position_embeddings":4096}"#)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == 4096)
  }

  @Test
  func readContextTokenLimitReadsNestedKnownKeys() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      configJSON: #"{"text_config":{"max_seq_len":8192}}"#)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == 8192)
  }

  @Test
  func readContextTokenLimitReturnsNilForMissingConfig() throws {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "sumika-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == nil)
  }

  @Test
  func readGenerationConfigPresetReadsKnownSamplingKeys() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      generationConfigJSON: """
        {
          "temperature": 0.7,
          "top_p": 0.95,
          "top_k": 64,
          "repetition_penalty": 1.1
        }
        """
    )

    let preset = try #require(LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory))

    #expect(preset.temperature == 0.7)
    #expect(preset.topP == 0.95)
    #expect(preset.topK == 64)
    #expect(preset.repetitionPenalty == 1.1)
  }

  @Test
  func readGenerationConfigPresetReturnsNilWhenNoSamplingKeysExist() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      generationConfigJSON: #"{"do_sample":true}"#)

    #expect(LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory) == nil)
  }

  @Test
  func generationConfigPresetAppliesOnlyPresentFields() {
    let preset = ChatGenerationConfigPreset(topP: 0.9, repetitionPenalty: 1.2)
    let settings = ChatGenerationSettings(
      temperature: 0.1,
      topP: 0.5,
      topK: 20,
      maxTokens: 512,
      maxKVSize: 4096
    )

    let updated = preset.applying(to: settings)

    #expect(updated.temperature == 0.1)
    #expect(updated.topP == 0.9)
    #expect(updated.topK == 20)
    #expect(updated.maxTokens == 512)
    #expect(updated.maxKVSize == 4096)
    #expect(updated.repetitionPenalty == 1.2)
  }

  @Test
  func applyingGenerationConfigPresetLayersChatFullyButKeepsAgentTemperature() {
    // Mirrors the Gemma generation_config.json (temp 1.0, top_k 64, top_p 0.95).
    let preset = ChatGenerationConfigPreset(temperature: 1.0, topP: 0.95, topK: 64)

    let updated = ModelSettingsStore.applyingGenerationConfigPreset(
      preset,
      to: .defaultSettings
    )

    // Chat adopts the model's full recommended sampling.
    #expect(updated.chat.generationSettings.temperature == 1.0)
    #expect(updated.chat.generationSettings.topP == 0.95)
    #expect(updated.chat.generationSettings.topK == 64)

    // Agent keeps its conservative temperature but adopts the model's nucleus/top-k shape.
    #expect(
      updated.agent.generationSettings.temperature
        == ChatGenerationSettings.agentDefault.temperature)
    #expect(updated.agent.generationSettings.topP == 0.95)
    #expect(updated.agent.generationSettings.topK == 64)
    #expect(
      updated.agent.generationSettings.presencePenalty
        == ChatGenerationSettings.agentDefault.presencePenalty)
  }

  @Test
  func applyingGenerationConfigPresetIsNoOpWhenPresetMissing() {
    #expect(
      ModelSettingsStore.applyingGenerationConfigPreset(nil, to: .defaultSettings)
        == ChatModeSettingsSet.defaultSettings)
  }

  private func makeTemporaryModelDirectory(configJSON: String) throws -> URL {
    try makeTemporaryModelDirectory(configJSON: configJSON, generationConfigJSON: nil)
  }

  private func makeTemporaryModelDirectory(generationConfigJSON: String) throws -> URL {
    try makeTemporaryModelDirectory(configJSON: nil, generationConfigJSON: generationConfigJSON)
  }

  private func makeTemporaryModelDirectory(
    configJSON: String?,
    generationConfigJSON: String?
  ) throws -> URL {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "sumika-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    if let configJSON {
      let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
      try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
    }
    if let generationConfigJSON {
      let configURL = modelDirectory.appending(
        path: "generation_config.json",
        directoryHint: .notDirectory
      )
      try generationConfigJSON.write(to: configURL, atomically: true, encoding: .utf8)
    }
    return modelDirectory
  }
}
