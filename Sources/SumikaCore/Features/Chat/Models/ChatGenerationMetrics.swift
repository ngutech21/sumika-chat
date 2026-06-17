import Foundation

public struct ChatGenerationMetrics: Codable, Equatable, Sendable {
  public let generatedTokenCount: Int
  public let tokensPerSecond: Double
  public let durationMs: Double

  public init(generatedTokenCount: Int, tokensPerSecond: Double, durationMs: Double) {
    self.generatedTokenCount = generatedTokenCount
    self.tokensPerSecond = tokensPerSecond
    self.durationMs = durationMs
  }
}
