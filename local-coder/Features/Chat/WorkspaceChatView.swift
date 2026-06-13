import AppKit
import LocalCoderCore
import SwiftUI

struct WorkspaceChatView: View {
  @Bindable var controller: ChatSessionController
  let workspace: Workspace
  let sessionID: ChatSession.ID?
  let browserToolService: HTMLPreviewBrowserToolService
  @Binding var isModelContextDebugVisible: Bool
  @Binding var isWorkspaceTerminalVisible: Bool
  let onAddAttachments: () -> Void
  let onOpenWorkspaceInFinder: () -> Void
  let onOpenWorkspaceInVisualStudioCode: () -> Void
  @State private var htmlPreview: HTMLPreviewState?
  @State private var htmlPreviewRefreshID = UUID()
  @State private var htmlPreviewConsoleEntries: [HTMLPreviewConsoleEntry] = []
  @State private var filePreview: FilePreviewState?

  private let slashCommandParser = SlashCommandParser()
  private let htmlPreviewResolver = HTMLPreviewResolver()
  private let filePreviewResolver = FilePreviewResolver()

  private var onSend: () -> Void {
    {
      if handleLocalSlashCommand() {
        return
      }

      if let sessionID {
        controller.sendMessage(in: workspace, sessionID: sessionID)
      } else {
        controller.sendMessage(in: workspace)
      }
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        ChatTranscript(
          turns: controller.chatSession.turns,
          toolCalls: controller.chatSession.toolCalls,
          selectedModel: controller.modelRuntime.selectedModel,
          modelState: controller.modelRuntime.modelState,
          isGenerating: controller.isGenerating,
          onApproveToolCall: { toolCallID in
            controller.approveToolCall(id: toolCallID, in: workspace)
          },
          onDenyToolCall: { toolCallID in
            controller.denyToolCall(id: toolCallID)
          },
          onAnswerAskUser: { toolCallID, answer in
            controller.answerAskUserToolCall(id: toolCallID, answer: answer, in: workspace)
          }
        )

        ChatComposer(
          draft: $controller.draft,
          attachments: controller.chatSession.pendingAttachments,
          activeAttachments: controller.activeAttachmentContextAttachments,
          availableModels: downloadedModels,
          selectedModel: composerSelectedModel,
          modelState: controller.modelRuntime.modelState,
          interactionMode: controller.chatSession.interactionMode,
          todoState: visibleTodoState,
          contextUsage: controller.contextUsage,
          processUsage: controller.modelRuntime.processUsage,
          canChangeModel: !downloadedModels.isEmpty && !controller.isGenerating
            && controller.modelRuntime.canChangeModel,
          canChangeInteractionMode: controller.canChangeInteractionMode,
          canSend: controller.canSend || canRunSlashCommand,
          isGenerating: controller.isGenerating,
          isInputBlocked: controller.isInputBlocked,
          errorMessage: controller.errorMessage,
          onSelectInteractionMode: controller.setInteractionMode,
          onSelectModel: selectModel(_:),
          onLoadModel: loadSelectedModel,
          onAddAttachments: onAddAttachments,
          onDropAttachments: controller.addAttachments,
          onRemoveAttachment: controller.removeAttachment,
          onSend: onSend,
          onCancel: controller.cancelGeneration
        )
        .zIndex(1)

        if isWorkspaceTerminalVisible {
          WorkspaceTerminalPane(
            configuration: WorkspaceTerminalConfiguration(workspace: workspace),
            onClose: {
              isWorkspaceTerminalVisible = false
            }
          )
          .id(workspace.id)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let htmlPreview {
        HTMLPreviewPane(
          preview: htmlPreview,
          refreshID: htmlPreviewRefreshID,
          browserToolService: browserToolService,
          consoleEntries: htmlPreviewConsoleEntries,
          onConsoleMessage: { entry in
            Task { @MainActor in
              htmlPreviewConsoleEntries.append(entry)
            }
          },
          onRefresh: {
            htmlPreviewConsoleEntries.removeAll()
            htmlPreviewRefreshID = UUID()
          },
          onClose: {
            htmlPreviewConsoleEntries.removeAll()
            self.htmlPreview = nil
            Task {
              await browserToolService.clear()
            }
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }

      if let filePreview {
        FilePreviewPane(
          preview: filePreview,
          onClose: {
            self.filePreview = nil
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }

      if isModelContextDebugVisible {
        ModelContextDebugPane(
          controller: controller,
          workspace: workspace,
          sessionID: sessionID,
          onClose: {
            isModelContextDebugVisible = false
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .onDisappear {
      Task {
        await browserToolService.clear()
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          isWorkspaceTerminalVisible.toggle()
        } label: {
          Image(systemName: isWorkspaceTerminalVisible ? "terminal.fill" : "terminal")
        }
        .help(isWorkspaceTerminalVisible ? "Hide workspace terminal" : "Show workspace terminal")
        .accessibilityLabel(
          isWorkspaceTerminalVisible ? "Hide workspace terminal" : "Show workspace terminal"
        )
        .accessibilityIdentifier("workspace.terminalToggleButton")

        Button(action: onOpenWorkspaceInFinder) {
          Image(systemName: "folder")
        }
        .help("Open workspace in Finder")
        .accessibilityLabel("Open workspace in Finder")
        .accessibilityIdentifier("workspace.openInFinderButton")

        Button(action: onOpenWorkspaceInVisualStudioCode) {
          Image(systemName: "curlybraces")
        }
        .help("Open workspace in Visual Studio Code")
        .accessibilityLabel("Open workspace in Visual Studio Code")
        .accessibilityIdentifier("workspace.openInVSCodeButton")
      }
    }
  }

  private var canRunSlashCommand: Bool {
    !controller.isGenerating
      && !controller.isInputBlocked
      && slashCommandParser.parse(controller.draft) != nil
  }

  private var visibleTodoState: TodoState? {
    guard controller.chatSession.interactionMode == .agent,
      let todoState = controller.chatSession.todoState,
      !todoState.items.isEmpty
    else {
      return nil
    }
    return todoState
  }

  private var downloadedModels: [ManagedModel] {
    controller.modelRuntime.availableModels.filter { controller.modelRuntime.isModelDownloaded($0) }
  }

  private var composerSelectedModel: ManagedModel {
    if downloadedModels.contains(controller.modelRuntime.selectedModel) {
      return controller.modelRuntime.selectedModel
    }

    return downloadedModels.first ?? controller.modelRuntime.selectedModel
  }

  private func selectModel(_ model: ManagedModel) {
    guard !controller.isGenerating, controller.modelRuntime.canChangeModel else {
      return
    }

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.selectModel(model)
  }

  private func loadSelectedModel() {
    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    guard !downloadedModels.isEmpty else {
      controller.errorMessage = "Download a model from Models first."
      return
    }

    if !downloadedModels.contains(controller.modelRuntime.selectedModel),
      let downloadedModel = downloadedModels.first
    {
      controller.modelRuntime.selectModel(downloadedModel)
    }
    controller.modelRuntime.loadSelectedModel()
  }

  private func handleLocalSlashCommand() -> Bool {
    let trimmedDraft = controller.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedDraft.hasPrefix("/") else {
      return false
    }

    let name = String(trimmedDraft.dropFirst().prefix { !$0.isWhitespace })
    guard let descriptor = SlashCommandRegistry.descriptor(named: name) else {
      // Unknown command text: leave it for the normal send path.
      return false
    }

    guard let command = slashCommandParser.parse(trimmedDraft) else {
      controller.errorMessage = descriptor.usage
      return true
    }

    switch command {
    case .preview(let path):
      runPreviewCommand(path: path)
    case .show(let path):
      runShowCommand(path: path)
    }
    return true
  }

  private func runPreviewCommand(path: String) {
    do {
      htmlPreview = try htmlPreviewResolver.resolve(path: path, in: workspace)
      filePreview = nil
      htmlPreviewConsoleEntries.removeAll()
      controller.draft = ""
      controller.errorMessage = nil
    } catch {
      controller.errorMessage = error.localizedDescription
    }
  }

  private func runShowCommand(path: String) {
    do {
      filePreview = try filePreviewResolver.resolve(path: path, in: workspace)
      controller.draft = ""
      controller.errorMessage = nil
    } catch {
      controller.errorMessage = error.localizedDescription
    }
  }
}

private struct ModelContextDebugPane: View {
  @Bindable var controller: ChatSessionController
  let workspace: Workspace
  let sessionID: ChatSession.ID?
  let onClose: () -> Void
  @State private var didCopy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch documentResult {
      case .success(let document):
        header(for: document)
        RuntimeCacheDebugSection(snapshot: controller.runtimeCacheDebugSnapshot)
        Divider()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ModelContextDebugEntryView(entry: document.systemPrompt)
            ForEach(document.entries) { entry in
              ModelContextDebugEntryView(entry: entry)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .failure(let error):
        ContentUnavailableView(
          "Model Context Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(error.localizedDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(width: 380)
    .frame(maxHeight: .infinity)
    .background(.regularMaterial)
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityIdentifier("modelContextDebug.pane")
  }

  private var documentResult: Result<ModelContextDebugDocument, Error> {
    Result {
      try controller.modelContextDebugDocument(
        workspace: workspace,
        sessionID: sessionID
      )
    }
  }

  private func header(for document: ModelContextDebugDocument) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Projected Model Context")
            .font(.headline)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

          Text(document.signature)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(document.signature)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 8) {
          Button {
            copy(document.renderedContext)
          } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
          }
          .help(didCopy ? "Copied" : "Copy full context")
          .accessibilityLabel("Copy full model context")

          Button(action: onClose) {
            Image(systemName: "xmark")
          }
          .help("Hide model context debug")
          .accessibilityLabel("Hide model context debug")
        }
      }

      HStack(spacing: 12) {
        ModelContextDebugMetric(
          title: "Chars",
          value: document.totalCharacters.formatted(.number)
        )
        ModelContextDebugMetric(
          title: "Est. tokens",
          value: document.totalEstimatedTokens.formatted(.number)
        )
        ModelContextDebugMetric(
          title: "Entries",
          value: document.entries.count.formatted(.number)
        )
      }
    }
    .padding(16)
  }

  private func copy(_ context: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(context, forType: .string)
    didCopy = true

    Task {
      try? await Task.sleep(for: .seconds(1.2))
      didCopy = false
    }
  }
}

private struct ModelContextDebugMetric: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospacedDigit())
    }
  }
}

private struct RuntimeCacheDebugSection: View {
  let snapshot: RuntimeCacheDebugSnapshot?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("KV Cache")
        .font(.subheadline.weight(.semibold))

