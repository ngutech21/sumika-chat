// swiftlint:disable file_length
import Foundation
import Observation

@MainActor
@Observable
final class ChatSessionController {
    var availableModels = ManagedModelCatalog.models
    var selectedModelID: ManagedModel.ID
    var downloadState: ModelDownloadState = .idle
    var downloadProgress: Double?
    var modelPath: String
    var modelState: ModelLoadState = .notLoaded
    var chatSession = ChatSessionState.codingDefault
    var contextUsage: ChatContextUsage?
    var processUsage: ProcessResourceUsage?
    var draft = ""
    var isGenerating = false
    var errorMessage: String?

    @ObservationIgnored private let runtime: any ChatModelRuntime
    @ObservationIgnored private let resourceMonitor: any ProcessResourceMonitoring
    @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
    @ObservationIgnored private let modelDownloader: any ModelDownloading
    @ObservationIgnored private var isHandlingDroppedDraftPath = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var modelOperationID = UUID()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var resourceMonitorTask: Task<Void, Never>?

    var canSend: Bool {
        modelState == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
    }

    var selectedModel: ManagedModel {
        availableModels.first { $0.id == selectedModelID } ?? ManagedModelCatalog.defaultModel
    }

    var canChangeModel: Bool {
        !isGenerating && modelState != .loading && !downloadState.isDownloading
    }

    init() {
        let settingsStore = ModelSettingsStore()
        let downloader = HuggingFaceModelDownloader()
        let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
        let selectedModelID = settingsStore.selectedModelID(availableModelIDs: availableModelIDs)
        let selectedModel =
            ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
        let storedSettings = settingsStore.settings(for: selectedModel)

        self.runtime = GemmaMLXRuntime()
        self.resourceMonitor = ProcessResourceMonitor()
        self.modelSettingsStore = settingsStore
        self.modelDownloader = downloader
        self.selectedModelID = selectedModel.id
        self.modelPath = selectedModel.localPath
        self.chatSession = ChatSessionState(
            messages: [],
            attachments: [],
            systemPrompt: storedSettings.systemPrompt,
            generationSettings: storedSettings.generationSettings
        )
    }

    init(
        runtime: any ChatModelRuntime,
        resourceMonitor: any ProcessResourceMonitoring = ProcessResourceMonitor(),
        modelPath: String,
        modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
        modelDownloader: any ModelDownloading = HuggingFaceModelDownloader()
    ) {
        self.runtime = runtime
        self.resourceMonitor = resourceMonitor
        self.modelSettingsStore = modelSettingsStore
        self.modelDownloader = modelDownloader
        self.selectedModelID = ManagedModelCatalog.defaultModelID
        self.modelPath = modelPath
    }

    deinit {
        loadTask?.cancel()
        downloadTask?.cancel()
        generationTask?.cancel()
        resourceMonitorTask?.cancel()
    }

