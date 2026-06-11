import AppKit
import LocalCoderCore
import SwiftUI

struct WorkspaceChatView: View {
  @Bindable var controller: ChatSessionController
  let workspace: Workspace
  let sessionID: ChatSession.ID?
  let browserToolService: HTMLPreviewBrowserToolService
  @Binding var isModelContextDebugVisible: Bool
  let onAddAttachments: () -> Void
  @State private var htmlPreview: HTMLPreviewState?
  @State private var htmlPreviewRefreshID = UUID()
  @State private var htmlPreviewConsoleEntries: [HTMLPreviewConsoleEntry] = []
  private let slashCommandParser = SlashCommandParser()
  private let htmlPreviewResolver = HTMLPreviewResolver()

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
          canSend: controller.canSend || canRunPreviewCommand,
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
  }

  private var canRunPreviewCommand: Bool {
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
    guard trimmedDraft.hasPrefix("/preview") else {
      return false
    }

    guard case .preview(let path) = slashCommandParser.parse(trimmedDraft) else {
      controller.errorMessage = "Usage: /preview <path-to-html-file>"
      return true
    }

    do {
      htmlPreview = try htmlPreviewResolver.resolve(path: path, in: workspace)
      htmlPreviewConsoleEntries.removeAll()
      controller.draft = ""
      controller.errorMessage = nil
    } catch {
      controller.errorMessage = error.localizedDescription
    }
    return true
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
    }
  }
}
