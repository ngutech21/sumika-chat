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
          .onPasteCommand(of: [UTType.fileURL, UTType.image, UTType.png, UTType.tiff]) {
            providers in
            handlePaste(providers)
          }
          .onChange(of: draft) { oldDraft, newDraft in
            handleDraftChangeAfterPaste(from: oldDraft, to: newDraft)
          }
          .background {
            ComposerPasteCommandMonitor(
              isActive: canInterceptPasteCommand,
              onPaste: handlePasteboardCommand
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

  private var canInterceptPasteCommand: Bool {
    messageFieldFocused && !isGenerating && !isInputBlocked && modelState == .ready
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

private struct ComposerPasteCommandMonitor: NSViewRepresentable {
  let isActive: Bool
  let onPaste: () -> Bool

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
    var parent: ComposerPasteCommandMonitor
    private var monitor: Any?

    init(parent: ComposerPasteCommandMonitor) {
      self.parent = parent
    }

    func installMonitor() {
      guard monitor == nil else {
        return
      }

      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, parent.isActive, Self.isPasteCommand(event) else {
          return event
        }

        return parent.onPaste() ? nil : event
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
