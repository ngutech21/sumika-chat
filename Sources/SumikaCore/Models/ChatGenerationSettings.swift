import Foundation

public struct ChatGenerationSettings: Codable, Equatable, Sendable {
  public var temperature: Double
  public var topP: Double
  public var topK: Int
  public var maxTokens: Int
  public var maxKVSize: Int?
  public var reasoningEnabled: Bool

  public init(
    temperature: Double,
    topP: Double,
    topK: Int,
    maxTokens: Int,
    maxKVSize: Int? = nil,
    reasoningEnabled: Bool = true
  ) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.maxTokens = maxTokens
    self.maxKVSize = maxKVSize
    self.reasoningEnabled = reasoningEnabled
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
