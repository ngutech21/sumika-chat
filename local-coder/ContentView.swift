// swiftlint:disable file_length
import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: AppNavigationSelection?
    @State private var appState: AppState

    @MainActor
    init() {
        _appState = State(initialValue: AppState())
    }

    @MainActor
    init(controller: ChatSessionController) {
        _appState = State(initialValue: AppState(chatController: controller))
    }

    @MainActor
    init(appState: AppState) {
        _appState = State(initialValue: appState)
    }

    var body: some View {
        let controller = appState.chatController

        NavigationSplitView(columnVisibility: $columnVisibility) {
            AppSidebar(
                appState: appState,
                selection: $selection,
                onAddWorkspace: chooseWorkspace
            )
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let selection {
                switch selection {
                case .models:
                    ModelsView(controller: controller)
                        .navigationTitle("Models")
                case .session:
                    if let workspace = appState.activeWorkspace {
                        WorkspaceChatView(controller: controller, onAddAttachments: chooseAttachments)
                            .navigationTitle(workspace.name)
                    } else {
                        EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
                            .navigationTitle("Local Coder")
                    }
                }
            } else {
                EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
                    .navigationTitle("Local Coder")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 560)
        .onChange(of: controller.chatSession.systemPrompt) {
            controller.refreshContextUsage()
            appState.persistActiveSession()
        }
        .onChange(of: controller.chatSession.generationSettings) {
            appState.persistActiveSession()
        }
        .onChange(of: controller.draft) {
            controller.convertDroppedFilePathsInDraft()
        }
        .onChange(of: selection) {
            if case .session(let sessionID) = selection {
                appState.selectSession(sessionID)
            }
        }
        .onChange(of: appState.activeSessionID) {
            if let sessionID = appState.activeSessionID {
                selection = .session(sessionID)
            } else if selection != .models {
                selection = nil
            }
        }
        .onAppear {
            columnVisibility = .all
            controller.prepareDefaultModelDirectory()
            controller.startResourceMonitoring()
            if let sessionID = appState.activeSessionID {
                selection = .session(sessionID)
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a folder to use as a local-coder workspace."
        panel.prompt = "Add Workspace"

        if panel.runModal() == .OK, let url = panel.url,
           let sessionID = appState.addWorkspace(from: url) {
            selection = .session(sessionID)
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
            appState.chatController.addAttachments(from: panel.urls)
        }
    }
}

private enum AppNavigationSelection: Hashable {
    case models
    case session(CodingSession.ID)
}

private struct AppSidebar: View {
    let appState: AppState
    @Binding var selection: AppNavigationSelection?
    let onAddWorkspace: () -> Void
    @State private var sessionBeingRenamed: CodingSession?
    @State private var sessionPendingDeletion: CodingSession?
    @State private var renameTitle = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: AppNavigationSelection.models) {
                    Label("Models", systemImage: "cpu")
                }
            }

            Section {
                Button(action: onAddWorkspace) {
                    Label("Add Workspace", systemImage: "folder.badge.plus")
                }
            }

            ForEach(appState.workspaceLibrary.workspaces) { workspace in
                Section(workspace.name) {
                    ForEach(workspace.sessions) { session in
                        NavigationLink(value: AppNavigationSelection.session(session.id)) {
                            Label(session.title, systemImage: "bubble.left.and.bubble.right")
                        }
                        .contextMenu {
                            Button("Rename") {
                                sessionBeingRenamed = session
                                renameTitle = session.title
                            }

                            Button("Delete", role: .destructive) {
                                sessionPendingDeletion = session
                            }
                        }
                    }

                    Button {
                        if let sessionID = appState.createSession(in: workspace.id) {
                            selection = .session(sessionID)
                        }
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("local-coder")
        .alert("Rename Session", isPresented: renameAlertBinding) {
            TextField("Session name", text: $renameTitle)

            Button("Cancel", role: .cancel) {
                sessionBeingRenamed = nil
                renameTitle = ""
            }

            Button("Rename") {
                if let sessionBeingRenamed {
                    appState.renameSession(sessionBeingRenamed.id, title: renameTitle)
                }
                sessionBeingRenamed = nil
                renameTitle = ""
            }
        }
        .alert("Delete Session?", isPresented: deleteAlertBinding, presenting: sessionPendingDeletion) { session in
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }

            Button("Delete", role: .destructive) {
                appState.deleteSession(session.id)
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("This permanently removes “\(session.title)” and its saved chat history.")
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { sessionBeingRenamed != nil },
            set: { isPresented in
                if !isPresented {
                    sessionBeingRenamed = nil
                    renameTitle = ""
                }
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { sessionPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    sessionPendingDeletion = nil
                }
            }
        )
    }
}

private struct EmptyWorkspaceView: View {
    let onAddWorkspace: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Workspace", systemImage: "folder")
        } description: {
            Text("Choose a folder to start a local coding session.")
        } actions: {
            Button(action: onAddWorkspace) {
                Label("Add Workspace", systemImage: "folder.badge.plus")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModelsView: View {
    @Bindable var controller: ChatSessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Models")
                        .font(.title2.weight(.semibold))
                    Text(
                        "Choose a local Gemma 3 model. Downloads are explicit so you stay in control of storage and network use."
                    )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 720, alignment: .leading)
                }

                VStack(spacing: 10) {
                    ForEach(controller.availableModels) { model in
                        ManagedModelRow(
                            model: model,
                            isSelected: controller.selectedModelID == model.id,
                            isActive: controller.selectedModelID == model.id && controller.modelState == .ready,
                            isDownloaded: controller.isModelDownloaded(model),
                            downloadState: controller.selectedModelID == model.id
                                ? controller.downloadState : .idle,
                            canSelect: controller.canChangeModel,
                            onSelect: {
                                controller.selectModel(model)
                            }
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.selectedModel.displayName)
                                .font(.headline)
                            Text(selectedModelStatusText)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button {
                            controller.downloadSelectedModel()
                        } label: {
                            Label("Download", systemImage: "square.and.arrow.down")
                        }
                        .disabled(
                            !controller.canChangeModel
                                || controller.downloadState.isDownloading
                                || controller.isModelDownloaded(controller.selectedModel))

                        Button {
                            controller.modelState == .ready
                                ? controller.unloadModel() : controller.loadSelectedModel()
                        } label: {
                            Label(modelActionTitle, systemImage: modelActionSystemImage)
                        }
                        .accessibilityIdentifier(
                            controller.modelState == .ready ? "unload-model-button" : "load-model-button"
                        )
                        .disabled(isModelActionDisabled)
                    }

                    if case .downloading(let progress) = controller.downloadState {
                        DownloadProgressView(progress: progress)
                    }

                    ModelRuntimeStatus(
                        modelState: controller.modelState,
                        downloadState: effectiveDownloadState,
                        contextUsage: controller.contextUsage,
                        processUsage: controller.processUsage
                    )

                    if let errorMessage = controller.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                DisclosureGroup("Details") {
                    ModelAdvancedSettings(
                        model: controller.selectedModel,
                        systemPrompt: $controller.chatSession.systemPrompt,
                        generationSettings: $controller.chatSession.generationSettings
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }

    private var selectedModelStatusText: String {
        if controller.selectedModel.requiresLargeMemory {
            return "\(controller.selectedModel.estimatedDownloadSize), needs a lot of memory"
        }

        return
            "\(controller.selectedModel.estimatedDownloadSize), \(controller.selectedModel.summary.lowercased())"
    }

    private var effectiveDownloadState: ModelDownloadState {
        if controller.isModelDownloaded(controller.selectedModel),
           !controller.downloadState.isDownloading {
            return .downloaded
        }

        return controller.downloadState
    }

    private var modelActionTitle: String {
        controller.modelState == .ready ? "Unload" : "Load"
    }

    private var modelActionSystemImage: String {
        controller.modelState == .ready ? "eject" : "play.fill"
    }

    private var isModelActionDisabled: Bool {
        controller.modelState == .loading
            || controller.downloadState.isDownloading
            || (controller.modelState != .ready
                && !controller.isModelDownloaded(controller.selectedModel))
    }
}

private struct DownloadProgressView: View {
    let progress: Double?

    var body: some View {
        if let progress {
            ProgressView(value: progress) {
                Text("Downloading model")
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
        } else {
            ProgressView {
                Text("Preparing download")
            }
        }
    }
}

private struct ResourceUsageRow: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ManagedModelRow: View {
    let model: ManagedModel
    let isSelected: Bool
    let isActive: Bool
    let isDownloaded: Bool
    let downloadState: ModelDownloadState
    let canSelect: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(.headline)

                        if model.isRecommended {
                            Text("Recommended")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        if model.requiresLargeMemory {
                            Label("High memory", systemImage: "memorychip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(model.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.estimatedDownloadSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusTint)
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!canSelect && !isSelected)
    }

    private var statusText: String {
        if isActive {
            return "Active"
        }

        switch downloadState {
        case .downloading(let progress):
            guard let progress else {
                return "Downloading"
            }
            return progress.formatted(.percent.precision(.fractionLength(0)))
        case .failed:
            return "Failed"
        case .downloaded:
            return "Ready"
        case .idle:
            return isDownloaded ? "Ready" : "Not downloaded"
        }
    }

    private var statusTint: Color {
        if isActive || isDownloaded {
            return .green
        }

        if case .failed = downloadState {
            return .red
        }

        return .secondary
    }
}

private struct ModelRuntimeStatus: View {
    let modelState: ModelLoadState
    let downloadState: ModelDownloadState
    let contextUsage: ChatContextUsage?
    let processUsage: ProcessResourceUsage?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                StatusValue(
                    title: "Runtime", systemImage: modelState.systemImage, value: modelState.label,
                    tint: modelState.tint)
                StatusValue(
                    title: "Download", systemImage: "arrow.down.circle", value: downloadState.label,
                    tint: downloadTint)
            }

            GridRow {
                StatusValue(
                    title: "Context",
                    systemImage: "rectangle.stack",
                    value: contextUsage?.summary ?? "Not loaded",
                    tint: .secondary
                )
                StatusValue(
                    title: "Memory",
                    systemImage: "memorychip",
                    value: processUsage?.memorySummary ?? "Measuring",
                    tint: .secondary
                )
            }
        }
        .font(.callout)
    }

    private var downloadTint: Color {
        switch downloadState {
        case .downloaded:
            .green
        case .failed:
            .red
        case .idle, .downloading:
            .secondary
        }
    }
}

private struct StatusValue: View {
    let title: String
    let systemImage: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ModelAdvancedSettings: View {
    let model: ManagedModel
    @Binding var systemPrompt: String
    @Binding var generationSettings: ChatGenerationSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("Hugging Face") {
                Text(model.huggingFaceRepoID)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Local Folder") {
                Text(model.localPath)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("System Prompt", systemImage: "text.quote")
                TextField("System Prompt", text: $systemPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...8)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Creativity", systemImage: "thermometer.variable")
                    Spacer()
                    Text(generationSettings.temperature.formatted(.number.precision(.fractionLength(1))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $generationSettings.temperature, in: 0...2, step: 0.1)
            }

            Stepper(value: $generationSettings.maxTokens, in: 128...8192, step: 128) {
                SettingValueLabel(title: "Response Length", value: "\(generationSettings.maxTokens)")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Technical Generation")
                    .font(.headline)

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
            }

            Button("Coding Defaults") {
                systemPrompt = model.defaultSystemPrompt
                generationSettings = model.defaultGenerationSettings
            }
        }
        .padding(.top, 10)
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

private struct WorkspaceChatView: View {
    @Bindable var controller: ChatSessionController
    let onAddAttachments: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscript(
                messages: controller.chatSession.messages,
                selectedModel: controller.selectedModel,
                modelState: controller.modelState
            )

            Divider()

            ChatComposer(
                draft: $controller.draft,
                attachments: controller.chatSession.attachments,
                availableModels: controller.availableModels,
                selectedModel: controller.selectedModel,
                modelState: controller.modelState,
                contextUsage: controller.contextUsage,
                processUsage: controller.processUsage,
                canChangeModel: controller.canChangeModel,
                isSelectedModelDownloaded: controller.isModelDownloaded(controller.selectedModel),
                canSend: controller.canSend,
                isGenerating: controller.isGenerating,
                errorMessage: controller.errorMessage,
                onSelectModel: controller.selectModel,
                onLoadModel: controller.loadSelectedModel,
                onAddAttachments: onAddAttachments,
                onDropAttachments: controller.addAttachments,
                onRemoveAttachment: controller.removeAttachment,
                onSend: controller.sendMessage,
                onCancel: controller.cancelGeneration
            )
        }
    }
}

private struct ChatTranscript: View {
    let messages: [ChatMessage]
    let selectedModel: ManagedModel
    let modelState: ModelLoadState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if messages.isEmpty {
                    ContentUnavailableView(
                        emptyStateTitle,
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(emptyStateDescription)
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

    private var emptyStateTitle: String {
        switch modelState {
        case .ready:
            "\(selectedModel.displayName) Ready"
        case .loading:
            "Loading Model"
        case .failed:
            "Model Not Ready"
        case .notLoaded:
            "No Model Loaded"
        }
    }

    private var emptyStateDescription: String {
        switch modelState {
        case .ready:
            "Send a prompt with \(selectedModel.displayName) to start chatting."
        case .loading:
            "Loading \(selectedModel.displayName). You can write a prompt once it is ready."
        case .failed:
            "Loading failed. Select or load a model below before writing a prompt."
        case .notLoaded:
            "Select and load a Gemma model below before writing a prompt."
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
                        .background(messageBubbleBackground)
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
        if message.role == .assistant {
            Markdown(AssistantMarkdownPreprocessor.renderableContent(for: message.content))
                .markdownTheme(.chatMessage)
                .markdownCodeSyntaxHighlighter(ChatCodeSyntaxHighlighter())
        } else {
            Text(message.content)
        }
    }
}

private struct ChatCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        switch language?.lowercased() {
        case "html", "xml":
            return highlightHTML(code)
        case "css":
            return highlightCSS(code)
        case "json":
            return highlightJSON(code)
        case "bash", "sh", "shell", "zsh":
            return highlightShell(code)
        case "diff", "patch":
            return highlightDiff(code)
        default:
            return Text(code)
        }
    }

    private func highlightHTML(_ code: String) -> Text {
        var result = Text("")
        var currentIndex = code.startIndex

        while currentIndex < code.endIndex {
            if code[currentIndex...].lowercased().hasPrefix("<style"),
                let openTagEnd = code[currentIndex...].firstIndex(of: ">"),
                let closeTagRange = code[openTagEnd...].range(of: "</style>", options: .caseInsensitive) {
                result = append(result, highlightHTMLTag(String(code[currentIndex...openTagEnd])))
                let styleContent = String(code[code.index(after: openTagEnd)..<closeTagRange.lowerBound])
                result = append(result, highlightCSS(styleContent))
                result = append(result, highlightHTMLTag(String(code[closeTagRange])))
                currentIndex = closeTagRange.upperBound
            } else if code[currentIndex] == "<",
                let tagEnd = code[currentIndex...].firstIndex(of: ">") {
                result = append(result, highlightHTMLTag(String(code[currentIndex...tagEnd])))
                currentIndex = code.index(after: tagEnd)
            } else {
                let nextTag = code[currentIndex...].firstIndex(of: "<") ?? code.endIndex
                result = append(result, Text(String(code[currentIndex..<nextTag])))
                currentIndex = nextTag
            }
        }

        return result
    }

    private func highlightHTMLTag(_ tag: String) -> Text {
        if tag.hasPrefix("<!--") {
            return Text(tag).foregroundColor(.secondary)
        }

        var result = Text("")
        var currentIndex = tag.startIndex

        while currentIndex < tag.endIndex {
            let character = tag[currentIndex]

            if character == "<" || character == ">" || character == "/" || character == "!" {
                result = append(result, Text(String(character)).foregroundColor(.secondary))
                currentIndex = tag.index(after: currentIndex)
            } else if character == "\"" || character == "'" {
                let quote = character
                let startIndex = currentIndex
                currentIndex = tag.index(after: currentIndex)

                while currentIndex < tag.endIndex && tag[currentIndex] != quote {
                    currentIndex = tag.index(after: currentIndex)
                }

                if currentIndex < tag.endIndex {
                    currentIndex = tag.index(after: currentIndex)
                }

                result = append(result, Text(String(tag[startIndex..<currentIndex])).foregroundColor(.green))
            } else if character.isLetter || character == "-" {
                let startIndex = currentIndex

                while currentIndex < tag.endIndex,
                    tag[currentIndex].isLetter || tag[currentIndex].isNumber || tag[currentIndex] == "-" {
                    currentIndex = tag.index(after: currentIndex)
                }

                result = append(result, Text(String(tag[startIndex..<currentIndex])).foregroundColor(.cyan))
            } else {
                result = append(result, Text(String(character)))
                currentIndex = tag.index(after: currentIndex)
            }
        }

        return result
    }

    private func highlightCSS(_ code: String) -> Text {
        var result = Text("")
        var currentIndex = code.startIndex

        while currentIndex < code.endIndex {
            if code[currentIndex...].hasPrefix("/*"),
                let commentEnd = code[currentIndex...].range(of: "*/") {
                result = append(
                    result,
                    Text(String(code[currentIndex..<commentEnd.upperBound])).foregroundColor(.secondary)
                )
                currentIndex = commentEnd.upperBound
            } else if code[currentIndex] == "\"" || code[currentIndex] == "'" {
                let quote = code[currentIndex]
                let startIndex = currentIndex
                currentIndex = code.index(after: currentIndex)

                while currentIndex < code.endIndex && code[currentIndex] != quote {
                    currentIndex = code.index(after: currentIndex)
                }

                if currentIndex < code.endIndex {
                    currentIndex = code.index(after: currentIndex)
                }

                result = append(result, Text(String(code[startIndex..<currentIndex])).foregroundColor(.green))
            } else if code[currentIndex].isLetter || code[currentIndex] == "-" || code[currentIndex] == "#" {
                let startIndex = currentIndex

                while currentIndex < code.endIndex,
                    code[currentIndex].isLetter
                        || code[currentIndex].isNumber
                        || code[currentIndex] == "-"
                        || code[currentIndex] == "#"
                        || code[currentIndex] == "." {
                    currentIndex = code.index(after: currentIndex)
                }

                let token = String(code[startIndex..<currentIndex])
                let nextNonWhitespace = code[currentIndex...].first { !$0.isWhitespace }
                let color: Color = nextNonWhitespace == ":" ? .purple : .cyan
                result = append(result, Text(token).foregroundColor(color))
            } else if code[currentIndex].isNumber {
                let startIndex = currentIndex

                while currentIndex < code.endIndex,
                    code[currentIndex].isNumber || code[currentIndex] == "." || code[currentIndex] == "%" {
                    currentIndex = code.index(after: currentIndex)
                }

                result = append(result, Text(String(code[startIndex..<currentIndex])).foregroundColor(.orange))
            } else {
                result = append(result, Text(String(code[currentIndex])))
                currentIndex = code.index(after: currentIndex)
            }
        }

        return result
    }

    private func highlightJSON(_ code: String) -> Text {
        var result = Text("")
        var currentIndex = code.startIndex

        while currentIndex < code.endIndex {
            if code[currentIndex] == "\"" {
                let startIndex = currentIndex
                currentIndex = code.index(after: currentIndex)

                while currentIndex < code.endIndex {
                    if code[currentIndex] == "\\" {
                        currentIndex = code.index(after: currentIndex)
                    } else if code[currentIndex] == "\"" {
                        currentIndex = code.index(after: currentIndex)
                        break
                    }

                    if currentIndex < code.endIndex {
                        currentIndex = code.index(after: currentIndex)
                    }
                }

                let nextNonWhitespace = code[currentIndex...].first { !$0.isWhitespace }
                let color: Color = nextNonWhitespace == ":" ? .cyan : .green
                result = append(result, Text(String(code[startIndex..<currentIndex])).foregroundColor(color))
            } else if code[currentIndex].isNumber || code[currentIndex] == "-" {
                let startIndex = currentIndex

                while currentIndex < code.endIndex,
                    code[currentIndex].isNumber || code[currentIndex] == "." || code[currentIndex] == "-" {
                    currentIndex = code.index(after: currentIndex)
                }

                result = append(result, Text(String(code[startIndex..<currentIndex])).foregroundColor(.orange))
            } else {
                result = append(result, Text(String(code[currentIndex])))
                currentIndex = code.index(after: currentIndex)
            }
        }

        return result
    }

    private func append(_ base: Text, _ next: Text) -> Text {
        base + next
    }

    private func highlightShell(_ code: String) -> Text {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(Text("")) { partialResult, line in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                    partialResult + Text(line).foregroundColor(.secondary) + Text("\n")
                } else {
                    partialResult + Text(line) + Text("\n")
                }
            }
    }

    private func highlightDiff(_ code: String) -> Text {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(Text("")) { partialResult, line in
                if line.hasPrefix("+") {
                    partialResult + Text(line).foregroundColor(.green) + Text("\n")
                } else if line.hasPrefix("-") {
                    partialResult + Text(line).foregroundColor(.red) + Text("\n")
                } else {
                    partialResult + Text(line) + Text("\n")
                }
            }
    }
}

extension Theme {
    fileprivate static let chatMessage = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            ForegroundColor(.primary)
            BackgroundColor(.secondary.opacity(0.16))
        }
        .link {
            ForegroundColor(.accentColor)
            UnderlineStyle(.single)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                configuration.label
                    .padding(.leading, 8)
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
            }
            .markdownMargin(top: 4, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.92))
                        BackgroundColor(nil)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .markdownMargin(top: 4, bottom: 8)
        }
}

