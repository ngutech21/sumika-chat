import Foundation

public struct ManagedModel: Identifiable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let shortName: String
  public let summary: String
  public let detail: String
  public let huggingFaceRepoID: String
  public let localDirectoryName: String
  public let parameterSize: String
  public let estimatedDownloadSize: String
  public let isRecommended: Bool
  public let requiresLargeMemory: Bool
  public let defaultSystemPrompt: String
  public let defaultGenerationSettings: ChatGenerationSettings
  public let defaultContextTokenLimit: Int

  public var localDirectoryURL: URL {
    LocalModelDirectory.defaultBaseURL.appending(
      path: localDirectoryName, directoryHint: .isDirectory)
  }

  public var localPath: String {
    localDirectoryURL.path(percentEncoded: false)
  }
}

public enum ManagedModelCatalog {
  public static let defaultModelID = "gemma3-4b"
  public static let defaultContextTokenLimit = 16_384

  public static let models: [ManagedModel] = [
    ManagedModel(
      id: "gemma3-1b",
      displayName: "Gemma 3 1B",
      shortName: "1B",
      summary: "Fast and light",
      detail: "Good for short answers and Macs with limited free memory.",
      huggingFaceRepoID: "mlx-community/gemma-3-1b-it-qat-4bit",
      localDirectoryName: "gemma3-1b",
      parameterSize: "1B",
      estimatedDownloadSize: "733 MB",
      isRecommended: false,
      requiresLargeMemory: false,
      defaultSystemPrompt: ChatPromptDefaults.codingSystemPrompt,
      defaultGenerationSettings: .codingDefault,
      defaultContextTokenLimit: defaultContextTokenLimit
    ),
    ManagedModel(
      id: "gemma3-4b",
      displayName: "Gemma 3 4B",
      shortName: "4B",
      summary: "Balanced",
      detail: "Recommended for local coding tasks with good speed.",
      huggingFaceRepoID: "mlx-community/gemma-3-4b-it-qat-4bit",
      localDirectoryName: "gemma3-4b",
      parameterSize: "4B",
      estimatedDownloadSize: "3 GB",
      isRecommended: true,
      requiresLargeMemory: false,
      defaultSystemPrompt: ChatPromptDefaults.codingSystemPrompt,
      defaultGenerationSettings: .codingDefault,
      defaultContextTokenLimit: defaultContextTokenLimit
    ),
    ManagedModel(
      id: "gemma3-27b",
      displayName: "Gemma 3 27B",
      shortName: "27B",
      summary: "Best quality",
      detail: "Large model for powerful Macs. It will not run well on every machine.",
      huggingFaceRepoID: "mlx-community/gemma-3-27b-it-qat-4bit",
      localDirectoryName: "gemma3-27b",
      parameterSize: "27B",
      estimatedDownloadSize: "16.8 GB",
      isRecommended: false,
      requiresLargeMemory: true,
      defaultSystemPrompt: ChatPromptDefaults.codingSystemPrompt,
      defaultGenerationSettings: .codingDefault,
      defaultContextTokenLimit: defaultContextTokenLimit
    ),
  ]

  public static var defaultModel: ManagedModel {
    models.first { $0.id == defaultModelID } ?? models[0]
  }

  public static func model(id: String) -> ManagedModel? {
    models.first { $0.id == id }
  }
}
