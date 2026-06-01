import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var controller: ChatSessionController

    @MainActor
    init() {
        _controller = State(initialValue: ChatSessionController())
    }

    @MainActor
    init(controller: ChatSessionController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        @Bindable var controller = controller

        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModelSidebar(
                modelPath: $controller.modelPath,
                systemPrompt: $controller.chatSession.systemPrompt,
                generationSettings: $controller.chatSession.generationSettings,
                contextUsage: controller.contextUsage,
                modelState: controller.modelState,
                isLoading: controller.modelState == .loading,
                onChooseModelDirectory: chooseModelDirectory,
                onLoad: controller.loadModel,
                onUnload: controller.unloadModel
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                ChatTranscript(messages: controller.chatSession.messages)

                Divider()

                ChatComposer(
                    draft: $controller.draft,
                    attachments: controller.chatSession.attachments,
                    canSend: controller.canSend,
                    isGenerating: controller.isGenerating,
                    errorMessage: controller.errorMessage,
                    onAddAttachments: chooseAttachments,
                    onDropAttachments: controller.addAttachments,
                    onRemoveAttachment: controller.removeAttachment,
                    onSend: controller.sendMessage,
                    onCancel: controller.cancelGeneration
                )
            }
            .navigationTitle("Local Coder")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 560)
        .onChange(of: controller.chatSession.systemPrompt) {
            controller.refreshContextUsage()
        }
        .onChange(of: controller.draft) {
            controller.convertDroppedFilePathsInDraft()
        }
        .onAppear {
            columnVisibility = .all
            controller.prepareDefaultModelDirectory()
        }
    }

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: controller.modelPath, directoryHint: .isDirectory)
        panel.message = "Choose a local MLX Gemma model directory."
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            controller.setModelDirectory(url)
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
            controller.addAttachments(from: panel.urls)
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
    let onUnload: () -> Void

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

                    Button(action: modelState == .ready ? onUnload : onLoad) {
                        Label(modelActionTitle, systemImage: modelActionSystemImage)
                    }
                    .accessibilityIdentifier(modelState == .ready ? "unload-model-button" : "load-model-button")
                    .disabled(isLoading || (modelState != .ready && modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
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

    private var modelActionTitle: String {
        switch modelState {
        case .ready:
            "Unload Model"
        case .loading:
            "Loading"
        case .notLoaded, .failed:
            "Load Model"
        }
    }

    private var modelActionSystemImage: String {
        switch modelState {
        case .ready:
            "eject"
        case .loading, .notLoaded, .failed:
            "square.and.arrow.down"
        }
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

private extension ModelLoadState {
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
