import Foundation

public struct ChatGenerationSettings: Codable, Equatable, Sendable {
  public var temperature: Double
  public var topP: Double
  public var topK: Int
  public var maxTokens: Int
  public var maxKVSize: Int?
  public var repetitionPenalty: Double
  /// How many recent tokens the repetition/presence penalties look back over.
  /// The MLX default of 20 is shorter than a single tool call, so it cannot see —
  /// and therefore cannot discourage — a repeated tool call. Agent mode widens it.
  public var repetitionContextSize: Int
  /// Additive penalty applied once to any token already seen in the penalty window.
  /// Preferred over a high repetition penalty for tool loops: it discourages repeated
  /// content without penalising the structural JSON tokens every tool call needs.
  public var presencePenalty: Double
  public var reasoningEnabled: Bool

  public init(
    temperature: Double,
    topP: Double,
    topK: Int,
    maxTokens: Int,
    maxKVSize: Int? = nil,
    repetitionPenalty: Double = 1,
    repetitionContextSize: Int = 20,
    presencePenalty: Double = 0,
    reasoningEnabled: Bool = true
  ) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.maxTokens = maxTokens
    self.maxKVSize = maxKVSize
    self.repetitionPenalty = repetitionPenalty
    self.repetitionContextSize = repetitionContextSize
    self.presencePenalty = presencePenalty
    self.reasoningEnabled = reasoningEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case temperature
    case topP
    case topK
    case maxTokens
    case maxKVSize
    case repetitionPenalty
    case repetitionContextSize
    case presencePenalty
    case reasoningEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    temperature = try container.decodeIfPresent(Double.self, forKey: .temperature, default: 1)
    topP = try container.decodeIfPresent(Double.self, forKey: .topP, default: 1)
    topK = try container.decodeIfPresent(Int.self, forKey: .topK, default: 0)
    maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens, default: 2048)
    maxKVSize = try container.decodeIfPresent(Int.self, forKey: .maxKVSize)
    repetitionPenalty = try container.decodeIfPresent(
      Double.self,
      forKey: .repetitionPenalty,
      default: 1
    )
    repetitionContextSize = try container.decodeIfPresent(
      Int.self,
      forKey: .repetitionContextSize,
      default: 20
    )
    presencePenalty = try container.decodeIfPresent(
      Double.self,
      forKey: .presencePenalty,
      default: 0
    )
    reasoningEnabled = try container.decodeIfPresent(
      Bool.self,
      forKey: .reasoningEnabled,
      default: true
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(temperature, forKey: .temperature)
    try container.encode(topP, forKey: .topP)
    try container.encode(topK, forKey: .topK)
    try container.encode(maxTokens, forKey: .maxTokens)
    try container.encodeIfPresent(maxKVSize, forKey: .maxKVSize)
    try container.encode(repetitionPenalty, forKey: .repetitionPenalty)
    try container.encode(repetitionContextSize, forKey: .repetitionContextSize)
    try container.encode(presencePenalty, forKey: .presencePenalty)
    try container.encode(reasoningEnabled, forKey: .reasoningEnabled)
  }

  public static let chatDefault = ChatGenerationSettings(
    temperature: 1,
    topP: 1,
    topK: 0,
    maxTokens: 2048,
    maxKVSize: nil
  )

  /// Agent-mode sampling is tuned to resist the tool-call loops small local models
  /// fall into. Temperature is non-zero (greedy/argmax makes a looping model repeat
  /// deterministically with no escape), a moderate presence penalty discourages
  /// re-emitting the same call, and the penalty window is widened to actually span a
  /// prior tool call. topP/topK match the Gemma generation_config recommendation.
  public static let agentDefault = ChatGenerationSettings(
    temperature: 0.3,
    topP: 0.95,
    topK: 64,
    maxTokens: 2048,
    maxKVSize: nil,
    repetitionContextSize: 256,
    presencePenalty: 0.5
  )
}
