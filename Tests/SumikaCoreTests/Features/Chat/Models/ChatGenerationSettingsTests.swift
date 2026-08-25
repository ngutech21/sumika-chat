import Foundation
import Testing

@testable import SumikaCore

struct ChatGenerationSettingsTests {
  @Test
  func minPDefaultsToDisabledAndPersistsOnlyWhenEnabled() throws {
    let legacyData = Data(
      """
      {
        "temperature": 0.2,
        "topP": 0.8,
        "topK": 10,
        "maxTokens": 256
      }
      """.utf8)

    let legacySettings = try JSONDecoder().decode(ChatGenerationSettings.self, from: legacyData)
    #expect(legacySettings.minP == 0)

    let legacyEncoding = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(legacySettings)) as? [String: Any]
    )
    #expect(legacyEncoding["minP"] == nil)

    var enabledSettings = legacySettings
    enabledSettings.minP = 0.1
    let decoded = try JSONDecoder().decode(
      ChatGenerationSettings.self,
      from: JSONEncoder().encode(enabledSettings)
    )
    #expect(decoded.minP == 0.1)
  }

  @Test
  func decodingMissingRepetitionPenaltyUsesNeutralDefault() throws {
    let data = Data(
      """
      {
        "temperature": 0.2,
        "topP": 0.8,
        "topK": 10,
        "maxTokens": 256
      }
      """.utf8)

    let settings = try JSONDecoder().decode(ChatGenerationSettings.self, from: data)

    #expect(settings.repetitionPenalty == 1)
  }

  @Test
  func encodeDecodeRoundTripPreservesRepetitionPenalty() throws {
    let settings = ChatGenerationSettings(
      temperature: 0.2,
      topP: 0.8,
      topK: 10,
      maxTokens: 256,
      repetitionPenalty: 1.15,
      repetitionContextSize: 128,
      presencePenalty: 0.7
    )

    let decoded = try JSONDecoder().decode(
      ChatGenerationSettings.self,
      from: JSONEncoder().encode(settings)
    )

    #expect(decoded == settings)
  }

  @Test
  func legacyMaxKVSizeIsNotPersistedAgain() throws {
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
    let encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
    )

    #expect(encoded["maxKVSize"] == nil)
  }

  @Test
  func decodingMissingPenaltyWindowFieldsUsesDefaults() throws {
    let data = Data(
      """
      {
        "temperature": 0.2,
        "topP": 0.8,
        "topK": 10,
        "maxTokens": 256
      }
      """.utf8)

    let settings = try JSONDecoder().decode(ChatGenerationSettings.self, from: data)

    #expect(settings.repetitionContextSize == 20)
    #expect(settings.presencePenalty == 0)
  }

  @Test
  func agentDefaultUsesLoopResistantSampling() {
    let agent = ChatGenerationSettings.agentDefault

    // Non-zero temperature so a looping small model is not locked into greedy repetition.
    #expect(agent.temperature > 0)
    #expect(agent.topP == 0.95)
    #expect(agent.topK == 64)
    // Penalty window must span more than a single tool call, and presence penalty on.
    #expect(agent.repetitionContextSize == 256)
    #expect(agent.presencePenalty > 0)

    // Chat mode stays vanilla (greedy-free but unpenalised).
    #expect(ChatGenerationSettings.chatDefault.presencePenalty == 0)
    #expect(ChatGenerationSettings.chatDefault.repetitionContextSize == 20)
  }
}
