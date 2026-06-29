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
  let reasoningEnabled: Bool
  let todoState: TodoState?
  let contextUsage: ChatContextUsage?
  let canChangeModel: Bool
  let canChangeInteractionMode: Bool
  let canSend: Bool
  let canRunLocalCommand: Bool
  let isGenerating: Bool
  let errorMessage: String?
  let onSelectInteractionMode: (WorkspaceInteractionMode) -> Void
  let onSetReasoningEnabled: (Bool) -> Void
  let onSelectModel: (ManagedModel) -> Void
  let onLoadModel: () -> Void
  let onAddAttachments: () -> Void
  let onDropAttachments: ([URL]) -> Void
  let onRemoveAttachment: (ChatAttachment.ID) -> Void
  let speechInputController: ComposerSpeechInputController
  let onOpenAudioModels: () -> Void
  let onSend: (String) -> Bool
  let onCancel: () -> Void
  @State private var draftBridge = ComposerDraftBridge()
  @State private var draftState = ComposerDraftState()
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
        ComposerTextView(
          draftBridge: draftBridge,
          placeholder: "Ask, dictate, or type / for commands",
          isDisabled: false,
          canAcceptAttachments: canAcceptAttachments,
          onTextStateChanged: updateDraftState(_:),
          onSubmit: sendMessage,
          onMoveSlashSelection: moveSlashSelection(by:),
          onCommitSlashSelection: commitSlashSelectionFromKey,
          onDismissSlashSuggestions: dismissSlashSuggestions,
          onPasteboardAttachments: handlePasteboardAttachments(_:)
        )
        .frame(height: 60, alignment: .topLeading)

        HStack(spacing: 8) {
          Button(action: onAddAttachments) {
            Image(systemName: "paperclip")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .disabled(isGenerating || modelState != .ready)
          .accessibilityLabel("Add context files")

          ComposerSpeechInputControl(
            controller: speechInputController,
            isDisabled: isGenerating || modelState != .ready,
            onTranscript: insertSpeechTranscript(_:),
            onNeedsAudioModel: onOpenAudioModels
          )

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
          reasoningToggle

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
          .disabled(!isGenerating && !canSubmitDraft)
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

  private var reasoningToggle: some View {
    Button {
      onSetReasoningEnabled(!reasoningEnabled)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: reasoningEnabled ? "lightbulb.fill" : "lightbulb")
          .font(.system(size: 10, weight: .semibold))
        Text(reasoningEnabled ? "Reasoning On" : "Reasoning")
          .font(.caption2.weight(reasoningEnabled ? .semibold : .medium))
          .lineLimit(1)
      }
      .foregroundStyle(reasoningEnabled ? Color.accentColor : Color.secondary)
      .padding(.horizontal, 7)
      .frame(width: 104, height: 24)
      .background(
        reasoningEnabled ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 5)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(
            reasoningEnabled ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16),
            lineWidth: reasoningEnabled ? 1.2 : 1
          )
      }
    }
    .buttonStyle(.plain)
    .disabled(!canChangeInteractionMode)
    .help(reasoningEnabled ? "Disable model reasoning" : "Enable model reasoning")
    .accessibilityLabel("Reasoning")
    .accessibilityValue(reasoningEnabled ? "On" : "Off")
    .accessibilityIdentifier("chat.reasoningToggle")
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
    .help(modelPickerHelp)
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
    return !activeAttachments.isEmpty && (hasDraftText || !attachments.isEmpty)
  }

  private var canLoadSelectedModel: Bool {
    !availableModels.isEmpty && modelState != .loading && !isGenerating
  }

  private var canAcceptAttachments: Bool {
    !isGenerating && modelState == .ready
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

  private var modelPickerHelp: String {
    availableModels.isEmpty ? "Download a model from Models first" : selectedModel.displayName
  }

  private var slashSuggestions: [SlashCommandDescriptor] {
    guard !slashSuggestionsDismissed else {
      return []
    }
    guard let token = draftState.slashSuggestionPrefix else {
      return []
    }
    return SlashCommandRegistry.matching(prefix: token)
  }

  private func clampedSlashIndex(for suggestions: [SlashCommandDescriptor]) -> Int {
    let count = suggestions.count
    guard count > 0 else {
      return 0
    }
    return min(max(slashSelectionIndex, 0), count - 1)
  }

  private var hasDraftText: Bool {
    draftState.hasText
  }

  private var canSendCurrentDraft: Bool {
    guard hasDraftText else {
      return false
    }

    guard let slashCommandText = draftState.slashCommandText else {
      return canSend
    }

    if slashCommandParser.parse(slashCommandText) != nil {
      return canRunLocalCommand
    }
    return canSend
  }

  private func updateDraftState(_ state: ComposerDraftState) {
    guard draftState != state else {
      return
    }
    draftState = state
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
    setDraftText(descriptor.token + " ")
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

    let submittedDraft = draftBridge.text
    let shouldClearDraft = onSend(submittedDraft)
    Task { @MainActor in
      let currentDraft = draftBridge.text
      if shouldClearDraft && (currentDraft.isEmpty || currentDraft == submittedDraft) {
        setDraftText("")
      }
    }
  }

  private func setDraftText(_ text: String) {
    draftBridge.replaceText(text)
    updateDraftState(ComposerDraftState(text: text))
  }

  private func insertSpeechTranscript(_ text: String) {
    draftBridge.insertTextAtCurrentSelection(text)
    updateDraftState(ComposerDraftState(text: draftBridge.text))
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

  private func handlePasteboardAttachments(_ pasteboard: NSPasteboard) -> Bool {
    guard canAcceptAttachments else {
      return false
    }

    let urls = Self.fileURLs(from: pasteboard)
    if !urls.isEmpty {
      onDropAttachments(urls)
      return true
    }

    guard let imageURL = Self.materializePasteboardImage(from: pasteboard) else {
      return false
    }

    onDropAttachments([imageURL])
    return true
  }

  private func handleImagePasteFromPasteboard() {
    guard !isGenerating, modelState == .ready else {
      return
    }
    guard let imageURL = Self.materializePasteboardImage(from: .general) else {
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

  nonisolated private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
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

  nonisolated private static func materializePasteboardImage(from pasteboard: NSPasteboard) -> URL?
  {
    guard let pngData = pasteboardPNGData(pasteboard) else {
      return nil
    }
    guard pngData.count <= ChatAttachmentLimits.maxImageFileBytes else {
      return nil
    }

    do {
      let directory = FileManager.default.temporaryDirectory
        .appending(path: "sumika-pasteboard", directoryHint: .isDirectory)
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

struct ComposerDraftState: Equatable {
  var hasText = false
  var slashSuggestionPrefix: String?
  var slashCommandText: String?

  init() {}

  init(text: String) {
    hasText = text.contains { !$0.isWhitespace }

    if text.first == "/" {
      let token = text.dropFirst()
      if !token.contains(where: \.isWhitespace) {
        slashSuggestionPrefix = String(token)
      }
    }

    if text.first(where: { !$0.isWhitespace }) == "/" {
      slashCommandText = text
    }
  }
}

private final class ComposerDraftBridge {
  private weak var textView: ComposerNSTextView?
  private var storedText = ""

  var text: String {
    textView?.string ?? storedText
  }

  func bind(_ textView: ComposerNSTextView) {
    self.textView = textView
    storedText = textView.string
  }

  func noteTextDidChange(_ text: String) {
    storedText = text
  }

  func replaceText(_ text: String) {
    storedText = text
    textView?.replaceAllText(text)
  }

  func insertTextAtCurrentSelection(_ text: String) {
    guard !text.isEmpty else {
      return
    }

    if let textView {
      textView.insertPlainTextAtCurrentSelection(text)
      storedText = textView.string
      return
    }

    let insertion = ComposerDraftTextEditor.inserting(
      text,
      into: storedText,
      selectedRange: NSRange(location: (storedText as NSString).length, length: 0)
    )
    storedText = insertion.text
  }
}

struct ComposerDraftTextInsertion: Equatable {
  var text: String
  var selectedRange: NSRange
}

enum ComposerDraftTextEditor {
  static func inserting(
    _ insertionText: String,
    into text: String,
    selectedRange: NSRange
  ) -> ComposerDraftTextInsertion {
    let nsText = text as NSString
    let insertionLength = (insertionText as NSString).length
    let location = min(max(selectedRange.location, 0), nsText.length)
    let length = min(max(selectedRange.length, 0), nsText.length - location)
    let replacementRange = NSRange(location: location, length: length)
    let updatedText = nsText.replacingCharacters(in: replacementRange, with: insertionText)

    return ComposerDraftTextInsertion(
      text: updatedText,
      selectedRange: NSRange(location: location + insertionLength, length: 0)
    )
  }
}

private struct ComposerSpeechInputControl: View {
  let controller: ComposerSpeechInputController
  let isDisabled: Bool
  let onTranscript: (String) -> Void
  let onNeedsAudioModel: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button {
        controller.toggle(
          onTranscript: onTranscript,
          onNeedsAudioModel: onNeedsAudioModel
        )
      } label: {
        Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(buttonForeground)
          .frame(width: 24, height: 24)
          .background(buttonBackground, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(isButtonDisabled)
      .help(helpText)
      .accessibilityLabel(controller.isRecording ? "Stop dictation" : "Start dictation")
      .accessibilityIdentifier("chat.speechInput")

      if let statusText = controller.statusText {
        Text(statusText)
          .font(.caption2)
          .foregroundStyle(statusForeground)
          .lineLimit(1)
          .frame(maxWidth: 120, alignment: .leading)
      }
    }
    .onDisappear {
      controller.cancel()
    }
  }

  private var isButtonDisabled: Bool {
    if controller.isRecording {
      return false
    }
    return isDisabled || controller.phase.isBusy
  }

  private var buttonForeground: Color {
    if controller.isRecording {
      return .white
    }
    return isButtonDisabled ? .secondary : .primary
  }

  private var buttonBackground: Color {
    if controller.isRecording {
      return .red
    }
    if isButtonDisabled {
      return Color.secondary.opacity(0.12)
    }
    return Color.secondary.opacity(0.08)
  }

  private var statusForeground: Color {
    if case .failed = controller.phase {
      return .red
    }
    return .secondary
  }

  private var helpText: String {
    if controller.isRecording {
      return "Stop dictation"
    }
    if isDisabled {
      return "Load a model before dictating"
    }
    return "Dictate message"
  }
}

private struct ComposerTextView: NSViewRepresentable {
  let draftBridge: ComposerDraftBridge
  let placeholder: String
  let isDisabled: Bool
  let canAcceptAttachments: Bool
  let onTextStateChanged: (ComposerDraftState) -> Void
  let onSubmit: () -> Void
  let onMoveSlashSelection: (Int) -> KeyPress.Result
  let onCommitSlashSelection: () -> KeyPress.Result
  let onDismissSlashSuggestions: () -> KeyPress.Result
  let onPasteboardAttachments: (NSPasteboard) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(draftBridge: draftBridge, onTextStateChanged: onTextStateChanged)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    let textView = ComposerNSTextView()
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.insertionPointColor = .labelColor
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.frame = NSRect(
      origin: .zero,
      size: NSSize(width: max(scrollView.contentSize.width, 1), height: 60)
    )
    textView.minSize = NSSize(width: 0, height: 60)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.autoresizingMask = [.width]
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.registerForDraggedTypes([
      .fileURL,
      .URL,
      .png,
      .tiff,
    ])
    textView.setAccessibilityIdentifier("message-field")
    textView.setAccessibilityLabel("Message")

    disableAutomaticTextServices(on: textView)
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ComposerNSTextView else {
      return
    }

    context.coordinator.draftBridge = draftBridge
    context.coordinator.onTextStateChanged = onTextStateChanged
    draftBridge.bind(textView)
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
    }
    textView.canAcceptAttachments = canAcceptAttachments
    textView.onSubmit = onSubmit
    textView.onMoveSlashSelection = onMoveSlashSelection
    textView.onCommitSlashSelection = onCommitSlashSelection
    textView.onDismissSlashSuggestions = onDismissSlashSuggestions
    textView.onPasteboardAttachments = onPasteboardAttachments
    textView.isEditable = !isDisabled
    textView.isSelectable = true
    textView.textColor = isDisabled ? .disabledControlTextColor : .labelColor
    textView.frame.size.width = max(scrollView.contentSize.width, 1)
  }

  private func disableAutomaticTextServices(on textView: NSTextView) {
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.enabledTextCheckingTypes = 0
    textView.smartInsertDeleteEnabled = false
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var draftBridge: ComposerDraftBridge
    var onTextStateChanged: (ComposerDraftState) -> Void

    init(
      draftBridge: ComposerDraftBridge,
      onTextStateChanged: @escaping (ComposerDraftState) -> Void
    ) {
      self.draftBridge = draftBridge
      self.onTextStateChanged = onTextStateChanged
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else {
        return
      }

      let previousText = draftBridge.text
      draftBridge.noteTextDidChange(textView.string)
      onTextStateChanged(ComposerDraftState(text: textView.string))
      if previousText.isEmpty != textView.string.isEmpty {
        textView.needsDisplay = true
      }
    }
  }
}

final class ComposerNSTextView: NSTextView {
  var placeholder = "" {
    didSet {
      needsDisplay = true
    }
  }

  var canAcceptAttachments = false
  var onSubmit: (() -> Void)?
  var onMoveSlashSelection: ((Int) -> KeyPress.Result)?
  var onCommitSlashSelection: (() -> KeyPress.Result)?
  var onDismissSlashSuggestions: (() -> KeyPress.Result)?
  var onPasteboardAttachments: ((NSPasteboard) -> Bool)?

  func replaceAllText(_ newText: String) {
    guard string != newText else {
      return
    }

    let wasEmpty = string.isEmpty
    string = newText
    setSelectedRange(NSRange(location: newText.utf16.count, length: 0))
    if wasEmpty != newText.isEmpty {
      needsDisplay = true
    }
  }

  func insertPlainTextAtCurrentSelection(_ text: String) {
    guard !text.isEmpty else {
      return
    }

    let insertion = ComposerDraftTextEditor.inserting(
      text,
      into: string,
      selectedRange: selectedRange()
    )
    guard string != insertion.text else {
      setSelectedRange(insertion.selectedRange)
      return
    }

    string = insertion.text
    setSelectedRange(insertion.selectedRange)
    didChangeText()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard string.isEmpty, !placeholder.isEmpty else {
      return
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byTruncatingTail
    let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.placeholderTextColor,
      .paragraphStyle: paragraphStyle,
    ]
    let horizontalInset = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
    let rect = NSRect(
      x: horizontalInset,
      y: textContainerInset.height,
      width: max(0, bounds.width - (horizontalInset * 2)),
      height: font.ascender - font.descender
    )
    placeholder.draw(in: rect, withAttributes: attributes)
  }

  override func keyDown(with event: NSEvent) {
    if shouldHandleAttachmentPasteShortcut(event), handleAttachmentPasteboard(.general) {
      return
    }

    switch event.keyCode {
    case 36, 76:
      handleReturn(event)
    case 126:
      if didHandle(onMoveSlashSelection?(-1)) {
        return
      }
      super.keyDown(with: event)
    case 125:
      if didHandle(onMoveSlashSelection?(1)) {
        return
      }
      super.keyDown(with: event)
    case 48:
      if didHandle(onCommitSlashSelection?()) {
        return
      }
      super.keyDown(with: event)
    case 53:
      if didHandle(onDismissSlashSuggestions?()) {
        return
      }
      super.keyDown(with: event)
    default:
      super.keyDown(with: event)
    }
  }

  override func paste(_ sender: Any?) {
    if pasteboardContainsAttachments(.general) {
      _ = handleAttachmentPasteboard(.general)
      return
    }

    pasteAsPlainText(sender)
  }

  override func pasteAsRichText(_ sender: Any?) {
    paste(sender)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if pasteboardContainsAttachments(sender.draggingPasteboard) {
      return canAcceptAttachments ? .copy : []
    }

    return super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    if pasteboardContainsAttachments(sender.draggingPasteboard) {
      return canAcceptAttachments ? .copy : []
    }

    return super.draggingUpdated(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if pasteboardContainsAttachments(sender.draggingPasteboard) {
      return handleAttachmentPasteboard(sender.draggingPasteboard)
    }

    return super.performDragOperation(sender)
  }

  private func handleReturn(_ event: NSEvent) {
    guard isEditable else {
      return
    }

    if hasMarkedText() {
      super.keyDown(with: event)
      return
    }

    let insertNewline = !event.modifierFlags.isDisjoint(with: [.shift, .option])
    if insertNewline {
      insertText("\n", replacementRange: selectedRange())
      return
    }

    onSubmit?()
  }

  private func handleAttachmentPasteboard(_ pasteboard: NSPasteboard) -> Bool {
    guard canAcceptAttachments else {
      return false
    }

    return onPasteboardAttachments?(pasteboard) ?? false
  }

  private func shouldHandleAttachmentPasteShortcut(_ event: NSEvent) -> Bool {
    guard event.keyCode == 9 else {
      return false
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control),
      !flags.contains(.command),
      !flags.contains(.option)
    else {
      return false
    }

    return pasteboardContainsAttachments(.general)
  }

  private func pasteboardContainsAttachments(_ pasteboard: NSPasteboard) -> Bool {
    if pasteboard.canReadObject(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) {
      return true
    }

    if pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil {
      return true
    }

    let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    if pasteboard.availableType(from: [filenamesType]) != nil {
      return true
    }

    return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
  }

  private func didHandle(_ result: KeyPress.Result?) -> Bool {
    guard let result else {
      return false
    }

    switch result {
    case .handled:
      return true
    case .ignored:
      return false
    @unknown default:
      return false
    }
  }
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