extension ChatGenerationMetrics {
    fileprivate var summary: String {
        "\(generatedTokenCount) tokens · \(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tokens/s"
    }
}

extension ChatBubble {
    fileprivate var messageBubbleBackground: Color {
        message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)
    }
}

private struct ChatComposer: View {
    @Binding var draft: String
    let attachments: [ChatAttachment]
    let availableModels: [ManagedModel]
    let selectedModel: ManagedModel
    let modelState: ModelLoadState
    let contextUsage: ChatContextUsage?
    let processUsage: ProcessResourceUsage?
    let canChangeModel: Bool
    let isSelectedModelDownloaded: Bool
    let canSend: Bool
    let isGenerating: Bool
    let errorMessage: String?
    let onSelectModel: (ManagedModel) -> Void
    let onLoadModel: () -> Void
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

            VStack(spacing: 8) {
                ComposerResourceSummary(
                    contextUsage: contextUsage,
                    processUsage: processUsage
                )

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .frame(minHeight: 36, alignment: .topLeading)
                    .accessibilityIdentifier("message-field")
                    .disabled(modelState != .ready || isGenerating)
                    .onSubmit(onSend)
                    .onDrop(
                        of: [UTType.fileURL.identifier],
                        isTargeted: $isDropTarget,
                        perform: handleDrop
                    )

                HStack(spacing: 8) {
                    Button(action: onAddAttachments) {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(isGenerating || modelState != .ready)
                    .help("Add context files")
                    .accessibilityLabel("Add context files")

                    Picker("Model", selection: modelSelection) {
                        ForEach(availableModels) { model in
                            Text(model.displayName)
                                .tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .controlSize(.small)
                    .disabled(!canChangeModel)
                    .help("Select model for this workspace")

                    if modelState != .ready {
                        Button(action: onLoadModel) {
                            Label(modelLoadActionTitle, systemImage: "play.fill")
                        }
                        .controlSize(.small)
                        .disabled(!canLoadSelectedModel)
                        .help(modelLoadHelp)
                    }

                    Spacer()

                    Button(action: isGenerating ? onCancel : onSend) {
                        Image(systemName: isGenerating ? "stop.fill" : "paperplane.fill")
                    }
                    .accessibilityIdentifier(isGenerating ? "cancel-generation-button" : "send-button")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isGenerating && !canSend)
                    .help(isGenerating ? "Cancel" : "Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
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

    private var modelSelection: Binding<ManagedModel.ID> {
        Binding(
            get: { selectedModel.id },
            set: { modelID in
                guard let model = availableModels.first(where: { $0.id == modelID }) else {
                    return
                }

                onSelectModel(model)
            }
        )
    }

    private var canLoadSelectedModel: Bool {
        modelState != .loading && !isGenerating && isSelectedModelDownloaded
    }

    private var modelLoadActionTitle: String {
        modelState == .loading ? "Loading" : "Load"
    }

    private var modelLoadHelp: String {
        isSelectedModelDownloaded
            ? "Load selected model"
            : "Download this model from Models first"
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isGenerating, modelState == .ready else {
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

private struct ComposerResourceSummary: View {
    let contextUsage: ChatContextUsage?
    let processUsage: ProcessResourceUsage?

    var body: some View {
        HStack(spacing: 12) {
            ComposerMetric(
                title: "RAM",
                systemImage: "memorychip",
                value: processUsage?.memorySummary ?? "Measuring"
            )

            ComposerMetric(
                title: "CPU",
                systemImage: "cpu",
                value: processUsage?.cpuSummary ?? "Measuring"
            )

            if let tokenValue {
                ComposerMetric(
                    title: "Tokens",
                    systemImage: "rectangle.stack",
                    value: tokenValue
                )
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var tokenValue: String? {
        guard let contextUsage else {
            return nil
        }

        let usedTokens = contextUsage.usedTokens.formatted(.number)
        guard let availableTokens = contextUsage.availableTokens else {
            return usedTokens
        }

        return "\(usedTokens)/\(availableTokens.formatted(.number))"
    }
}

private struct ComposerMetric: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(title)
                Text(value)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .lineLimit(1)
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

extension ModelLoadState {
    fileprivate var tint: Color {
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
