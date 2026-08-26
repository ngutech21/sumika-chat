package struct ChatGenerationSettings: Codable, Equatable, Sendable {
  package var temperature: Double
  package var topP: Double
  package var topK: Int
  package var minP: Double
  package var maxTokens: Int
  package var repetitionPenalty: Double
  /// How many recent tokens the repetition/presence penalties look back over.
  /// The MLX default of 20 is shorter than a single tool call, so it cannot see —
  /// and therefore cannot discourage — a repeated tool call. Agent mode widens it.
  package var repetitionContextSize: Int
  /// Additive penalty applied once to any token already seen in the penalty window.
  /// Preferred over a high repetition penalty for tool loops: it discourages repeated
  /// content without penalising the structural JSON tokens every tool call needs.
  package var presencePenalty: Double
  package var reasoningSelection: ReasoningSelection

  package var reasoningEnabled: Bool {
    reasoningSelection.isEnabled
  }

  package init(
    temperature: Double,
    topP: Double,
    topK: Int,
    maxTokens: Int,
    minP: Double = 0,
    repetitionPenalty: Double = 1,
    repetitionContextSize: Int = 20,
    presencePenalty: Double = 0,
    reasoningSelection: ReasoningSelection = .on
  ) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.minP = minP
    self.maxTokens = maxTokens
    self.repetitionPenalty = repetitionPenalty
    self.repetitionContextSize = repetitionContextSize
    self.presencePenalty = presencePenalty
    self.reasoningSelection = reasoningSelection
  }

  private enum CodingKeys: String, CodingKey {
    case temperature
    case topP
    case topK
    case minP
    case maxTokens
    case repetitionPenalty
    case repetitionContextSize
    case presencePenalty
    case reasoningSelection
    case reasoningEnabled
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    temperature = try container.decodeIfPresent(Double.self, forKey: .temperature, default: 1)
    topP = try container.decodeIfPresent(Double.self, forKey: .topP, default: 1)
    topK = try container.decodeIfPresent(Int.self, forKey: .topK, default: 0)
    minP = try container.decodeIfPresent(Double.self, forKey: .minP, default: 0)
    maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens, default: 2048)
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
    if let selection = try container.decodeIfPresent(
      ReasoningSelection.self,
      forKey: .reasoningSelection
    ) {
      reasoningSelection = selection
    } else {
      reasoningSelection =
        try container.decodeIfPresent(
          Bool.self,
          forKey: .reasoningEnabled,
          default: true
        ) ? .on : .off
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(temperature, forKey: .temperature)
    try container.encode(topP, forKey: .topP)
    try container.encode(topK, forKey: .topK)
    if minP != 0 {
      try container.encode(minP, forKey: .minP)
    }
    try container.encode(maxTokens, forKey: .maxTokens)
    try container.encode(repetitionPenalty, forKey: .repetitionPenalty)
    try container.encode(repetitionContextSize, forKey: .repetitionContextSize)
    try container.encode(presencePenalty, forKey: .presencePenalty)
    try container.encode(reasoningSelection, forKey: .reasoningSelection)
  }

  package static let chatDefault = ChatGenerationSettings(
    temperature: 1,
    topP: 1,
    topK: 0,
    maxTokens: 2048
  )

  /// The app fallback for agent mode keeps a non-zero temperature, a moderate presence
  /// penalty, and a wider penalty window to reduce deterministic tool-call loops. Model
  /// configuration and family profiles may replace individual sampling fields.
  package static let agentDefault = ChatGenerationSettings(
    temperature: 0.3,
    topP: 0.95,
    topK: 64,
    maxTokens: 8192,
    repetitionContextSize: 256,
    presencePenalty: 0.5
  )
}
