import Foundation

struct StoredModelSettings: Codable, Equatable, Sendable {
    var systemPrompt: String
    var generationSettings: ChatGenerationSettings

    init(
        systemPrompt: String = ChatPromptDefaults.codingSystemPrompt,
        generationSettings: ChatGenerationSettings = .codingDefault
    ) {
        self.systemPrompt = systemPrompt
        self.generationSettings = generationSettings
    }
}

protocol ModelSettingsStoring: Sendable {
    func selectedModelID(availableModelIDs: Set<String>) -> String
    func setSelectedModelID(_ modelID: String)
    func settings(for model: ManagedModel) -> StoredModelSettings
    func save(settings: StoredModelSettings, for model: ManagedModel) throws
}

final class ModelSettingsStore: ModelSettingsStoring, @unchecked Sendable {
    private struct SettingsFile: Codable {
        var modelSettings: [String: StoredModelSettings]
    }

    private let userDefaults: UserDefaults
    private let settingsURL: URL
    private let selectedModelKey = "selectedModelID"
    private let fileManager: FileManager

    init(
        userDefaults: UserDefaults = .standard,
        settingsURL: URL = LocalModelDirectory.defaultBaseURL
            .deletingLastPathComponent()
            .appending(path: "model-settings.json", directoryHint: .notDirectory),
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    func selectedModelID(availableModelIDs: Set<String>) -> String {
        guard
            let storedID = userDefaults.string(forKey: selectedModelKey),
            availableModelIDs.contains(storedID)
        else {
            return ManagedModelCatalog.defaultModelID
        }

        return storedID
    }

    func setSelectedModelID(_ modelID: String) {
        userDefaults.set(modelID, forKey: selectedModelKey)
    }

    func settings(for model: ManagedModel) -> StoredModelSettings {
        guard let stored = readSettingsFile().modelSettings[model.id] else {
            return StoredModelSettings(
                systemPrompt: model.defaultSystemPrompt,
                generationSettings: model.defaultGenerationSettings
            )
        }

        return stored
    }

    func save(settings: StoredModelSettings, for model: ManagedModel) throws {
        var file = readSettingsFile()
        file.modelSettings[model.id] = settings

        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: settingsURL, options: .atomic)
    }

    private func readSettingsFile() -> SettingsFile {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let decoded = try? JSONDecoder().decode(SettingsFile.self, from: data)
        else {
            return SettingsFile(modelSettings: [:])
        }

        return decoded
    }
}
