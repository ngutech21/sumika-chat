import Foundation

public struct ChatGenerationSettings: Codable, Equatable, Sendable {
  public var temperature: Double
  public var topP: Double
  public var topK: Int
  public var maxTokens: Int

  public static let codingDefault = ChatGenerationSettings(
    temperature: 0,
    topP: 1,
    topK: 0,
    maxTokens: 2048
  )
}
