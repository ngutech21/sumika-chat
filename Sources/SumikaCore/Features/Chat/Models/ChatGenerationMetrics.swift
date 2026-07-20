package struct ChatGenerationMetrics: Codable, Equatable, Sendable {
  package let generatedTokenCount: Int
  package let tokensPerSecond: Double
  package let durationMs: Double

  package init(generatedTokenCount: Int, tokensPerSecond: Double, durationMs: Double) {
    self.generatedTokenCount = generatedTokenCount
    self.tokensPerSecond = tokensPerSecond
    self.durationMs = durationMs
  }
}
