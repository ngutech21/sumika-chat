import Foundation

nonisolated struct ManagedModel: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let shortName: String
    let summary: String
    let detail: String
    let huggingFaceRepoID: String
    let localDirectoryName: String
    let parameterSize: String
    let estimatedDownloadSize: String
    let isRecommended: Bool
    let requiresLargeMemory: Bool
    let defaultSystemPrompt: String
    let defaultGenerationSettings: ChatGenerationSettings
    let defaultContextTokenLimit: Int

    var localDirectoryURL: URL {
        LocalModelDirectory.defaultBaseURL.appending(
            path: localDirectoryName, directoryHint: .isDirectory)
    }

    var localPath: String {
        localDirectoryURL.path(percentEncoded: false)
    }
}

nonisolated enum ManagedModelCatalog {
    static let defaultModelID = "gemma3-4b"
    static let defaultContextTokenLimit = 65_536

    static let models: [ManagedModel] = [
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

    static var defaultModel: ManagedModel {
        models.first { $0.id == defaultModelID } ?? models[0]
    }

    static func model(id: String) -> ManagedModel? {
        models.first { $0.id == id }
    }
}
