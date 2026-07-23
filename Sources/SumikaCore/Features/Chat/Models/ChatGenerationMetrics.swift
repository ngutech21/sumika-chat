package struct ChatGenerationMetrics: Codable, Equatable, Sendable {
  package let generatedTokenCount: Int
  package let tokensPerSecond: Double

  package init(generatedTokenCount: Int, tokensPerSecond: Double) {
    self.generatedTokenCount = generatedTokenCount
    self.tokensPerSecond = tokensPerSecond
  }
}
