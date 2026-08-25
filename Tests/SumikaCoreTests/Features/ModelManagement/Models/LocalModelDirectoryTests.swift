import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-local-model-directory-tests"))
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
    let modelDirectory = try scopedTemporaryDirectory().appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == nil)
  }

  @Test
  func readContextTokenLimitIgnoresBooleanValues() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      configJSON: #"{"max_position_embeddings":true,"text_config":{"max_seq_len":8192}}"#)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == 8192)
  }

  @Test
  func readGenerationConfigPresetReadsKnownSamplingKeys() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      generationConfigJSON: """
        {
          "temperature": 0.7,
          "top_p": 0.95,
          "top_k": 64,
          "min_p": 0.1,
          "repetition_penalty": 1.1,
          "presence_penalty": 1.5
        }
        """
    )

    let preset = try #require(LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory))

    #expect(preset.temperature == 0.7)
    #expect(preset.topP == 0.95)
    #expect(preset.topK == 64)
    #expect(preset.minP == 0.1)
    #expect(preset.repetitionPenalty == 1.1)
    #expect(preset.presencePenalty == 1.5)
  }

  @Test
  func readGenerationConfigPresetIgnoresInvalidFieldsIndividually() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      generationConfigJSON: """
        {
          "temperature": -1,
          "top_p": 0.9,
          "top_k": -20,
          "min_p": 2,
          "repetition_penalty": 0,
          "presence_penalty": 4
        }
        """
    )

    let preset = try #require(LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory))

    #expect(preset.temperature == nil)
    #expect(preset.topP == 0.9)
    #expect(preset.topK == nil)
    #expect(preset.minP == nil)
    #expect(preset.repetitionPenalty == nil)
    #expect(preset.presencePenalty == nil)
  }

  @Test
  func readGenerationConfigPresetIgnoresBooleanNumericFields() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      generationConfigJSON: """
        {
          "temperature": true,
          "top_p": 0.9,
          "top_k": false,
          "min_p": true,
          "repetition_penalty": true,
          "presence_penalty": false
        }
        """
    )

    let preset = try #require(LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory))

    #expect(preset.temperature == nil)
    #expect(preset.topP == 0.9)
    #expect(preset.topK == nil)
    #expect(preset.minP == nil)
    #expect(preset.repetitionPenalty == nil)
    #expect(preset.presencePenalty == nil)
  }

  @Test
  func readGenerationConfigPresetReturnsNilWhenNoSamplingKeysExist() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      generationConfigJSON: #"{"do_sample":true,"eos_token_id":1,"max_new_tokens":999}"#)

    #expect(LocalModelDirectory.readGenerationConfigPreset(from: modelDirectory) == nil)
  }

  @Test
  func generationConfigPresetAppliesOnlyPresentFields() {
    let preset = GenerationSettingsOverride(topP: 0.9, repetitionPenalty: 1.2)
    let settings = ChatGenerationSettings(
      temperature: 0.1,
      topP: 0.5,
      topK: 20,
      maxTokens: 512
    )

    let updated = preset.applying(to: settings)

    #expect(updated.temperature == 0.1)
    #expect(updated.topP == 0.9)
    #expect(updated.topK == 20)
    #expect(updated.maxTokens == 512)
    #expect(updated.repetitionPenalty == 1.2)
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
    let modelDirectory = try scopedTemporaryDirectory().appending(
      path: UUID().uuidString,
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
