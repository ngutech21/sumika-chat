import Foundation

public enum ManagedModelStability: Equatable, Sendable {
  case stable
  case experimental
}

public enum ReasoningTraceFormat: Equatable, Sendable {
  case none
  case gemmaChannel
  case qwenThinkTags
}

public struct ToolCallingPolicy: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var allowsMultipleToolCalls: Bool

  public init(
    isEnabled: Bool,
    allowsMultipleToolCalls: Bool
  ) {
    self.isEnabled = isEnabled
    self.allowsMultipleToolCalls = allowsMultipleToolCalls
  }

  public static let unsupported = ToolCallingPolicy(
    isEnabled: false,
    allowsMultipleToolCalls: false
  )
  public static let nativeMLX = ToolCallingPolicy(
    isEnabled: true,
    allowsMultipleToolCalls: true
  )
}

public struct ManagedModel: Identifiable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let detail: String
  public let huggingFaceRepoID: String
  public let localDirectoryName: String
  public let estimatedDownloadSize: String
  public let isRecommended: Bool
  public let requiresLargeMemory: Bool
  public let stability: ManagedModelStability
  public let toolCallingPolicy: ToolCallingPolicy
  public let supportsImageInput: Bool
  public let reasoningTraceFormat: ReasoningTraceFormat
  public let defaultModeSettings: ChatModeSettingsSet
  public let defaultContextTokenLimit: Int
  public let enabled: Bool

  public init(
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

  public var defaultSystemPrompt: String {
    defaultModeSettings.agent.systemPrompt
  }

  public var defaultGenerationSettings: ChatGenerationSettings {
    defaultModeSettings.agent.generationSettings
  }

  public var supportsWorkspaceTools: Bool {
    toolCallingPolicy.isEnabled
  }

  public var localDirectoryURL: URL {
    LocalModelDirectory.defaultBaseURL.appending(
      path: localDirectoryName, directoryHint: .isDirectory)
  }

  public var localPath: String {
    localDirectoryURL.path(percentEncoded: false)
  }
}

public enum ManagedModelCatalog {
  public static let defaultModelID = "gemma4-12b-qat-4bit"
  public static let defaultContextTokenLimit = 16_384

  public static let models: [ManagedModel] = [
    ManagedModel(
      id: "gemma4-e2b-qat-4bit",
      displayName: "Gemma 4 e2b qat",
      detail: "Gemma 4 model with local vision support.",
      huggingFaceRepoID: "mlx-community/gemma-4-E2B-it-qat-4bit",
      localDirectoryName: "gemma-4-E2B-it-qat-4bit",
      estimatedDownloadSize: "4.3 GB",
      isRecommended: false,
      requiresLargeMemory: false,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: false,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: false
    ),
    ManagedModel(
      id: "gemma4-e4b-qat-4bit",
      displayName: "Gemma 4 e4b qat",
      detail: "Gemma 4 small model",
      huggingFaceRepoID: "mlx-community/gemma-4-e4b-it-qat-4bit",
      localDirectoryName: "gemma-4-e4b-it-qat-4bit",
      estimatedDownloadSize: "6.8 GB",
      isRecommended: false,
      requiresLargeMemory: false,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: false,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: true
    ),
    ManagedModel(
      id: "gemma-4-e4b-it-4bit",
      displayName: "Gemma 4 e4b",
      detail: "Gemma 4 model with local vision support.",
      huggingFaceRepoID: "mlx-community/gemma-4-e4b-it-4bit",
      localDirectoryName: "gemma-4-e4b-it-4bit",
      estimatedDownloadSize: "5.2 GB",
      isRecommended: false,
      requiresLargeMemory: false,
      stability: .stable,
      toolCallingPolicy: .nativeMLX,
      supportsImageInput: false,
      reasoningTraceFormat: .gemmaChannel,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: defaultContextTokenLimit,
      enabled: false
    ),
    ManagedModel(
      id: "gemma4-12b-qat-4bit",
      displayName: "Gemma 4 12b qat",
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
      displayName: "Gemma 4 26b qat",
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
      displayName: "Gemma 4 31b qat",
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
      displayName: "Qwen 3.6 35B A3B 4bit",
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
      displayName: "Qwen 3.6 35B A3B 8bit",
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
      displayName: "Qwen 3.6 27B 4bit",
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
  ].filter(\.enabled)

  public static var defaultModel: ManagedModel {
    models.first { $0.id == defaultModelID } ?? models[0]
  }

  public static func model(id: String) -> ManagedModel? {
    models.first { $0.id == id }
  }
}
