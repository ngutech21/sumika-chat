import AppKit
import SumikaCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
  let attachments: [ChatAttachment]
  let activeAttachments: [ChatAttachment]
  let availableModels: [ManagedModel]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let interactionMode: WorkspaceInteractionMode
  let todoState: TodoState?
  let contextUsage: ChatContextUsage?
  let canChangeModel: Bool
  let canChangeInteractionMode: Bool
  let canSend: Bool
  let canRunLocalCommand: Bool
  let isGenerating: Bool
  let isInputBlocked: Bool
  let errorMessage: String?
  let onSelectInteractionMode: (WorkspaceInteractionMode) -> Void
  let onSelectModel: (ManagedModel) -> Void
  let onLoadModel: () -> Void
  let onAddAttachments: () -> Void
  let onDropAttachments: ([URL]) -> Void
  let onRemoveAttachment: (ChatAttachment.ID) -> Void
  let onSend: (String) -> Bool
  let onCancel: () -> Void
  @State private var draft = ""
  @State private var slashSelectionIndex = 0
  @State private var slashSuggestionsDismissed = false
  @State private var showModelPicker = false
  @State private var isDropTarget = false

  private let slashCommandParser = SlashCommandParser()

  var body: some View {
    let suggestions = slashSuggestions
    let selectedSlashIndex = clampedSlashIndex(for: suggestions)
    let canSubmitDraft = canSendCurrentDraft
    let canActivateSend = isGenerating || canSubmitDraft

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

      if !suggestions.isEmpty {
        SlashCommandSuggestionList(
          suggestions: suggestions,
          selectedIndex: selectedSlashIndex,
          onSelect: acceptSlashSuggestion,
          onHighlight: { slashSelectionIndex = $0 }
        )
        .transition(.opacity)
      }

      VStack(spacing: 8) {
        TextField("Message", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .autocorrectionDisabled(true)
          .lineLimit(3, reservesSpace: true)
          .frame(height: 60, alignment: .topLeading)
          .accessibilityIdentifier("message-field")
          .disabled(isInputBlocked)
          .onSubmit(sendMessage)
          .onKeyPress(.upArrow) { moveSlashSelection(by: -1) }
          .onKeyPress(.downArrow) { moveSlashSelection(by: 1) }
          .onKeyPress(.tab) { commitSlashSelectionFromKey() }
          .onKeyPress(.escape) { dismissSlashSuggestions() }

        HStack(spacing: 8) {
          Button(action: onAddAttachments) {
            Image(systemName: "paperclip")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .disabled(isGenerating || isInputBlocked || modelState != .ready)
          .accessibilityLabel("Add context files")

          modelPicker

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
            .accessibilityLabel(modelLoadHelp)
            .accessibilityIdentifier("load-model-button")
          }

          modeSelector

          Spacer()

          ComposerContextRing(usage: contextUsage)

          Button(action: isGenerating ? onCancel : sendMessage) {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
              .font(.system(size: 13, weight: .bold))
              .foregroundStyle(sendButtonForeground(canActivateSend: canActivateSend))
              .frame(width: 28, height: 28)
              .background(sendButtonBackground(canActivateSend: canActivateSend), in: Circle())
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(isGenerating ? "cancel-generation-button" : "send-button")
          .disabled(!isGenerating && !canSend)
          .accessibilityLabel(isGenerating ? "Cancel" : "Send")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 14)
      .background(
        composerBackground,
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(composerBorderColor, lineWidth: isDropTarget ? 1.5 : 1)
      }
      .shadow(color: Color.black.opacity(0.14), radius: 16, x: 0, y: 8)
      // Keep paste/drop on native SwiftUI modifiers. The previous custom
      // NSViewRepresentable overlay was easy to re-enter during layout.
      .onPasteCommand(of: Self.attachmentPasteTypes) { providers in
        handlePaste(providers)
      }
      .onDrop(of: Self.attachmentDropTypes, isTargeted: $isDropTarget) { providers in
        handleDrop(providers)
      }
    }
    .padding(16)
  }

  private var modeSelector: some View {
    HStack(spacing: 2) {
      ForEach(WorkspaceInteractionMode.allCases, id: \.self) { mode in
        modeButton(mode)
      }
    }
    .padding(2)
    .frame(width: 104, height: 24)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Mode")
    .accessibilityValue(interactionMode.displayName)
    .accessibilityIdentifier("chat.modePicker")
  }

  private func modeButton(_ mode: WorkspaceInteractionMode) -> some View {
    let isSelected = mode == interactionMode

    return Button {
      guard mode != interactionMode else {
        return
      }
      onSelectInteractionMode(mode)
    } label: {
      Text(mode.displayName)
        .font(.caption2.weight(isSelected ? .semibold : .medium))
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .frame(width: 48, height: 20)
        .background(
          isSelected ? Color.secondary.opacity(0.16) : Color.clear,
          in: RoundedRectangle(cornerRadius: 4)
        )
    }
    .buttonStyle(.plain)
    .disabled(!canChangeInteractionMode)
    .accessibilityLabel(mode.displayName)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityIdentifier("chat.mode.\(mode.rawValue)")
  }

  // Clickable model picker. Uses a button + `.popover` rather than a native
  // `Menu`/NSMenu: when an accessibility client walks the tree, a closed popover
  // contributes only the button (its content lives in a separate window shown on
  // demand), so it can't feed the reentrant layout loop the way the old segmented
  // Picker / native menus did.
  private var modelPicker: some View {
    Button {
      showModelPicker.toggle()
    } label: {
      HStack(spacing: 6) {
        Text(modelPickerTitle)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .frame(width: 150, height: 24)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .disabled(!canChangeModel)
    .accessibilityLabel("Selected model")
    .accessibilityValue(modelPickerTitle)
    .accessibilityIdentifier("chat.modelPicker")
    .popover(isPresented: $showModelPicker) {
      VStack(alignment: .leading, spacing: 1) {
        ForEach(availableModels) { model in
          Button {
            onSelectModel(model)
            showModelPicker = false
          } label: {
            HStack(spacing: 8) {
              Text(model.displayName)
                .lineLimit(1)
              Spacer(minLength: 0)
              if model.id == selectedModel.id {
                Image(systemName: "checkmark")
                  .font(.caption.weight(.semibold))
              }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .frame(height: 26)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("chat.modelOption.\(model.id)")
        }
      }
      .padding(6)
      .frame(width: 240)
    }
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

  private var canAcceptAttachments: Bool {
    !isGenerating && !isInputBlocked && modelState == .ready
  }

  private func sendButtonBackground(canActivateSend: Bool) -> Color {
    canActivateSend ? Color.accentColor : Color.secondary.opacity(0.25)
  }

  private func sendButtonForeground(canActivateSend: Bool) -> Color {
    canActivateSend ? Color.white : Color.secondary
  }

  private var composerBackground: AnyShapeStyle {
    if isDropTarget && canAcceptAttachments {
      return AnyShapeStyle(Color.accentColor.opacity(0.08))
    }
    return AnyShapeStyle(.regularMaterial)
  }

  private var composerBorderColor: Color {
    isDropTarget && canAcceptAttachments
      ? Color.accentColor.opacity(0.55)
      : Color.secondary.opacity(0.18)
  }

  private var modelLoadActionTitle: String {
    modelState == .loading ? "Loading" : "Load"
  }

  private var modelLoadHelp: String {
    availableModels.isEmpty
      ? "Download a model from Models first"
      : "Load selected model"
  }

  private var modelPickerTitle: String {
    availableModels.isEmpty ? "No local models" : selectedModel.displayName
  }

  private var canInsertSoftBreak: Bool {
    !isInputBlocked
  }

  private var slashSuggestions: [SlashCommandDescriptor] {
    guard !slashSuggestionsDismissed, !isInputBlocked else {
      return []
    }
    guard draft.first == "/" else {
      return []
    }
    let token = draft.dropFirst()
    guard !token.contains(where: \.isWhitespace) else {
      return []
    }
    return SlashCommandRegistry.matching(prefix: String(token))
  }

  private func clampedSlashIndex(for suggestions: [SlashCommandDescriptor]) -> Int {
    let count = suggestions.count
    guard count > 0 else {
      return 0
    }
    return min(max(slashSelectionIndex, 0), count - 1)
  }

  private var canSendCurrentDraft: Bool {
    if slashCommandParser.parse(draft) != nil {
      return canRunLocalCommand
    }
    return canSend && draft.contains { !$0.isWhitespace }
  }

  private func moveSlashSelection(by delta: Int) -> KeyPress.Result {
    let suggestions = slashSuggestions
    guard !suggestions.isEmpty else {
      return .ignored
    }
    let selectedIndex = clampedSlashIndex(for: suggestions)
    slashSelectionIndex = min(max(selectedIndex + delta, 0), suggestions.count - 1)
    return .handled
  }

  private func commitSlashSelectionFromKey() -> KeyPress.Result {
    let suggestions = slashSuggestions
    guard !suggestions.isEmpty else {
      return .ignored
    }
    acceptSlashSuggestion(suggestions[clampedSlashIndex(for: suggestions)])
    return .handled
  }

  private func dismissSlashSuggestions() -> KeyPress.Result {
    guard !slashSuggestions.isEmpty else {
      return .ignored
    }
    slashSuggestionsDismissed = true
    return .handled
  }

  private func acceptSlashSuggestion(_ descriptor: SlashCommandDescriptor) {
    draft = descriptor.token + " "
    slashSelectionIndex = 0
    slashSuggestionsDismissed = false
  }

  private func sendMessage() {
    let suggestions = slashSuggestions
    if !suggestions.isEmpty {
      acceptSlashSuggestion(suggestions[clampedSlashIndex(for: suggestions)])
      return
    }

    guard canSendCurrentDraft else {
      return
    }

    let submittedDraft = draft
    let shouldClearDraft = onSend(submittedDraft)
    Task { @MainActor in
      if shouldClearDraft && (draft.isEmpty || draft == submittedDraft) {
        draft = ""
      }
    }
  }

  private func handlePaste(_ providers: [NSItemProvider]) {
    guard canAcceptAttachments else {
      return
    }
    if handleAttachmentProviders(providers) {
      return
    }

    handleImagePasteFromPasteboard()
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    guard canAcceptAttachments else {
      return false
    }
    return handleAttachmentProviders(providers)
  }

  private func handlePasteboardCommand() -> Bool {
    guard !isGenerating, !isInputBlocked, modelState == .ready else {
      return false
    }

    let urls = Self.fileURLsFromPasteboard()
    if !urls.isEmpty {
      onDropAttachments(urls)
      return true
    }

    guard let imageURL = Self.materializePasteboardImage() else {
      return false
    }

    onDropAttachments([imageURL])
    return true
  }

  private func insertSoftBreak() -> Bool {
    guard canInsertSoftBreak else {
      return false
    }

    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
      editor.insertText("\n", replacementRange: editor.selectedRange())
      return true
    }

    draft.append("\n")
    return true
  }

  private func handleImagePasteFromPasteboard() {
    guard !isGenerating, !isInputBlocked, modelState == .ready else {
      return
    }
    guard let imageURL = Self.materializePasteboardImage() else {
      return
    }

    onDropAttachments([imageURL])
  }

  private func handleAttachmentProviders(_ providers: [NSItemProvider]) -> Bool {
    guard canAcceptAttachments else {
      return false
    }

    let fileURLType = UTType.fileURL.identifier
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
    guard !fileProviders.isEmpty else {
      return false
    }

    let loader = AttachmentFileProviderLoader(providers: fileProviders)

    Task { @MainActor in
      let urls = await Self.fileURLs(from: loader, typeIdentifier: fileURLType)
      guard !urls.isEmpty else {
        return
      }
      onDropAttachments(urls)
    }

    return true
  }

  nonisolated fileprivate static func fileURL(from item: NSSecureCoding?) -> URL? {
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

  private static func fileURLs(
    from loader: AttachmentFileProviderLoader,
    typeIdentifier: String
  ) async -> [URL] {
    await withTaskGroup(of: (Int, URL?).self, returning: [URL].self) { group in
      let providerCount = loader.providerCount
      for position in 0..<providerCount {
        group.addTask {
          await loader.fileURL(at: position, typeIdentifier: typeIdentifier)
        }
      }

      var urlsByIndex: [(Int, URL)] = []
      for await (index, url) in group {
        guard let url else {
          continue
        }
        urlsByIndex.append((index, url))
      }

      return
        urlsByIndex
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }
  }

  nonisolated private static func fileURLsFromPasteboard() -> [URL] {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL],
      !urls.isEmpty
    {
      return urls
    }

    let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    guard let paths = pasteboard.propertyList(forType: filenamesType) as? [String] else {
      return []
    }

    return paths.map { URL(filePath: $0).standardizedFileURL }
  }

  nonisolated private static func materializePasteboardImage() -> URL? {
    let pasteboard = NSPasteboard.general
    guard let pngData = pasteboardPNGData(pasteboard) else {
      return nil
    }
    guard pngData.count <= ChatAttachmentLimits.maxImageFileBytes else {
      return nil
    }

    do {
      let directory = FileManager.default.temporaryDirectory
        .appending(path: "sumika-chat-pasteboard", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let url = directory.appending(path: "clipboard-image-\(UUID().uuidString).png")
      try pngData.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  nonisolated private static func pasteboardPNGData(_ pasteboard: NSPasteboard) -> Data? {
    if let data = pasteboard.data(forType: .png) {
      return data
    }

    if let data = pasteboard.data(forType: .tiff),
      let bitmap = NSBitmapImageRep(data: data),
      let pngData = bitmap.representation(using: .png, properties: [:])
    {
      return pngData
    }

    guard let image = NSImage(pasteboard: pasteboard),
      let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData)
    else {
      return nil
    }

    return bitmap.representation(using: .png, properties: [:])
  }

  private static let attachmentPasteTypes: [UTType] = [
    .fileURL,
    .image,
    .png,
    .tiff,
  ]

  private static let attachmentDropTypes: [UTType] = [
    .fileURL
  ]
}

@MainActor
private final class AttachmentFileProviderLoader {
  private let indexedProviders: [(index: Int, provider: NSItemProvider)]

  var providerCount: Int {
    indexedProviders.count
  }

  init(providers: [NSItemProvider]) {
    indexedProviders = providers.enumerated().map { ($0.offset, $0.element) }
  }

  func fileURL(at position: Int, typeIdentifier: String) async -> (Int, URL?) {
    let (index, provider) = indexedProviders[position]
    let item = try? await provider.loadItem(
      forTypeIdentifier: typeIdentifier,
      options: nil
    )
    return (index, ChatComposer.fileURL(from: item))
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
