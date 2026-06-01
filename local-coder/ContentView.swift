import AppKit
import SwiftUI

struct ContentView: View {
    @State private var modelPath = LocalModelDirectory.defaultModelURL.path(percentEncoded: false)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var modelState: ModelLoadState = .notLoaded
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private let runtime: any ChatModelRuntime = GemmaMLXRuntime()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModelSidebar(
                modelPath: $modelPath,
                modelState: modelState,
                isLoading: modelState == .loading,
                onChooseModelDirectory: chooseModelDirectory,
                onLoad: loadModel
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                ChatTranscript(messages: messages, isGenerating: isGenerating)

                Divider()

                ChatComposer(
                    draft: $draft,
                    canSend: canSend,
                    errorMessage: errorMessage,
                    onSend: sendMessage
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
        isGenerating = true

        Task {
            do {
                let reply = try await runtime.generateReply(for: messages)
                messages.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                errorMessage = error.localizedDescription
            }

            isGenerating = false
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
        }
        .listStyle(.sidebar)
        .navigationTitle("Runtime")
    }
}

private struct ChatTranscript: View {
    let messages: [ChatMessage]
    let isGenerating: Bool

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

                    if isGenerating {
                        Label("Generating", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
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

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(message.role.title, systemImage: message.role.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: 680, alignment: .leading)

            if message.role == .assistant {
                Spacer(minLength: 80)
            }
        }
    }
}

private struct ChatComposer: View {
    @Binding var draft: String
    let canSend: Bool
    let errorMessage: String?
    let onSend: () -> Void

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

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                }
                .accessibilityIdentifier("send-button")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send")
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
