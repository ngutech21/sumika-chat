import SwiftUI

struct ContentView: View {
    @State private var modelID = "mlx-community/gemma-3-1b-it-qat-4bit"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var modelState: ModelLoadState = .notLoaded
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private let runtime: any ChatModelRuntime = MockChatRuntime()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModelSidebar(
                modelID: $modelID,
                modelState: modelState,
                isLoading: modelState == .loading,
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
        }
    }

    private var canSend: Bool {
        modelState == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private func loadModel() {
        Task {
            errorMessage = nil
            modelState = .loading

            do {
                try await runtime.load(modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines))
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
}

private struct ModelSidebar: View {
    @Binding var modelID: String
    let modelState: ModelLoadState
    let isLoading: Bool
    let onLoad: () -> Void

    var body: some View {
        List {
            Section("Model") {
                TextField("Model ID", text: $modelID)
                    .textFieldStyle(.roundedBorder)

                Button(action: onLoad) {
                    Label(isLoading ? "Loading" : "Load Mock", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("load-model-button")
                .disabled(isLoading || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
                        description: Text("Load the mock runtime to start a local coding chat.")
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
            "No runtime loaded"
        case .loading:
            "Loading runtime"
        case .ready:
            "Mock runtime ready"
        case .failed:
            "Runtime failed"
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

#Preview {
    ContentView()
}
