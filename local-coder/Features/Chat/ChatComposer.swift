import AppKit
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
  @State private var slashSelectionIndex = 0
  @State private var slashSuggestionsDismissed = false

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

      if !slashSuggestions.isEmpty {
        SlashCommandSuggestionList(
          suggestions: slashSuggestions,
          selectedIndex: clampedSlashIndex,
          onSelect: acceptSlashSuggestion,
          onHighlight: { slashSelectionIndex = $0 }
        )
        .transition(.opacity)
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
          .onKeyPress(.upArrow) { moveSlashSelection(by: -1) }
          .onKeyPress(.downArrow) { moveSlashSelection(by: 1) }
          .onKeyPress(.tab) { commitSlashSelectionFromKey() }
          .onKeyPress(.escape) { dismissSlashSuggestions() }
          .onPasteCommand(of: [UTType.fileURL, UTType.image, UTType.png, UTType.tiff]) {
            providers in
            handlePaste(providers)
          }
          .onChange(of: draft) { oldDraft, newDraft in
            slashSuggestionsDismissed = false
            slashSelectionIndex = 0
            handleDraftChangeAfterPaste(from: oldDraft, to: newDraft)
          }
          .background {
            ComposerKeyCommandMonitor(
              canHandlePaste: canInterceptPasteCommand,
              canInsertSoftBreak: canInsertSoftBreak,
              onPaste: handlePasteboardCommand,
              onSoftBreak: insertSoftBreak
            )
            .frame(width: 0, height: 0)
          }
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

          Spacer()

          ComposerContextRing(usage: contextUsage)

          Button(action: isGenerating ? onCancel : sendMessage) {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
              .font(.system(size: 13, weight: .bold))
              .foregroundStyle(sendButtonForeground)
              .frame(width: 28, height: 28)
              .background(sendButtonBackground, in: Circle())
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(isGenerating ? "cancel-generation-button" : "send-button")
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!isGenerating && !canSend)
          .help(isGenerating ? "Cancel" : "Send")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 14)
      .glassPanel(cornerRadius: 14)
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

  private var canActivateSend: Bool {
    isGenerating || canSend
  }

  private var sendButtonBackground: Color {
    canActivateSend ? Color.accentColor : Color.secondary.opacity(0.25)
  }

  private var sendButtonForeground: Color {
    canActivateSend ? Color.white : Color.secondary
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

  private var canInterceptPasteCommand: Bool {
    messageFieldFocused && !isGenerating && !isInputBlocked && modelState == .ready
  }

  private var canInsertSoftBreak: Bool {
    messageFieldFocused && !isInputBlocked
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

  private var clampedSlashIndex: Int {
    let count = slashSuggestions.count
    guard count > 0 else {
      return 0
    }
    return min(max(slashSelectionIndex, 0), count - 1)
  }

  private func moveSlashSelection(by delta: Int) -> KeyPress.Result {
    let suggestions = slashSuggestions
    guard !suggestions.isEmpty else {
      return .ignored
    }
    slashSelectionIndex = min(max(clampedSlashIndex + delta, 0), suggestions.count - 1)
    return .handled
  }

  private func commitSlashSelectionFromKey() -> KeyPress.Result {
    let suggestions = slashSuggestions
    guard !suggestions.isEmpty else {
      return .ignored
    }
    acceptSlashSuggestion(suggestions[clampedSlashIndex])
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
    messageFieldFocused = true
  }

  private func sendMessage() {
    let suggestions = slashSuggestions
    if !suggestions.isEmpty {
      acceptSlashSuggestion(suggestions[clampedSlashIndex])
      return
    }

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
    handleAttachmentProviders(providers)
  }

  private func handlePaste(_ providers: [NSItemProvider]) {
    if handleAttachmentProviders(providers) {
      return
    }

    handleImagePasteFromPasteboard()
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

  private func handleDraftChangeAfterPaste(from oldDraft: String, to newDraft: String) {
    guard !isGenerating, !isInputBlocked, modelState == .ready else {
      return
    }
    guard let pasteEdit = Self.pasteEdit(from: oldDraft, to: newDraft),
      Self.insertedTextMatchesPasteboardFiles(pasteEdit.insertedText)
    else {
      return
    }

    let urls = Self.fileURLsFromPasteboard()
    guard !urls.isEmpty else {
      return
    }

    draft = pasteEdit.draftWithoutInsertedText.trimmingCharacters(in: .whitespacesAndNewlines)
    onDropAttachments(urls)
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
    guard !isGenerating, !isInputBlocked, modelState == .ready else {
      return false
    }

    let fileURLType = UTType.fileURL.identifier
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
    guard !fileProviders.isEmpty else {
      return false
    }

    let group = DispatchGroup()
    let accumulator = AttachmentURLAccumulator()

    for provider in fileProviders {
      group.enter()
      provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
        defer { group.leave() }
        guard let url = Self.fileURL(from: item) else {
          return
        }

        accumulator.append(url)
      }
    }

    group.notify(queue: .main) {
      let urls = accumulator.urls()
      guard !urls.isEmpty else {
        return
      }
      onDropAttachments(urls)
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
        .appending(path: "local-coder-pasteboard", directoryHint: .isDirectory)
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

  nonisolated private static func pasteEdit(from oldDraft: String, to newDraft: String)
    -> PasteEdit?
  {
    guard newDraft.count > oldDraft.count else {
      return nil
    }

    var prefix = 0
    while prefix < oldDraft.count,
      oldDraft[oldDraft.index(oldDraft.startIndex, offsetBy: prefix)]
        == newDraft[newDraft.index(newDraft.startIndex, offsetBy: prefix)]
    {
      prefix += 1
    }

    var suffix = 0
    while suffix < oldDraft.count - prefix,
      oldDraft[oldDraft.index(oldDraft.endIndex, offsetBy: -suffix - 1)]
        == newDraft[newDraft.index(newDraft.endIndex, offsetBy: -suffix - 1)]
    {
      suffix += 1
    }

    let start = newDraft.index(newDraft.startIndex, offsetBy: prefix)
    let end = newDraft.index(newDraft.endIndex, offsetBy: -suffix)
    let insertedText = String(newDraft[start..<end])
    var draftWithoutInsertedText = newDraft
    draftWithoutInsertedText.removeSubrange(start..<end)
    return PasteEdit(
      insertedText: insertedText,
      draftWithoutInsertedText: draftWithoutInsertedText
    )
  }

  nonisolated private static func insertedTextMatchesPasteboardFiles(_ insertedText: String)
    -> Bool
  {
    let urls = fileURLsFromPasteboard()
    guard !urls.isEmpty else {
      return false
    }

    let names = urls.map(\.lastPathComponent)
    let candidates = [
      names.joined(separator: "\n"),
      names.joined(separator: " "),
      names.joined(separator: ", "),
    ]
    let trimmedInsertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
    return candidates.contains {
      $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedInsertedText
    }
  }

  nonisolated private struct PasteEdit {
    let insertedText: String
    let draftWithoutInsertedText: String
  }
}

nonisolated private final class AttachmentURLAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var storedURLs: [URL] = []

  func append(_ url: URL) {
    lock.lock()
    storedURLs.append(url)
    lock.unlock()
  }

  func urls() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return storedURLs
  }
}

private struct ComposerKeyCommandMonitor: NSViewRepresentable {
  let canHandlePaste: Bool
  let canInsertSoftBreak: Bool
  let onPaste: () -> Bool
  let onSoftBreak: () -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.installMonitor()
    let view = NSView(frame: .zero)
    view.isHidden = true
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.parent = self
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstallMonitor()
  }

  final class Coordinator {
    var parent: ComposerKeyCommandMonitor
    private var monitor: Any?

    init(parent: ComposerKeyCommandMonitor) {
      self.parent = parent
    }

    func installMonitor() {
      guard monitor == nil else {
        return
      }

      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else {
          return event
        }

        if parent.canInsertSoftBreak, Self.isSoftBreakCommand(event) {
          return parent.onSoftBreak() ? nil : event
        }

        if parent.canHandlePaste, Self.isPasteCommand(event) {
          return parent.onPaste() ? nil : event
        }

        return event
      }
    }

    func uninstallMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    private static func isPasteCommand(_ event: NSEvent) -> Bool {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags == .command else {
        return false
      }

      return event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    private static func isSoftBreakCommand(_ event: NSEvent) -> Bool {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags.contains(.shift),
        !flags.contains(.command),
        !flags.contains(.control),
        !flags.contains(.option)
      else {
        return false
      }

      return event.keyCode == 36 || event.keyCode == 76
    }
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
