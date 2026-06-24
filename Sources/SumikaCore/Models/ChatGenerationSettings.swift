import Foundation

public struct ChatGenerationSettings: Codable, Equatable, Sendable {
  public var temperature: Double
  public var topP: Double
  public var topK: Int
  public var maxTokens: Int
  public var maxKVSize: Int?
  public var repetitionPenalty: Double
  public var reasoningEnabled: Bool

  public init(
    temperature: Double,
    topP: Double,
    topK: Int,
    maxTokens: Int,
    maxKVSize: Int? = nil,
    repetitionPenalty: Double = 1,
    reasoningEnabled: Bool = true
  ) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.maxTokens = maxTokens
    self.maxKVSize = maxKVSize
    self.repetitionPenalty = repetitionPenalty
    self.reasoningEnabled = reasoningEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case temperature
    case topP
    case topK
    case maxTokens
    case maxKVSize
    case repetitionPenalty
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
    try container.encode(reasoningEnabled, forKey: .reasoningEnabled)
  }

  public static let chatDefault = ChatGenerationSettings(
    temperature: 1,
    topP: 1,
    topK: 0,
    maxTokens: 2048,
    maxKVSize: nil
  )

  public static let agentDefault = ChatGenerationSettings(
    temperature: 0,
    topP: 1,
    topK: 0,
    maxTokens: 2048,
    maxKVSize: nil
  )
}
