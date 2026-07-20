import Foundation

package enum ManagedModelStability: Equatable, Sendable {
  case stable
  case experimental
}

package enum ReasoningTraceFormat: Equatable, Sendable {
  case none
  case gemmaChannel
  case qwenThinkTags
}

package struct ToolCallingPolicy: Codable, Equatable, Sendable {
  package var isEnabled: Bool
  package var allowsMultipleToolCalls: Bool

  package init(
    isEnabled: Bool,
    allowsMultipleToolCalls: Bool
  ) {
    self.isEnabled = isEnabled
    self.allowsMultipleToolCalls = allowsMultipleToolCalls
  }

  package static let unsupported = ToolCallingPolicy(
    isEnabled: false,
    allowsMultipleToolCalls: false
  )
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
  package let isRecommended: Bool
  package let requiresLargeMemory: Bool
  package let stability: ManagedModelStability
  package let toolCallingPolicy: ToolCallingPolicy
  package let supportsImageInput: Bool
  package let reasoningTraceFormat: ReasoningTraceFormat
  package let defaultModeSettings: ChatModeSettingsSet
  package let defaultContextTokenLimit: Int
  package let enabled: Bool

  package init(
    id: String,
    displayName: String,
    detail: String,
    huggingFaceRepoID: String,
    localDirectoryName: String,
    estimatedDownloadSize: String,
    isRecommended: Bool,
    requiresLargeMemory: Bool,
    stability: ManagedModelStability,
    toolCallingPolicy: ToolCallingPolicy,
    supportsImageInput: Bool,
    reasoningTraceFormat: ReasoningTraceFormat = .none,
    defaultModeSettings: ChatModeSettingsSet,
    defaultContextTokenLimit: Int,
    enabled: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.detail = detail
    self.huggingFaceRepoID = huggingFaceRepoID
    self.localDirectoryName = localDirectoryName
    self.estimatedDownloadSize = estimatedDownloadSize
    self.isRecommended = isRecommended
    self.requiresLargeMemory = requiresLargeMemory
    self.stability = stability
    self.toolCallingPolicy = toolCallingPolicy
    self.supportsImageInput = supportsImageInput
    self.reasoningTraceFormat = reasoningTraceFormat
    self.defaultModeSettings = defaultModeSettings
    self.defaultContextTokenLimit = defaultContextTokenLimit
    self.enabled = enabled
  }

  package var defaultSystemPrompt: String {
    defaultModeSettings.agent.systemPrompt
  }

  package var defaultGenerationSettings: ChatGenerationSettings {
    defaultModeSettings.agent.generationSettings
  }

  package var supportsWorkspaceTools: Bool {
    toolCallingPolicy.isEnabled
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
      id: "gemma4-e2b-qat-4bit",
      displayName: "Gemma 4 E2B QAT 4-bit",
      detail: "Gemma 4 model with local vision support.",
      huggingFaceRepoID: "mlx-community/gemma-4-E2B-it-qat-4bit",
      localDirectoryName: "gemma-4-E2B-it-qat-4bit",
      estimatedDownloadSize: "4.3 GB",
      isRecommended: false,
      requiresLargeMemory: false,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: false
    ),
    ManagedModel(
      id: "gemma4-e4b-qat-4bit",
      displayName: "Gemma 4 E4B QAT 4-bit",
      detail: "Gemma 4 small model",
      huggingFaceRepoID: "mlx-community/gemma-4-e4b-it-qat-4bit",
      localDirectoryName: "gemma-4-e4b-it-qat-4bit",
      estimatedDownloadSize: "6.8 GB",
      isRecommended: false,
      requiresLargeMemory: false,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "gemma-4-e4b-it-4bit",
      displayName: "Gemma 4 E4B 4-bit",
      detail: "Gemma 4 model with local vision support.",
      huggingFaceRepoID: "mlx-community/gemma-4-e4b-it-4bit",
      localDirectoryName: "gemma-4-e4b-it-4bit",
      estimatedDownloadSize: "5.2 GB",
      isRecommended: false,
      requiresLargeMemory: false,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: false
    ),
    ManagedModel(
      id: "gemma4-12b-qat-4bit",
      displayName: "Gemma 4 12B QAT 4-bit",
      detail: "Larger Gemma 4 model with local vision support.",
      huggingFaceRepoID: "mlx-community/gemma-4-12B-it-qat-4bit",
      localDirectoryName: "gemma-4-12B-it-qat-4bit",
      estimatedDownloadSize: "11.0 GB",
      isRecommended: true,
      requiresLargeMemory: true,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "gemma4-26b-qat-4bit",
      displayName: "Gemma 4 26B QAT 4-bit",
      detail: "Larger Gemma 4 model with local vision support.",
      huggingFaceRepoID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
      localDirectoryName: "gemma-4-26B-A4B-it-qat-4bit",
      estimatedDownloadSize: "15.6 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "gemma4-31b-qat-4bit",
      displayName: "Gemma 4 31B QAT 4-bit",
      detail: "Large Gemma 4 model with local vision support.",
      huggingFaceRepoID: "mlx-community/gemma-4-31B-it-qat-4bit",
      localDirectoryName: "gemma-4-31b-qat-4bit",
      estimatedDownloadSize: "28.8 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),

    ManagedModel(
      id: "qwen3.6-35b-a3b-4bit",
      displayName: "Qwen 3.6 35B A3B 4-bit",
      detail: "Experimental Qwen3.6 MoE model with local vision support.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-35B-A3B-4bit",
      localDirectoryName: "Qwen3.6-35B-A3B-4bit",
      estimatedDownloadSize: "20.4 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      stability: .experimental,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "qwen3.6-35b-a3b-8bit",
      displayName: "Qwen 3.6 35B A3B 8-bit",
      detail: "Experimental Qwen3.6 MoE model with local vision support.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-35B-A3B-8bit",
      localDirectoryName: "Qwen3.6-35B-A3B-8bit",
      estimatedDownloadSize: "37.7 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      stability: .experimental,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "qwen3.6-27B-4bit",
      displayName: "Qwen 3.6 27B 4-bit",
      detail: "Experimental Qwen3.6 model with local vision support.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-27B-4bit",
      localDirectoryName: "Qwen3.6-27B-4bit",
      estimatedDownloadSize: "16.1 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      stability: .experimental,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "qwen3.6-27B-8bit",
      displayName: "Qwen 3.6 27B 8-bit",
      detail: "Experimental Qwen3.6 model with local vision support.",
      huggingFaceRepoID: "mlx-community/Qwen3.6-27B-8bit",
      localDirectoryName: "Qwen3.6-27B-8bit",
      estimatedDownloadSize: "29.5 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      stability: .experimental,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: true,
      reasoningTraceFormat: .qwenThinkTags,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "qwen3.6-40B-8bit-heretic",
      displayName: "Qwen 3.6 40B uncensored 8-bit",
      detail: "Uncensored Qwen3.6 model with local vision support.",
      huggingFaceRepoID:
        "mlx-community/Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-8bit",
      localDirectoryName: "Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-8bit",
      estimatedDownloadSize: "41.5 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      stability: .experimental,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: false,
      reasoningTraceFormat: .qwenThinkTags,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
  ].filter(\.enabled)

  package static var defaultModel: ManagedModel {
    models.first { $0.id == defaultModelID } ?? models[0]
  }

  package static func model(id: String) -> ManagedModel? {
    models.first { $0.id == id }
  }
}
