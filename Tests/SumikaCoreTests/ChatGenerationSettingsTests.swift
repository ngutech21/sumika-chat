import Foundation
import Testing

@testable import SumikaCore

struct ChatGenerationSettingsTests {
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
      maxKVSize: 4096,
      repetitionPenalty: 1.15
    )

    let decoded = try JSONDecoder().decode(
      ChatGenerationSettings.self,
      from: JSONEncoder().encode(settings)
    )

    #expect(decoded == settings)
  }
}
