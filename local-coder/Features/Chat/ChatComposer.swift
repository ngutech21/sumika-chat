import LocalCoderCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
  @Binding var draft: String
  let attachments: [ChatAttachment]
  let activeAttachments: [ChatAttachment]
  let availableModels: [ManagedModel]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let interactionMode: WorkspaceInteractionMode
  let todoState: TodoState?
  let contextUsage: ChatContextUsage?
  let processUsage: ProcessResourceUsage?
  let canChangeModel: Bool
  let canChangeInteractionMode: Bool
  let canSend: Bool
  let isGenerating: Bool
  let isInputBlocked: Bool
  let errorMessage: String?
  let onSelectInteractionMode: (WorkspaceInteractionMode) -> Void
  let onSelectModel: (ManagedModel) -> Void
  let onLoadModel: () -> Void
  let onAddAttachments: () -> Void
  let onDropAttachments: ([URL]) -> Void
  let onRemoveAttachment: (ChatAttachment.ID) -> Void
  let onSend: () -> Void
  let onCancel: () -> Void
  @State private var isDropTarget = false
  @FocusState private var messageFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .font(.callout)
      }

      if shouldShowActiveAttachments {
        AttachmentList(
          title: "Active image context",
          attachments: activeAttachments,
          canRemove: !isGenerating,
          onRemoveAttachment: onRemoveAttachment
        )
      }

      if !visiblePendingAttachments.isEmpty {
        AttachmentList(
          title: nil,
          attachments: visiblePendingAttachments,
          canRemove: !isGenerating,
          onRemoveAttachment: onRemoveAttachment
        )
      }

      if let todoState {
        TodoPlanPanel(todoState: todoState)
          .frame(maxWidth: .infinity, alignment: .center)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      VStack(spacing: 8) {
        TextField("Message", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...5)
          .frame(minHeight: 36, alignment: .topLeading)
          .accessibilityIdentifier("message-field")
          .focused($messageFieldFocused)
          .disabled(isInputBlocked)
          .onSubmit(sendMessage)
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
          .disabled(isGenerating || isInputBlocked || modelState != .ready)
          .help("Add context files")
          .accessibilityLabel("Add context files")

          Menu {
            ForEach(availableModels) { model in
              Button {
                onSelectModel(model)
              } label: {
                if model.id == selectedModel.id {
                  Label(model.displayName, systemImage: "checkmark")
                } else {
                  Text(model.displayName)
                }
              }
            }
          } label: {
            HStack(spacing: 6) {
              Text(modelPickerTitle)
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 4)
              Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(width: 150, height: 22)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
          }
          .buttonStyle(.plain)
          .disabled(!canChangeModel)
          .help(modelPickerHelp)
          .accessibilityIdentifier("chat.modelPicker")

          if modelState != .ready {
            Button(action: onLoadModel) {
              if modelState == .loading {
                HStack(spacing: 6) {
                  ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("load-model-progress")
                  Text(modelLoadActionTitle)
                }
              } else {
                Label(modelLoadActionTitle, systemImage: "play.fill")
              }
            }
            .controlSize(.small)
            .disabled(!canLoadSelectedModel)
            .help(modelLoadHelp)
            .accessibilityIdentifier("load-model-button")
          }

          Picker("Mode", selection: interactionModeSelection) {
            ForEach(WorkspaceInteractionMode.allCases, id: \.self) { mode in
              Text(mode.displayName)
                .tag(mode)
                .accessibilityIdentifier("chat.mode.\(mode.rawValue)")
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 190)
          .controlSize(.small)
          .disabled(!canChangeInteractionMode)
          .help("Select interaction mode")
          .accessibilityIdentifier("chat.modePicker")

          ComposerResourceSummary(
            contextUsage: contextUsage,
            processUsage: processUsage
          )

          Spacer()

          Button(action: isGenerating ? onCancel : sendMessage) {
            Image(systemName: isGenerating ? "stop.fill" : "paperplane.fill")
              .frame(width: 16, height: 16)
          }
          .accessibilityIdentifier(isGenerating ? "cancel-generation-button" : "send-button")
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!isGenerating && !canSend)
          .frame(width: 28, height: 24)
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
    .onAppear {
      messageFieldFocused = true
    }
  }

  private var interactionModeSelection: Binding<WorkspaceInteractionMode> {
    Binding(
      get: { interactionMode },
      set: { mode in
        onSelectInteractionMode(mode)
      }
    )
  }

  private var visiblePendingAttachments: [ChatAttachment] {
    let activeAttachmentIDs = Set(activeAttachments.map(\.id))
    return attachments.filter { !activeAttachmentIDs.contains($0.id) }
  }

  private var shouldShowActiveAttachments: Bool {
    let hasDraftText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return !activeAttachments.isEmpty && (hasDraftText || !attachments.isEmpty)
  }

  private var canLoadSelectedModel: Bool {
    !availableModels.isEmpty && modelState != .loading && !isGenerating
  }

  private var modelLoadActionTitle: String {
    modelState == .loading ? "Loading" : "Load"
  }

  private var modelLoadHelp: String {
    availableModels.isEmpty
      ? "Download a model from Models first"
      : "Load selected model"
  }

  private var modelPickerHelp: String {
    availableModels.isEmpty
      ? "Download a model from Models first"
      : "Select model for this workspace"
  }

  private var modelPickerTitle: String {
    availableModels.isEmpty ? "No local models" : selectedModel.displayName
  }

  private func sendMessage() {
    guard canSend else {
      return
    }

    let submittedDraft = draft
    messageFieldFocused = false
    onSend()
    Task { @MainActor in
      if draft.isEmpty || draft == submittedDraft {
        draft = ""
      }
      messageFieldFocused = true
    }
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    guard !isGenerating, !isInputBlocked, modelState == .ready else {
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

  nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
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
          value: tokenValue,
          help: tokenHelp
        )
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var tokenValue: String? {
    guard let contextUsage else {
      return nil
    }

    let prefix = contextUsage.accuracy == .estimate ? "~" : ""
    let usedTokens = contextUsage.usedTokens.formatted(.number)
    guard let availableTokens = contextUsage.availableTokens else {
      return "\(prefix)\(usedTokens)"
    }

    return "\(prefix)\(usedTokens)/\(availableTokens.formatted(.number))"
  }

  private var tokenHelp: String? {
    guard let contextUsage, contextUsage.accuracy == .estimate || contextUsage.isStale else {
      return nil
    }

    return "Estimated tokens; exact count updates when idle."
  }
}

private struct ComposerMetric: View {
  let title: String
  let systemImage: String
  let value: String
  var help: String?

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
    .help(help ?? "")
  }
}

private struct AttachmentList: View {
  var title: String?
  let attachments: [ChatAttachment]
  let canRemove: Bool
  let onRemoveAttachment: (ChatAttachment.ID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let title {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(attachments) { attachment in
            AttachmentPreview(
              attachment: attachment,
              style: .pending,
              canRemove: canRemove,
              onRemove: onRemoveAttachment
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
