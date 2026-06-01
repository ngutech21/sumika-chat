import AppKit
import SwiftUI

struct ContentView: View {
    @State private var modelPath = LocalModelDirectory.defaultModelURL.path(percentEncoded: false)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var modelState: ModelLoadState = .notLoaded
    @State private var generationSettings = ChatGenerationSettings.codingDefault
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private let runtime: any ChatModelRuntime = GemmaMLXRuntime()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModelSidebar(
                modelPath: $modelPath,
                generationSettings: $generationSettings,
                modelState: modelState,
                isLoading: modelState == .loading,
                onChooseModelDirectory: chooseModelDirectory,
                onLoad: loadModel
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                ChatTranscript(messages: messages)

                Divider()

                ChatComposer(
                    draft: $draft,
                    canSend: canSend,
                    isGenerating: isGenerating,
                    errorMessage: errorMessage,
                    onSend: sendMessage,
                    onCancel: cancelGeneration
                )
            }
            .navigationTitle("Local Coder")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 560)
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
                try await runtime.load(configuration: ChatModelConfiguration(localModelDirectory: directoryURL))
                modelState = .ready
            } catch {
                modelState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendMessage() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }

        draft = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, content: prompt))
        let assistantMessageID = UUID()
        messages.append(ChatMessage(id: assistantMessageID, role: .assistant, content: ""))
        isGenerating = true

        generationTask = Task {
            do {
                let stream = try await runtime.streamReply(
                    for: messages,
                    settings: generationSettings
                )

                for try await event in stream {
                    switch event {
                    case .chunk(let chunk):
                        appendChunk(chunk, to: assistantMessageID)
                    case .completed(let metrics):
                        updateGenerationMetrics(metrics, for: assistantMessageID)
                    }
                }
            } catch is CancellationError {
                if messageContent(for: assistantMessageID).isEmpty {
                    removeMessage(id: assistantMessageID)
                }
            } catch {
                removeMessage(id: assistantMessageID)
                errorMessage = error.localizedDescription
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
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let message = messages[index]
        messages[index] = ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content + chunk,
            generationMetrics: message.generationMetrics
        )
    }

    private func updateGenerationMetrics(_ metrics: ChatGenerationMetrics?, for messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let message = messages[index]
        messages[index] = ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            generationMetrics: metrics
        )
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    private func messageContent(for id: UUID) -> String {
        messages.first(where: { $0.id == id })?.content ?? ""
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
            messages.removeAll()
        }
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
    @Binding var generationSettings: ChatGenerationSettings
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

            Section("Generation") {
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

            VStack(alignment: .leading, spacing: 6) {
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
            .frame(maxWidth: 680, alignment: .leading)

            if message.role == .assistant {
                Spacer(minLength: 80)
            }
        }
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
    let canSend: Bool
    let isGenerating: Bool
    let errorMessage: String?
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("message-field")
                    .onSubmit(onSend)

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
