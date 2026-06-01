import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var modelPath = LocalModelDirectory.defaultModelURL.path(percentEncoded: false)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var modelState: ModelLoadState = .notLoaded
    @State private var chatSession = ChatSessionState.codingDefault
    @State private var contextUsage: ChatContextUsage?
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var isHandlingDroppedDraftPath = false
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private let runtime: any ChatModelRuntime = GemmaMLXRuntime()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModelSidebar(
                modelPath: $modelPath,
                systemPrompt: $chatSession.systemPrompt,
                generationSettings: $chatSession.generationSettings,
                contextUsage: contextUsage,
                modelState: modelState,
                isLoading: modelState == .loading,
                onChooseModelDirectory: chooseModelDirectory,
                onLoad: loadModel
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                ChatTranscript(messages: chatSession.messages)

                Divider()

                ChatComposer(
                    draft: $draft,
                    attachments: chatSession.attachments,
                    canSend: canSend,
                    isGenerating: isGenerating,
                    errorMessage: errorMessage,
                    onAddAttachments: chooseAttachments,
                    onDropAttachments: addAttachments,
                    onRemoveAttachment: removeAttachment,
                    onSend: sendMessage,
                    onCancel: cancelGeneration
                )
            }
            .navigationTitle("Local Coder")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 560)
        .onChange(of: chatSession.systemPrompt) {
            refreshContextUsage()
        }
        .onChange(of: draft) {
            convertDroppedFilePathsInDraft()
        }
        .onAppear {
            columnVisibility = .all
            do {
                let baseURL = try LocalModelDirectory.ensureDefaultBaseDirectoryExists()
                if modelPath.isEmpty {
                    modelPath = baseURL
                        .appending(path: LocalModelDirectory.defaultModelName, directoryHint: .isDirectory)
                        .path(percentEncoded: false)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var canSend: Bool {
        modelState == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private func loadModel() {
        let trimmedPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            errorMessage = "Choose a local model directory before loading."
            return
        }

        let directoryURL = URL(filePath: trimmedPath, directoryHint: .isDirectory)

        Task {
            errorMessage = nil
            modelState = .loading

            do {
                try validateModelDirectory(directoryURL)
                let configuration = ChatModelConfiguration(
                    localModelDirectory: directoryURL,
                    contextTokenLimit: LocalModelDirectory.readContextTokenLimit(from: directoryURL)
                )
                try await runtime.load(configuration: configuration)
                modelState = .ready
                await updateContextUsage()
            } catch {
                modelState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendMessage() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }

        let sentAttachments = chatSession.attachments
        draft = ""
        errorMessage = nil
        chatSession.attachments.removeAll()
        chatSession.messages.append(ChatMessage(role: .user, content: prompt, attachments: sentAttachments))
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

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
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

    private func clearChatHistory() {
        chatSession.messages.removeAll()
        chatSession.attachments.removeAll()
        contextUsage = nil

        Task {
            await runtime.clearContext()
            await updateContextUsage()
        }
    }

    private func refreshContextUsage() {
        Task {
            await updateContextUsage()
        }
    }

    private func updateContextUsage() async {
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

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: modelPath, directoryHint: .isDirectory)
        panel.message = "Choose a local MLX Gemma model directory."
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            modelPath = url.path(percentEncoded: false)
            modelState = .notLoaded
            errorMessage = nil
            clearChatHistory()
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = "Choose text files to add as model context."
        panel.prompt = "Add"

        if panel.runModal() == .OK {
            addAttachments(from: panel.urls)
        }
    }

    private func addAttachments(from urls: [URL]) {
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

    private func convertDroppedFilePathsInDraft() {
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
        var cleaned = text
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

    private func removeAttachment(id: ChatAttachment.ID) {
        chatSession.attachments.removeAll { $0.id == id }
        refreshContextUsage()
    }

    private func validateModelDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalModelDirectoryError.notFound(path)
        }
    }
}

private struct ModelSidebar: View {
    @Binding var modelPath: String
    @Binding var systemPrompt: String
    @Binding var generationSettings: ChatGenerationSettings
    let contextUsage: ChatContextUsage?
    let modelState: ModelLoadState
    let isLoading: Bool
    let onChooseModelDirectory: () -> Void
    let onLoad: () -> Void

    var body: some View {
        List {
            Section("Model") {
                TextField("Model Path", text: $modelPath, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                HStack {
                    Button(action: onChooseModelDirectory) {
                        Label("Choose", systemImage: "folder")
                    }
                    .disabled(isLoading)

                    Button(action: onLoad) {
                        Label(isLoading ? "Loading" : "Load Model", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("load-model-button")
                    .disabled(isLoading || modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Label(modelState.label, systemImage: modelState.systemImage)
                    .accessibilityIdentifier("model-state-label")
                    .foregroundStyle(modelState.tint)
            }

            Section("Context") {
                if let contextUsage {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Tokens", systemImage: "rectangle.stack")
                            Spacer()
                            Text(contextUsage.summary)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        if let fraction = contextUsage.fraction {
                            ProgressView(value: fraction)
                        }
                    }
                } else {
                    Label("Load a model to count tokens.", systemImage: "rectangle.stack")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Generation") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("System Prompt", systemImage: "text.quote")
                    TextField("System Prompt", text: $systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...8)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Temperature", systemImage: "thermometer.variable")
                        Spacer()
                        Text(generationSettings.temperature.formatted(.number.precision(.fractionLength(1))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $generationSettings.temperature, in: 0...2, step: 0.1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Top P", systemImage: "chart.line.uptrend.xyaxis")
                        Spacer()
                        Text(generationSettings.topP.formatted(.number.precision(.fractionLength(2))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $generationSettings.topP, in: 0.05...1, step: 0.05)
                }

                Stepper(value: $generationSettings.topK, in: 0...200, step: 10) {
                    SettingValueLabel(title: "Top K", value: "\(generationSettings.topK)")
                }

                Stepper(value: $generationSettings.maxTokens, in: 128...8192, step: 128) {
                    SettingValueLabel(title: "Max Tokens", value: "\(generationSettings.maxTokens)")
                }

                Button("Coding Defaults") {
                    systemPrompt = ChatPromptDefaults.codingSystemPrompt
                    generationSettings = .codingDefault
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Runtime")
    }
}

private struct SettingValueLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ChatTranscript: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Choose a local Gemma model directory to start chatting.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    ForEach(messages) { message in
                        ChatBubble(message: message)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                Label(message.role.title, systemImage: message.role.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if message.content.isEmpty && message.role == .assistant {
                    Label("Generating", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    MessageContentText(message: message)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if message.role == .user && !message.attachments.isEmpty {
                    SentAttachmentList(attachments: message.attachments)
                }

                if message.role == .assistant && !message.content.isEmpty {
                    HStack(spacing: 8) {
                        if let metrics = message.generationMetrics {
                            Text(metrics.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            copyMessageToClipboard()
                        } label: {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(didCopy ? "Copied" : "Copy")
                        .accessibilityLabel("Copy assistant message")
                    }
                }
            }
            .frame(maxWidth: 680, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func copyMessageToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        didCopy = true

        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

private struct SentAttachmentList: View {
    let attachments: [ChatAttachment]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(attachments) { attachment in
                Label(attachment.displayName, systemImage: "doc.text")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .help(attachment.displayPath)
            }
        }
    }
}

private struct MessageContentText: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .assistant,
           let markdown = try? AttributedString(markdown: message.content)
        {
            Text(markdown)
        } else {
            Text(message.content)
        }
    }
}

private extension ChatGenerationMetrics {
    var summary: String {
        "\(generatedTokenCount) tokens · \(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tokens/s"
    }
}

private struct ChatComposer: View {
    @Binding var draft: String
    let attachments: [ChatAttachment]
    let canSend: Bool
    let isGenerating: Bool
    let errorMessage: String?
    let onAddAttachments: () -> Void
    let onDropAttachments: ([URL]) -> Void
    let onRemoveAttachment: (ChatAttachment.ID) -> Void
    let onSend: () -> Void
    let onCancel: () -> Void
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if !attachments.isEmpty {
                AttachmentList(
                    attachments: attachments,
                    canRemove: !isGenerating,
                    onRemoveAttachment: onRemoveAttachment
                )
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: onAddAttachments) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .disabled(isGenerating)
                .help("Add context files")
                .accessibilityLabel("Add context files")

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("message-field")
                    .onSubmit(onSend)
                    .onDrop(
                        of: [UTType.fileURL.identifier],
                        isTargeted: $isDropTarget,
                        perform: handleDrop
                    )

                Button(action: isGenerating ? onCancel : onSend) {
                    Image(systemName: isGenerating ? "stop.fill" : "paperplane.fill")
                }
                .accessibilityIdentifier(isGenerating ? "cancel-generation-button" : "send-button")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isGenerating && !canSend)
                .help(isGenerating ? "Cancel" : "Send")
            }
        }
        .padding(16)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                    }
                    .padding(6)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTarget,
            perform: handleDrop
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isGenerating else {
            return false
        }

        let fileURLType = UTType.fileURL.identifier
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        guard !fileProviders.isEmpty else {
            return false
        }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                guard let url = Self.fileURL(from: item) else {
                    return
                }

                Task { @MainActor in
                    onDropAttachments([url])
                }
            }
        }

        return true
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }
}

private struct AttachmentList: View {
    let attachments: [ChatAttachment]
    let canRemove: Bool
    let onRemoveAttachment: (ChatAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)

                        Text(attachment.displayName)
                            .lineLimit(1)

                        Button {
                            onRemoveAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(!canRemove)
                        .help("Remove")
                        .accessibilityLabel("Remove \(attachment.displayName)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .help(attachment.displayPath)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum ModelLoadState: Equatable {
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

    var tint: Color {
        switch self {
        case .notLoaded, .loading:
            .secondary
        case .ready:
            .green
        case .failed:
            .red
        }
    }
}

private enum LocalModelDirectoryError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            "Model directory does not exist: \(path)"
        }
    }
}

#Preview {
    ContentView()
}