    func prepareDefaultModelDirectory() {
        do {
            let baseURL = try LocalModelDirectory.ensureDefaultBaseDirectoryExists()
            if modelPath.isEmpty {
                modelPath = selectedModel.localPath
            } else if !modelPath.hasPrefix(baseURL.path(percentEncoded: false)) {
                modelPath = selectedModel.localPath
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startResourceMonitoring() {
        guard resourceMonitorTask == nil else {
            return
        }

        resourceMonitorTask = Task {
            while !Task.isCancelled {
                processUsage = await resourceMonitor.currentUsage()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func setModelDirectory(_ url: URL) {
        modelPath = url.path(percentEncoded: false)
        modelState = .notLoaded
        errorMessage = nil
        clearChatHistory()
    }

    func selectModel(_ model: ManagedModel) {
        guard canChangeModel, selectedModelID != model.id else {
            return
        }

        saveSelectedModelSettings()
        unloadModel()
        selectedModelID = model.id
        modelSettingsStore.setSelectedModelID(model.id)
        modelPath = model.localPath
        downloadState = .idle
        downloadProgress = nil
        errorMessage = nil
        clearChatHistory()

        let settings = modelSettingsStore.settings(for: model)
        chatSession.systemPrompt = settings.systemPrompt
        chatSession.generationSettings = settings.generationSettings
    }

    func isModelDownloaded(_ model: ManagedModel) -> Bool {
        let modelDirectory = model.localDirectoryURL
        let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: modelDirectory.path(percentEncoded: false),
                isDirectory: &isDirectory
            ), isDirectory.boolValue
        else {
            return false
        }

        return FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false))
    }

    func downloadSelectedModel() {
        guard !downloadState.isDownloading else {
            return
        }

        let model = selectedModel
        downloadTask?.cancel()
        downloadProgress = nil
        downloadState = .downloading(progress: nil)
        errorMessage = nil

        downloadTask = Task {
            do {
                _ = try await modelDownloader.download(model: model) { progress in
                    let fraction = Self.normalizedDownloadProgress(progress)
                    self.downloadProgress = fraction
                    self.downloadState = .downloading(progress: self.downloadProgress)
                }
                try Task.checkCancellation()
                downloadState = .downloaded
                downloadProgress = 1
                modelPath = model.localPath
            } catch is CancellationError {
                downloadState = .idle
                downloadProgress = nil
            } catch {
                downloadState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
                downloadProgress = nil
            }

            downloadTask = nil
        }
    }

    func saveSelectedModelSettings() {
        let settings = StoredModelSettings(
            systemPrompt: chatSession.systemPrompt,
            generationSettings: chatSession.generationSettings
        )

        do {
            try modelSettingsStore.save(settings: settings, for: selectedModel)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSelectedModel() {
        modelPath = selectedModel.localPath
        loadModel()
    }

    func loadModel() {
        guard !downloadState.isDownloading else {
            return
        }

        let trimmedPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            errorMessage = "Choose a local model directory before loading."
            return
        }

        let directoryURL = URL(filePath: trimmedPath, directoryHint: .isDirectory)
        loadTask?.cancel()
        modelOperationID = UUID()
        let operationID = modelOperationID

        loadTask = Task {
            errorMessage = nil
            modelState = .loading

            do {
                try validateModelDirectory(directoryURL)
                try Task.checkCancellation()
                let configuration = ChatModelConfiguration(
                    localModelDirectory: directoryURL,
                    contextTokenLimit: LocalModelDirectory.readContextTokenLimit(from: directoryURL)
                )
                try await runtime.load(configuration: configuration)
                try Task.checkCancellation()
                guard operationID == modelOperationID else {
                    return
                }
                modelState = .ready
                await updateContextUsage()
            } catch is CancellationError {
                if operationID == modelOperationID {
                    modelState = .notLoaded
                    contextUsage = nil
                }
            } catch {
                guard operationID == modelOperationID else {
                    return
                }
                modelState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }

            if operationID == modelOperationID {
                loadTask = nil
            }
        }
    }

    func unloadModel() {
        modelOperationID = UUID()
        loadTask?.cancel()
        loadTask = nil
        cancelGeneration()
        errorMessage = nil
        modelState = .notLoaded
        contextUsage = nil

        Task {
            await runtime.unload()
        }
    }

    func sendMessage() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }

        let sentAttachments = chatSession.attachments
        draft = ""
        errorMessage = nil
        chatSession.attachments.removeAll()
        chatSession.messages.append(
            ChatMessage(role: .user, content: prompt, attachments: sentAttachments))
        let assistantMessageID = UUID()
        chatSession.messages.append(ChatMessage(id: assistantMessageID, role: .assistant, content: ""))
        isGenerating = true

        generationTask = Task {
            do {
                await updateContextUsage()
                let stream = try await runtime.streamReply(
                    for: chatSession.messages,
                    attachments: [],
                    systemPrompt: chatSession.systemPrompt,
                    settings: chatSession.generationSettings
                )

                for try await event in stream {
                    switch event {
                    case .chunk(let chunk):
                        appendChunk(chunk, to: assistantMessageID)
                    case .completed(let metrics):
                        updateGenerationMetrics(metrics, for: assistantMessageID)
                        await updateContextUsage()
                    }
                }
            } catch is CancellationError {
                if messageContent(for: assistantMessageID).isEmpty {
                    removeMessage(id: assistantMessageID)
                }
                await updateContextUsage()
            } catch {
                removeMessage(id: assistantMessageID)
                errorMessage = error.localizedDescription
                await updateContextUsage()
            }

            isGenerating = false
            generationTask = nil
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    func clearChatHistory() {
        chatSession.messages.removeAll()
        chatSession.attachments.removeAll()
        contextUsage = nil

        Task {
            await runtime.clearContext()
            await updateContextUsage()
        }
    }

    func refreshContextUsage() {
        Task {
            await updateContextUsage()
        }
    }

    func updateContextUsage() async {
        guard modelState == .ready else {
            contextUsage = nil
            return
        }

        do {
            contextUsage = try await runtime.contextUsage(
                for: chatSession.messages,
                attachments: chatSession.attachments,
                systemPrompt: chatSession.systemPrompt
            )
        } catch {
            contextUsage = nil
        }
    }

    func addAttachments(from urls: [URL]) {
        do {
            let remainingSlots = ChatAttachmentLimits.maxAttachmentCount - chatSession.attachments.count
            guard urls.count <= remainingSlots else {
                throw ChatAttachmentError.tooManyFiles(ChatAttachmentLimits.maxAttachmentCount)
            }

            let existingPaths = Set(chatSession.attachments.map(\.displayPath))
            let attachments = try urls.compactMap { url -> ChatAttachment? in
                let path = url.path(percentEncoded: false)
                guard !existingPaths.contains(path) else {
                    return nil
                }

                return try readTextAttachment(from: url)
            }

            chatSession.attachments.append(contentsOf: attachments)
            errorMessage = nil
            refreshContextUsage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func convertDroppedFilePathsInDraft() {
        guard !isHandlingDroppedDraftPath, !isGenerating else {
            return
        }

        let droppedFiles = droppedAttachmentURLs(in: draft)
        guard !droppedFiles.urls.isEmpty else {
            return
        }

        isHandlingDroppedDraftPath = true
        draft = droppedFiles.cleanedDraft
        addAttachments(from: droppedFiles.urls)
        isHandlingDroppedDraftPath = false
    }

    func removeAttachment(id: ChatAttachment.ID) {
        chatSession.attachments.removeAll { $0.id == id }
        refreshContextUsage()
    }

    private func appendChunk(_ chunk: String, to messageID: UUID) {
        guard let index = chatSession.messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let message = chatSession.messages[index]
        chatSession.messages[index] = ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content + chunk,
            attachments: message.attachments,
            generationMetrics: message.generationMetrics
        )
    }

    private func updateGenerationMetrics(_ metrics: ChatGenerationMetrics?, for messageID: UUID) {
        guard let index = chatSession.messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let message = chatSession.messages[index]
        chatSession.messages[index] = ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            attachments: message.attachments,
            generationMetrics: metrics
        )
    }

    private func removeMessage(id: UUID) {
        chatSession.messages.removeAll { $0.id == id }
    }

    private func messageContent(for id: UUID) -> String {
        chatSession.messages.first(where: { $0.id == id })?.content ?? ""
    }

    private func droppedAttachmentURLs(in text: String) -> (urls: [URL], cleanedDraft: String) {
        let pattern = droppedAttachmentPathPattern()
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], text)
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else {
            return ([], text)
        }

        var urls: [URL] = []
        var rangesToRemove: [Range<String.Index>] = []

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else {
                continue
            }

            let rawPath = String(text[matchRange])
            guard let url = attachmentURL(fromDroppedPath: rawPath), isSupportedAttachmentURL(url) else {
                continue
            }

            urls.append(url)
            rangesToRemove.append(matchRange)
        }

        guard !urls.isEmpty else {
            return ([], text)
        }

        var cleanedDraft = text
        for range in rangesToRemove.reversed() {
            cleanedDraft.removeSubrange(range)
        }

        return (urls, normalizeDraftAfterRemovingAttachmentPaths(cleanedDraft))
    }

    private func droppedAttachmentPathPattern() -> String {
        let extensions = ChatAttachmentLimits.supportedTextFileExtensions
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return #"file://[^\s]+|/[^\n\r\t]*?\.(?:"# + extensions + #")(?=\s|$)"#
    }

    private func attachmentURL(fromDroppedPath path: String) -> URL? {
        if path.hasPrefix("file://") {
            return URL(string: path)?.standardizedFileURL
        }

        return URL(filePath: path).standardizedFileURL
    }

    private func isSupportedAttachmentURL(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        let fileExtension = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false

        return ChatAttachmentLimits.supportedTextFileExtensions.contains(fileExtension)
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func normalizeDraftAfterRemovingAttachmentPaths(_ text: String) -> String {
        var cleaned =
            text
            .replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")

        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readTextAttachment(from url: URL) throws -> ChatAttachment {
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = url.lastPathComponent
        let fileExtension = url.pathExtension.lowercased()
        guard ChatAttachmentLimits.supportedTextFileExtensions.contains(fileExtension) else {
            throw ChatAttachmentError.unsupportedFileType(fileName)
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = resourceValues.fileSize ?? 0
        guard fileSize <= ChatAttachmentLimits.maxTextFileBytes else {
            throw ChatAttachmentError.fileTooLarge(fileName, ChatAttachmentLimits.maxTextFileBytes)
        }

        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ChatAttachmentError.unreadableText(fileName)
        }

        return ChatAttachment(
            url: url,
            displayName: fileName,
            kind: .text,
            content: content
        )
    }

    private func validateModelDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw LocalModelDirectoryError.notFound(path)
        }
    }

    private static func normalizedDownloadProgress(_ progress: Progress) -> Double? {
        let fraction = progress.fractionCompleted
        guard fraction.isFinite else {
            return nil
        }

        return min(max(fraction, 0), 1)
    }
}

enum ModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double?)
    case downloaded
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self {
            return true
        }

        return false
    }

    var label: String {
        switch self {
        case .idle:
            "Not downloaded"
        case .downloading(let progress):
            if let progress {
                "Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))"
            } else {
                "Downloading"
            }
        case .downloaded:
            "Downloaded"
        case .failed:
            "Download failed"
        }
    }
}

enum ModelLoadState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .notLoaded:
            "No model loaded"
        case .loading:
            "Loading model"
        case .ready:
            "Model ready"
        case .failed:
            "Model failed"
        }
    }

    var systemImage: String {
        switch self {
        case .notLoaded:
            "circle"
        case .loading:
            "clock"
        case .ready:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }
}

enum LocalModelDirectoryError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            "Model directory does not exist: \(path)"
        }
    }
}