      if let snapshot {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Label(statusTitle(for: snapshot), systemImage: statusImage(for: snapshot))
              .font(.caption.weight(.semibold))
            Spacer()
            Text(snapshot.recordedAt, style: .time)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }

          RuntimeCacheDebugRow(title: "Reason", value: snapshot.cacheReason)
          RuntimeCacheDebugRow(title: "Mode", value: snapshot.cacheMode)
          RuntimeCacheDebugRow(title: "Reuse", value: reuseValue(for: snapshot))
          RuntimeCacheDebugRow(title: "Messages", value: messageValue(for: snapshot))
          RuntimeCacheDebugRow(title: "Mismatch", value: mismatchValue(for: snapshot))
          RuntimeCacheDebugRow(
            title: "System prompt",
            value: booleanValue(snapshot.systemPromptChanged)
          )
          RuntimeCacheDebugRow(
            title: "Prompt context",
            value: booleanValue(snapshot.currentPromptContextChanged)
          )
          RuntimeCacheDebugRow(title: "Signature", value: snapshot.contextSignature)
          if let previousContextSignature = snapshot.previousContextSignature {
            RuntimeCacheDebugRow(title: "Previous", value: previousContextSignature)
          }
        }
      } else {
        Text("No KV cache decision recorded yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }

  private func statusTitle(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    if snapshot.cacheReason == "append_only_delta_reused"
      || snapshot.reuseStrategy == "append_history_delta"
    {
      return "Append-only delta"
    }
    if snapshot.cacheMode == "session_reused" {
      return "Reused"
    }
    if snapshot.cacheMode == "new_session_history" {
      return "New session"
    }
    if snapshot.cacheMode.hasPrefix("invalidated_") {
      return "Invalidated"
    }
    return snapshot.cacheMode
  }

  private func statusImage(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    if snapshot.cacheMode == "session_reused" {
      return "bolt.horizontal.circle"
    }
    if snapshot.cacheMode == "new_session_history" {
      return "plus.circle"
    }
    if snapshot.cacheMode.hasPrefix("invalidated_") {
      return "exclamationmark.triangle"
    }
    return "memorychip"
  }

  private func reuseValue(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    guard let appendDeltaStartIndex = snapshot.appendDeltaStartIndex else {
      return snapshot.reuseStrategy
    }
    return "\(snapshot.reuseStrategy) @ \(appendDeltaStartIndex)"
  }

  private func messageValue(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    "reused \(snapshot.reusedMessageCount), appended \(snapshot.appendedMessageCount)"
  }

  private func mismatchValue(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    guard let mismatchReason = snapshot.mismatchReason else {
      return "none"
    }
    if let firstMismatchIndex = snapshot.firstMismatchIndex {
      return "\(mismatchReason) @ \(firstMismatchIndex)"
    }
    return mismatchReason
  }

  private func booleanValue(_ value: Bool?) -> String {
    switch value {
    case .some(true):
      "changed"
    case .some(false):
      "unchanged"
    case .none:
      "unknown"
    }
  }
}

private struct RuntimeCacheDebugRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 76, alignment: .leading)
      Text(value)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(value)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ModelContextDebugEntryView: View {
  let entry: ModelContextDebugEntry
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ScrollView(.horizontal) {
        Text(entry.content.isEmpty ? " " : entry.content)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(spacing: 10) {
        Label(entryTitle, systemImage: entry.role.systemImage)
          .font(.subheadline)
        Spacer()
        Text("\(entry.characterCount.formatted(.number)) chars")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Text("~\(entry.estimatedTokens.formatted(.number)) tokens")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private var entryTitle: String {
    if let index = entry.index {
      return "\(index). \(entry.role.title)"
    }
    return entry.role.title
  }
}

extension ModelContextDebugRole {
  fileprivate var title: String {
    switch self {
    case .system:
      "System"
    case .user:
      "User"
    case .assistant:
      "Assistant"
    case .toolFollowUpPrompt:
      "Tool follow-up prompt"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .system:
      "gearshape"
    case .user:
      "person"
    case .assistant:
      "cpu"
    case .toolFollowUpPrompt:
      "arrow.triangle.2.circlepath"
    }
  }
}
