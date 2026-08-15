import Foundation

package enum ManagedModelStability: Equatable, Sendable {
  case stable
  case experimental
}

package enum ManagedModelGroup: CaseIterable, Equatable, Hashable, Sendable {
  case everydayChat
  case coding
  case specialized
}

package enum ManagedModelRecommendation: Equatable, Sendable {
  case standard
  case recommended
  case bestForGroup
}

package enum ReasoningTraceFormat: Equatable, Sendable {
  case none
  case gemmaChannel
  case qwenThinkTags
}

/// A chat-template reasoning effort persisted as a stable string.
package enum ReasoningEffort: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case low
  case medium
  case xhigh
}

/// The per-mode user selection. `.on` keeps binary reasoning models independent
/// from models that expose a concrete effort level.
package enum ReasoningSelection: Codable, Equatable, Hashable, Sendable {
  case off
  // swiftlint:disable:next identifier_name
  case on
  case effort(ReasoningEffort)

  package var isEnabled: Bool {
    self != .off
  }

  package var effort: ReasoningEffort? {
    guard case .effort(let effort) = self else {
      return nil
    }
    return effort
  }

  package var persistenceValue: String {
    switch self {
    case .off:
      "off"
    case .on:
      "on"
    case .effort(let effort):
      effort.rawValue
    }
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try? container.decode(String.self)
    switch value {
    case "off":
      self = .off
    case "on":
      self = .on
    case ReasoningEffort.low.rawValue:
      self = .effort(.low)
    case ReasoningEffort.medium.rawValue:
      self = .effort(.medium)
    case ReasoningEffort.xhigh.rawValue:
      self = .effort(.xhigh)
    default:
      // Model-aware normalization maps this legacy/default-on value to the
      // selected model's capability default.
      self = .on
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(persistenceValue)
  }
}

/// Catalog-owned reasoning controls. Selectable options are ordered for display.
package enum ModelReasoningCapability: Equatable, Sendable {
  case toggle
  case selectableEffort(supported: [ReasoningEffort], defaultValue: ReasoningEffort)

  package var defaultSelection: ReasoningSelection {
    switch self {
    case .toggle:
      .on
    case .selectableEffort(_, let defaultValue):
      .effort(defaultValue)
    }
  }

  package var hasValidOptions: Bool {
    switch self {
    case .toggle:
      true
    case .selectableEffort(let supported, let defaultValue):
      !supported.isEmpty
        && Set(supported).count == supported.count
        && supported.contains(defaultValue)
    }
  }

  package func resolving(_ selection: ReasoningSelection) -> ReasoningSelection {
    switch (self, selection) {
    case (.toggle, .off):
      .off
    case (.toggle, .on), (.toggle, .effort):
      .on
    case (.selectableEffort, .off):
      .off
    case (.selectableEffort(_, let defaultValue), .on):
      .effort(defaultValue)
    case (.selectableEffort(let supported, let defaultValue), .effort(let effort)):
      if supported.contains(effort) {
        .effort(effort)
      } else {
        .effort(defaultValue)
      }
    }
  }
}

/// Catalog-owned policy for hard thinking limits. This is runtime configuration,
/// not a persisted user setting.
package enum ThinkingBudgetPolicy: Equatable, Sendable {
  case unmanaged
  case unsupported
  case hardLimitImmediate
}

package struct ToolCallingPolicy: Equatable, Sendable {
  package var isEnabled: Bool
  package var allowsMultipleToolCalls: Bool

  package init(
    isEnabled: Bool,
    allowsMultipleToolCalls: Bool
  ) {
    self.isEnabled = isEnabled
    self.allowsMultipleToolCalls = allowsMultipleToolCalls
  }

  package static let nativeMLX = ToolCallingPolicy(
    isEnabled: true,
    allowsMultipleToolCalls: true
  )
}

package struct ManagedModel: Identifiable, Equatable, Sendable {
  package let id: String
  package let displayName: String
  package let detail: String
  package let huggingFaceRepoID: String
  package let localDirectoryName: String
  package let estimatedDownloadSize: String
  package let group: ManagedModelGroup
  package let recommendation: ManagedModelRecommendation
  package let requiresLargeMemory: Bool
  package let stability: ManagedModelStability
  package let toolCallingPolicy: ToolCallingPolicy
  package let supportsImageInput: Bool
  package let usesBundledMTPDrafter: Bool
  package let reasoningTraceFormat: ReasoningTraceFormat
  package let supportsHistoricalReasoningPreservation: Bool
  package let reasoningCapability: ModelReasoningCapability
  package let thinkingBudgetPolicy: ThinkingBudgetPolicy
  let generationProfile: ModelGenerationProfile?
  package let defaultModeSettings: ChatModeSettingsSet
  package let defaultContextTokenLimit: Int
  package let maxToolLoopIterations: Int

  init(
    id: String,
    displayName: String,
    detail: String,
    huggingFaceRepoID: String,
    localDirectoryName: String,
    estimatedDownloadSize: String,
    group: ManagedModelGroup,
    recommendation: ManagedModelRecommendation = .standard,
    requiresLargeMemory: Bool,
    stability: ManagedModelStability,
    toolCallingPolicy: ToolCallingPolicy = .nativeMLX,
    supportsImageInput: Bool,
    usesBundledMTPDrafter: Bool = false,
    reasoningTraceFormat: ReasoningTraceFormat = .none,
    supportsHistoricalReasoningPreservation: Bool = false,
    reasoningCapability: ModelReasoningCapability = .toggle,
    thinkingBudgetPolicy: ThinkingBudgetPolicy = .unmanaged,
    generationProfile: ModelGenerationProfile? = nil,
    defaultModeSettings: ChatModeSettingsSet,
    defaultContextTokenLimit: Int,
    maxToolLoopIterations: Int = 8
  ) {
    self.id = id
    self.displayName = displayName
    self.detail = detail
    self.huggingFaceRepoID = huggingFaceRepoID
    self.localDirectoryName = localDirectoryName
    self.estimatedDownloadSize = estimatedDownloadSize
    self.group = group
    self.recommendation = recommendation
    self.requiresLargeMemory = requiresLargeMemory
    self.stability = stability
    self.toolCallingPolicy = toolCallingPolicy
    self.supportsImageInput = supportsImageInput
    self.usesBundledMTPDrafter = usesBundledMTPDrafter
    self.reasoningTraceFormat = reasoningTraceFormat
    self.supportsHistoricalReasoningPreservation = supportsHistoricalReasoningPreservation
    precondition(reasoningCapability.hasValidOptions)
    self.reasoningCapability = reasoningCapability
    self.thinkingBudgetPolicy = thinkingBudgetPolicy
    self.generationProfile = generationProfile
    self.defaultModeSettings = defaultModeSettings
    self.defaultContextTokenLimit = defaultContextTokenLimit
    self.maxToolLoopIterations = maxToolLoopIterations
  }

  package var supportsWorkspaceTools: Bool {
    toolCallingPolicy.isEnabled
  }

  package var isRecommended: Bool {
    recommendation != .standard
  }

  package var localDirectoryURL: URL {
    LocalModelDirectory.defaultBaseURL.appending(
      path: localDirectoryName, directoryHint: .isDirectory)
  }

  package var localPath: String {
    localDirectoryURL.path(percentEncoded: false)
  }
}

package enum ManagedModelCatalog {
  package static let defaultModelID = "gemma4-12b-qat-4bit"
  package static let defaultContextTokenLimit = 16_384

  package static let models: [ManagedModel] = [
    ManagedModel(
      id: "gemma4-e4b-qat-4bit",
      displayName: "Gemma 4 E4B QAT 4-bit",
      detail: "Lightweight for everyday chat and images.",
      huggingFaceRepoID: "mlx-community/gemma-4-e4b-it-qat-4bit",
      localDirectoryName: "gemma-4-e4b-it-qat-4bit",
      estimatedDownloadSize: "6.8 GB",
      group: .everydayChat,
      requiresLargeMemory: false,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      generationProfile: .gemma4,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit
    ),
    ManagedModel(
      id: "gemma4-12b-qat-4bit",
      displayName: "Gemma 4 12B QAT 4-bit",
      detail: "Balanced for everyday chat, writing, and images.",
      huggingFaceRepoID: "mlx-community/gemma-4-12B-it-qat-4bit",
      localDirectoryName: "gemma-4-12B-it-qat-4bit",
      estimatedDownloadSize: "11.0 GB",
      group: .everydayChat,
      recommendation: .bestForGroup,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      generationProfile: .gemma4,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit
    ),
    ManagedModel(
      id: "gemma4-26b-qat-4bit",
      displayName: "Gemma 4 26B A4B QAT 4-bit",
      detail: "Strong for coding, complex tasks, and images.",
      huggingFaceRepoID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
      localDirectoryName: "gemma-4-26B-A4B-it-qat-4bit",
      estimatedDownloadSize: "15.6 GB",
      group: .coding,
      recommendation: .recommended,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      generationProfile: .gemma4,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit
    ),
    ManagedModel(
      id: "gemma4-31b-qat-4bit",
      displayName: "Gemma 4 31B QAT 4-bit",
      detail: "Largest Gemma for demanding coding and image tasks.",
      huggingFaceRepoID: "mlx-community/gemma-4-31B-it-qat-4bit",
      localDirectoryName: "gemma-4-31b-qat-4bit",
      estimatedDownloadSize: "28.8 GB",
      group: .coding,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      generationProfile: .gemma4,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),

    ManagedModel(
      id: "qwen3.6-35b-a3b-4bit",
      displayName: "Qwen 3.6 35B A3B 4-bit",
      detail: "For coding and images. Prefer OptiQ for text-only work.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-35B-A3B-4bit",
      localDirectoryName: "Qwen3.6-35B-A3B-4bit",
      estimatedDownloadSize: "20.4 GB",
      group: .coding,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen36,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
    ManagedModel(
      id: "qwen3.6-35b-a3b-optiq-4bit",
      displayName: "Qwen 3.6 35B A3B OptiQ 4-bit",
      detail: "Strong for coding and complex agent workflows.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit",
      localDirectoryName: "Qwen3.6-35B-A3B-OptiQ-4bit",
      estimatedDownloadSize: "24.7 GB",
      group: .coding,
      recommendation: .recommended,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen36,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
    ManagedModel(
      id: "qwen3.6-35b-a3b-8bit",
      displayName: "Qwen 3.6 35B A3B 8-bit",
      detail: "Higher precision for coding and images. Uses more storage.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-35B-A3B-8bit",
      localDirectoryName: "Qwen3.6-35B-A3B-8bit",
      estimatedDownloadSize: "37.7 GB",
      group: .coding,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen36,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
    ManagedModel(
      id: "qwen3.6-27B-4bit",
      displayName: "Qwen 3.6 27B 4-bit",
      detail: "For coding and images. Prefer OptiQ for text-only work.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-27B-4bit",
      localDirectoryName: "Qwen3.6-27B-4bit",
      estimatedDownloadSize: "16.1 GB",
      group: .coding,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen36,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
    ManagedModel(
      id: "Qwen3.6-27B-OptiQ-4bit",
      displayName: "Qwen 3.6 27B OptiQ 4-bit",
      detail: "Excellent for coding and demanding agent tasks.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-27B-OptiQ-4bit",
      localDirectoryName: "Qwen3.6-27B-OptiQ-4bit",
      estimatedDownloadSize: "20.0 GB",
      group: .coding,
      recommendation: .recommended,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      usesBundledMTPDrafter: true,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen36,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
    ManagedModel(
      id: "qwen3.6-27B-8bit",
      displayName: "Qwen 3.6 27B 8-bit",
      detail: "Higher precision for coding and images. Uses more storage.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-27B-8bit",
      localDirectoryName: "Qwen3.6-27B-8bit",
      estimatedDownloadSize: "29.5 GB",
      group: .coding,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen36,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
    ManagedModel(
      id: "qwen3.8-27B-OptiQ-4bit",
      displayName: "Qwen 3.8 27B OptiQ 4-bit",
      detail: "Best for coding and demanding agent tasks.",
      huggingFaceRepoID: "mlx-community/Qwen3.8-27B-OptiQ-4bit",
      localDirectoryName: "Qwen3.8-27B-OptiQ-4bit",
      estimatedDownloadSize: "20.0 GB",
      group: .coding,
      recommendation: .bestForGroup,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      reasoningCapability: .selectableEffort(
        supported: [.low, .medium, .xhigh],
        defaultValue: .medium
      ),
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen38,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
    ManagedModel(
      id: "qwen3.6-40B-8bit-heretic",
      displayName: "Qwen 3.6 40B uncensored 8-bit",
      detail: "Uncensored specialist model with fewer safeguards.",
      huggingFaceRepoID:
        "mlx-community/Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-8bit",
      localDirectoryName: "Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-8bit",
      estimatedDownloadSize: "41.5 GB",
      group: .specialized,
      requiresLargeMemory: true,
      stability: .stable,
      supportsImageInput: false,
      reasoningTraceFormat: .qwenThinkTags,
      supportsHistoricalReasoningPreservation: true,
      thinkingBudgetPolicy: .hardLimitImmediate,
      generationProfile: .qwen36,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      maxToolLoopIterations: 18
    ),
  ]

  package static var defaultModel: ManagedModel {
    models.first { $0.id == defaultModelID } ?? models[0]
  }

  package static func model(id: String) -> ManagedModel? {
    models.first { $0.id == id }
  }
}
