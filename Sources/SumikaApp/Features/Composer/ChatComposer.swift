import AppKit
import SumikaCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
  let attachments: [ChatAttachment]
  let availableModels: [ManagedModel]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let interactionMode: WorkspaceInteractionMode
  let skillCatalog: SkillCatalogSnapshot
  let sessionOptionsConfiguration: ChatComposerOptions.Configuration
  let todoState: TodoState?
  let canChangeModel: Bool
  let canChangeInteractionMode: Bool
  let canSend: Bool
  let canRunLocalCommand: Bool
  let isGenerating: Bool
  let isPreparingTurn: Bool
  let errorMessage: String?
  let onSelectInteractionMode: (WorkspaceInteractionMode) -> Void
  let onSelectModel: (ManagedModel) -> Void
  let onLoadModel: () -> Void
  let onAddAttachments: () -> Void
  let onDropAttachments: ([URL]) -> Void
  let onRemoveAttachment: (ChatAttachment.ID) -> Void
  let speechInputController: ComposerSpeechInputController
  let onOpenAudioModels: () -> Void
  let onRefreshSkills: () async -> SkillCatalogSnapshot
  let onSend: (MessageSubmission) async -> Bool
  let onCancel: () -> Void
  @State private var draftBridge = ComposerDraftBridge()
  @State private var draftState = ComposerDraftState()
  @State private var suggestionSelectionIndex = 0
  @State private var suggestionsDismissed = false
  @State private var refreshedSkillCatalog: SkillCatalogSnapshot?
  @State private var boundSkillMentions: [SkillMention] = []
  @State private var showModelPicker = false
  @State private var isDropTarget = false
  @State private var isSubmitting = false

  private let slashCommandParser = SlashCommandParser()

  var body: some View {
    let suggestions = composerSuggestions
    let selectedSuggestionIndex = clampedSuggestionIndex(for: suggestions)
    let canSubmitDraft = canSendCurrentDraft
    let canActivateSend = isGenerating || canSubmitDraft

    VStack(alignment: .leading, spacing: 8) {
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .font(.callout)
      }

      if !attachments.isEmpty {
        AttachmentList(
          title: nil,
          attachments: attachments,
          canRemove: !isComposerBusy,
          onRemoveAttachment: onRemoveAttachment
        )
      }

      if let todoState {
        TodoPlanPanel(todoState: todoState)
          .frame(maxWidth: .infinity, alignment: .center)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      if shouldShowSuggestionList {
        ComposerSuggestionList(
          suggestions: suggestions,
          diagnostics: suggestionDiagnostics,
          selectedIndex: selectedSuggestionIndex,
          onSelect: acceptSuggestion,
          onHighlight: { suggestionSelectionIndex = $0 }
        )
        .transition(.opacity)
      }

      VStack(spacing: 8) {
        ComposerTextView(
          draftBridge: draftBridge,
          placeholder: composerPlaceholder,
          canAcceptAttachments: canAcceptAttachments,
          isEditable: !isComposerBusy,
          onTextEdit: updateBoundMentions(replacing:with:),
          onTextStateChanged: updateDraftState(_:),
          onSubmit: sendMessage,
          onMoveSuggestionSelection: moveSuggestionSelection(by:),
          onCommitSuggestionSelection: commitSuggestionSelectionFromKey,
          onDismissSuggestions: dismissSuggestions,
          onPasteboardAttachments: handlePasteboardAttachments(_:)
        )
        .frame(height: 60, alignment: .topLeading)

        HStack(spacing: 8) {
          Button(action: onAddAttachments) {
            Image(systemName: "paperclip")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .disabled(isComposerBusy || modelState != .ready)
          .accessibilityLabel("Add context files")

          modelControlGroup
          modeSelector
          ChatComposerOptions(configuration: sessionOptionsConfiguration)

          Spacer(minLength: 8)

          ComposerSpeechInputControl(
            controller: speechInputController,
            isDisabled: isComposerBusy || modelState != .ready,
            onTranscript: insertSpeechTranscript(_:),
            onNeedsAudioModel: onOpenAudioModels
          )

          Button(action: isGenerating ? onCancel : sendMessage) {
            Group {
              if isPreparingTurn || isSubmitting {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
              }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(sendButtonForeground(canActivateSend: canActivateSend))
            .frame(width: 28, height: 28)
            .background(sendButtonBackground(canActivateSend: canActivateSend), in: Circle())
            .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(isGenerating ? "cancel-generation-button" : "send-button")
          .disabled(!isGenerating && !canSubmitDraft)
          .accessibilityLabel(
            isGenerating ? "Cancel" : (isPreparingTurn || isSubmitting ? "Preparing" : "Send")
          )

        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 14)
      .glassPanel(cornerRadius: 18)
      .overlay {
        // Drop-target affordance layered on top of the glass surface so the
        // base panel keeps its translucency while a drag is in progress.
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
          }
          .opacity(isDropTarget && canAcceptAttachments ? 1 : 0)
          .allowsHitTesting(false)
      }
      .shadow(color: Color.black.opacity(0.22), radius: 22, x: 0, y: 10)
      .onPasteCommand(of: Self.attachmentPasteTypes) { providers in
        handlePaste(providers)
      }
      .onDrop(of: Self.attachmentDropTypes, isTargeted: $isDropTarget) { providers in
        handleDrop(providers)
      }
    }
    .padding(16)
    .onChange(of: skillCatalog) { _, snapshot in
      refreshedSkillCatalog = snapshot
    }
    .onChange(of: interactionMode) { _, mode in
      if mode == .chat {
        boundSkillMentions = []
        suggestionsDismissed = false
      }
    }
  }

  private var modelControlGroup: some View {
    HStack(spacing: 0) {
      modelPicker

      Divider()
        .frame(height: 14)

      loadButton
    }
    .frame(height: 24)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Model")
    .accessibilityIdentifier("chat.modelControl")
  }

  private var loadButton: some View {
    Button(action: onLoadModel) {
      HStack(spacing: 5) {
        switch modelState {
        case .loading:
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
              .accessibilityIdentifier("load-model-progress")
            Text("Loading")
          }
        case .ready:
          Label("Ready", systemImage: "checkmark")
            .foregroundStyle(.secondary)
        case .notLoaded, .failed:
          Label("Load", systemImage: "play.fill")
        }
      }
      .font(.caption2.weight(.medium))
      .frame(width: 82, height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!canLoadSelectedModel)
    .accessibilityLabel(modelLoadHelp)
    .accessibilityValue(modelState.label)
    .accessibilityIdentifier("load-model-button")
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
      .contentShape(Rectangle())
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

  private var canLoadSelectedModel: Bool {
    !availableModels.isEmpty && modelState != .loading && modelState != .ready && !isComposerBusy
  }

  private var canAcceptAttachments: Bool {
    !isComposerBusy && modelState == .ready
  }

  private var isComposerBusy: Bool {
    isGenerating || isPreparingTurn || isSubmitting
  }

  private var composerPlaceholder: String {
    interactionMode == .agent
      ? "Ask, dictate, or type / for commands and $ for skills"
      : "Ask, dictate, or type / for commands"
  }

  private func sendButtonBackground(canActivateSend: Bool) -> Color {
    canActivateSend ? Color.accentColor : Color.secondary.opacity(0.25)
  }

  private func sendButtonForeground(canActivateSend: Bool) -> Color {
    canActivateSend ? Color.white : Color.secondary
  }

  private var modelLoadHelp: String {
    if availableModels.isEmpty {
      return "Download a model from Models first"
    }
    switch modelState {
    case .notLoaded:
      return "Load selected model"
    case .loading:
      return "Loading selected model"
    case .ready:
      return "Model ready"
    case .failed:
      return "Retry loading selected model"
    }
  }

  private var modelPickerTitle: String {
    availableModels.isEmpty ? "No local models" : selectedModel.displayName
  }

  private var modelPickerHelp: String {
    availableModels.isEmpty ? "Download a model from Models first" : selectedModel.displayName
  }

  private var effectiveSkillCatalog: SkillCatalogSnapshot {
    refreshedSkillCatalog ?? skillCatalog
  }

  private var composerSuggestions: [ComposerSuggestion] {
    guard !suggestionsDismissed else {
      return []
    }
    if let token = draftState.slashSuggestionPrefix {
      return SlashCommandRegistry.matching(prefix: token).map(ComposerSuggestion.slash)
    }
    guard interactionMode == .agent, let token = draftState.skillSuggestionToken else {
      return []
    }
    return effectiveSkillCatalog.skills
      .filter { descriptor in
        token.prefix.isEmpty
          || descriptor.name.lowercased().hasPrefix(token.prefix.lowercased())
      }
      .map(ComposerSuggestion.skill)
  }

  private var suggestionDiagnostics: [SkillDiagnostic] {
    guard interactionMode == .agent, draftState.skillSuggestionToken != nil else {
      return []
    }
    return effectiveSkillCatalog.diagnostics
  }

  private var shouldShowSuggestionList: Bool {
    guard !suggestionsDismissed else { return false }
    return !composerSuggestions.isEmpty || !suggestionDiagnostics.isEmpty
  }

  private func clampedSuggestionIndex(for suggestions: [ComposerSuggestion]) -> Int {
    let count = suggestions.count
    guard count > 0 else {
      return 0
    }
    return min(max(suggestionSelectionIndex, 0), count - 1)
  }

  private var hasDraftText: Bool {
    draftState.hasText
  }

  private var canSendCurrentDraft: Bool {
    guard hasDraftText, !isSubmitting, !isPreparingTurn else {
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
    let previousSkillToken = draftState.skillSuggestionToken
    let previousSlashPrefix = draftState.slashSuggestionPrefix
    let wasDismissed = suggestionsDismissed
    draftState = state
    boundSkillMentions = ComposerSkillMentionEditor.validMentions(
      boundSkillMentions,
      in: draftBridge.text
    )
    if state.skillSuggestionToken != previousSkillToken
      || state.slashSuggestionPrefix != previousSlashPrefix
    {
      suggestionsDismissed = false
      suggestionSelectionIndex = 0
    }
    if interactionMode == .agent,
      state.skillSuggestionToken != nil,
      previousSkillToken == nil || wasDismissed
    {
      refreshSkills()
    }
  }

  private func moveSuggestionSelection(by delta: Int) -> KeyPress.Result {
    let suggestions = composerSuggestions
    guard !suggestions.isEmpty else {
      return .ignored
    }
    let selectedIndex = clampedSuggestionIndex(for: suggestions)
    suggestionSelectionIndex = min(max(selectedIndex + delta, 0), suggestions.count - 1)
    return .handled
  }

  private func commitSuggestionSelectionFromKey() -> KeyPress.Result {
    let suggestions = composerSuggestions
    guard !suggestions.isEmpty else {
      return .ignored
    }
    acceptSuggestion(suggestions[clampedSuggestionIndex(for: suggestions)])
    return .handled
  }

  private func dismissSuggestions() -> KeyPress.Result {
    guard shouldShowSuggestionList else {
      return .ignored
    }
    suggestionsDismissed = true
    return .handled
  }

  private func acceptSuggestion(_ suggestion: ComposerSuggestion) {
    switch suggestion {
    case .slash(let descriptor):
      acceptSlashSuggestion(descriptor)
    case .skill(let descriptor):
      acceptSkillSuggestion(descriptor)
    }
  }

  private func acceptSlashSuggestion(_ descriptor: SlashCommandDescriptor) {
    setDraftText(descriptor.token + " ")
    suggestionSelectionIndex = 0
    suggestionsDismissed = false
  }

  private func acceptSkillSuggestion(_ descriptor: SkillDescriptor) {
    guard let token = draftState.skillSuggestionToken else { return }
    let replacement = "$\(descriptor.name)"
    updateBoundMentions(replacing: token.range, with: replacement)
    let insertion = ComposerDraftTextEditor.inserting(
      replacement,
      into: draftBridge.text,
      selectedRange: token.range
    )
    let mention = SkillMention(
      id: descriptor.id,
      range: NSRange(location: token.range.location, length: (replacement as NSString).length)
    )
    boundSkillMentions.removeAll { $0.range == mention.range }
    boundSkillMentions.append(mention)
    boundSkillMentions.sort { $0.range.location < $1.range.location }
    draftBridge.replaceText(insertion.text, selectedRange: insertion.selectedRange)
    updateDraftState(
      ComposerDraftState(text: insertion.text, selectedRange: insertion.selectedRange)
    )
    suggestionSelectionIndex = 0
    suggestionsDismissed = true
  }

  private func refreshSkills() {
    Task { @MainActor in
      refreshedSkillCatalog = await onRefreshSkills()
    }
  }

  private func updateBoundMentions(replacing range: NSRange, with replacement: String) {
    boundSkillMentions = ComposerSkillMentionEditor.updating(
      boundSkillMentions,
      replacing: range,
      with: replacement
    )
  }

  private func sendMessage() {
    let suggestions = composerSuggestions
    if !suggestions.isEmpty {
      acceptSuggestion(suggestions[clampedSuggestionIndex(for: suggestions)])
      return
    }

    guard canSendCurrentDraft else {
      return
    }

    let submittedDraft = draftBridge.text
    let submittedMentions = ComposerSkillMentionEditor.validMentions(
      boundSkillMentions,
      in: submittedDraft
    )
    isSubmitting = true
    Task { @MainActor in
      let shouldClearDraft = await onSend(
        MessageSubmission(text: submittedDraft, skillMentions: submittedMentions)
      )
      let currentDraft = draftBridge.text
      if shouldClearDraft && (currentDraft.isEmpty || currentDraft == submittedDraft) {
        setDraftText("")
      }
      isSubmitting = false
    }
  }

  private func setDraftText(_ text: String) {
    boundSkillMentions = []
    let selectedRange = NSRange(location: (text as NSString).length, length: 0)
    draftBridge.replaceText(text, selectedRange: selectedRange)
    updateDraftState(ComposerDraftState(text: text, selectedRange: selectedRange))
  }

  private func insertSpeechTranscript(_ text: String) {
    updateBoundMentions(replacing: draftBridge.selectedRange, with: text)
    draftBridge.insertTextAtCurrentSelection(text)
    updateDraftState(
      ComposerDraftState(text: draftBridge.text, selectedRange: draftBridge.selectedRange)
    )
  }
}

extension ChatComposer {
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

extension ChatComposer {
  fileprivate var modeSelector: some View {
    HStack(spacing: 2) {
      ForEach(WorkspaceInteractionMode.allCases, id: \.self) { mode in
        modeButton(mode)
      }
    }
    .padding(2)
    .frame(width: 112, height: 28)
    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Mode")
    .accessibilityValue(interactionMode.displayName)
    .accessibilityIdentifier("chat.modePicker")
  }

  fileprivate func modeButton(_ mode: WorkspaceInteractionMode) -> some View {
    let isSelected = mode == interactionMode

    return Button {
      guard mode != interactionMode else {
        return
      }
      onSelectInteractionMode(mode)
    } label: {
      Text(mode.displayName)
        .font(.caption2.weight(isSelected ? .semibold : .medium))
        .foregroundStyle(modeButtonForeground(isSelected: isSelected))
        .frame(width: 52, height: 24)
        .background(
          modeButtonBackground(isSelected: isSelected),
          in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(modeButtonBorder(isSelected: isSelected), lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .disabled(!canChangeInteractionMode)
    .accessibilityLabel(mode.displayName)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityIdentifier("chat.mode.\(mode.rawValue)")
  }

  fileprivate func modeButtonForeground(isSelected: Bool) -> Color {
    guard isSelected else {
      return .secondary
    }
    return .white
  }

  fileprivate func modeButtonBackground(isSelected: Bool) -> Color {
    guard isSelected else {
      return .clear
    }
    return .accentColor
  }

  fileprivate func modeButtonBorder(isSelected: Bool) -> Color {
    isSelected ? Color.accentColor.opacity(0.65) : Color.clear
  }

}

struct ComposerDraftState: Equatable {
  var hasText = false
  var slashSuggestionPrefix: String?
  var slashCommandText: String?
  var selectedRange = NSRange(location: 0, length: 0)
  var skillSuggestionToken: ComposerSkillSuggestionToken?

  init() {}

  init(text: String, selectedRange: NSRange? = nil) {
    let textLength = (text as NSString).length
    let requestedRange = selectedRange ?? NSRange(location: textLength, length: 0)
    self.selectedRange = NSRange(
      location: min(max(requestedRange.location, 0), textLength),
      length: min(
        max(requestedRange.length, 0), textLength - min(max(requestedRange.location, 0), textLength)
      )
    )
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

    skillSuggestionToken = Self.skillToken(in: text, selectedRange: self.selectedRange)
  }

  private static func skillToken(
    in text: String,
    selectedRange: NSRange
  ) -> ComposerSkillSuggestionToken? {
    guard selectedRange.length == 0 else { return nil }
    let nsText = text as NSString
    let caret = selectedRange.location
    var tokenStart = caret
    while tokenStart > 0, isSkillNameCodeUnit(nsText.character(at: tokenStart - 1)) {
      tokenStart -= 1
    }
    guard tokenStart > 0, nsText.character(at: tokenStart - 1) == 36 else {
      return nil
    }
    let dollarLocation = tokenStart - 1
    guard
      dollarLocation == 0
        || !isSkillNameCodeUnit(nsText.character(at: dollarLocation - 1))
    else {
      return nil
    }
    var tokenEnd = caret
    while tokenEnd < nsText.length, isSkillNameCodeUnit(nsText.character(at: tokenEnd)) {
      tokenEnd += 1
    }
    return ComposerSkillSuggestionToken(
      prefix: nsText.substring(
        with: NSRange(location: tokenStart, length: caret - tokenStart)
      ),
      range: NSRange(location: dollarLocation, length: tokenEnd - dollarLocation)
    )
  }

  private static func isSkillNameCodeUnit(_ codeUnit: unichar) -> Bool {
    (codeUnit >= 48 && codeUnit <= 57)
      || (codeUnit >= 65 && codeUnit <= 90)
      || (codeUnit >= 97 && codeUnit <= 122)
      || codeUnit == 45
  }
}

struct ComposerSkillSuggestionToken: Equatable {
  let prefix: String
  let range: NSRange
}

enum ComposerSkillMentionEditor {
  static func updating(
    _ mentions: [SkillMention],
    replacing editedRange: NSRange,
    with replacement: String
  ) -> [SkillMention] {
    let replacementLength = (replacement as NSString).length
    let delta = replacementLength - editedRange.length
    let editedUpperBound = editedRange.location + editedRange.length
    return mentions.compactMap { mention in
      let mentionUpperBound = mention.range.location + mention.range.length
      if editedRange.length == 0 {
        if editedRange.location <= mention.range.location {
          return SkillMention(
            id: mention.id,
            range: NSRange(
              location: mention.range.location + delta,
              length: mention.range.length
            )
          )
        }
        if editedRange.location >= mentionUpperBound {
          return mention
        }
        return nil
      }
      if editedUpperBound <= mention.range.location {
        return SkillMention(
          id: mention.id,
          range: NSRange(
            location: mention.range.location + delta,
            length: mention.range.length
          )
        )
      }
      if editedRange.location >= mentionUpperBound {
        return mention
      }
      return nil
    }
  }

  static func validMentions(_ mentions: [SkillMention], in text: String) -> [SkillMention] {
    let nsText = text as NSString
    return mentions.filter { mention in
      guard mention.range.location >= 0,
        mention.range.length > 1,
        mention.range.location + mention.range.length <= nsText.length
      else {
        return false
      }
      let upperBound = mention.range.location + mention.range.length
      let hasValidLeadingBoundary =
        mention.range.location == 0
        || !isSkillNameCodeUnit(nsText.character(at: mention.range.location - 1))
      let hasValidTrailingBoundary =
        upperBound == nsText.length
        || !isSkillNameCodeUnit(nsText.character(at: upperBound))
      return hasValidLeadingBoundary
        && hasValidTrailingBoundary
        && nsText.substring(with: mention.range) == "$\(mention.id.name)"
    }
  }

  private static func isSkillNameCodeUnit(_ codeUnit: unichar) -> Bool {
    (codeUnit >= 48 && codeUnit <= 57)
      || (codeUnit >= 65 && codeUnit <= 90)
      || (codeUnit >= 97 && codeUnit <= 122)
      || codeUnit == 45
  }
}

private final class ComposerDraftBridge {
  private weak var textView: ComposerNSTextView?
  private var storedText = ""

  var text: String {
    textView?.string ?? storedText
  }

  var selectedRange: NSRange {
    textView?.selectedRange() ?? NSRange(location: (storedText as NSString).length, length: 0)
  }

  func bind(_ textView: ComposerNSTextView) {
    self.textView = textView
    storedText = textView.string
  }

  func noteTextDidChange(_ text: String) {
    storedText = text
  }

  func replaceText(
    _ text: String,
    selectedRange: NSRange? = nil
  ) {
    storedText = text
    textView?.replaceAllText(text, selectedRange: selectedRange)
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
      // Status sits to the left of the icon so the mic stays the trailing
      // anchor of the row and the transient text grows inward, not off-edge.
      if let statusText = controller.statusText {
        Text(statusText)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(statusForeground)
          .lineLimit(1)
          .frame(maxWidth: 150, alignment: .trailing)
      }

      Button {
        controller.toggle(
          onTranscript: onTranscript,
          onNeedsAudioModel: onNeedsAudioModel
        )
      } label: {
        Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(buttonForeground)
          .frame(width: 28, height: 28)
          .background(buttonBackground, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(isButtonDisabled)
      .help(helpText)
      .accessibilityLabel(controller.isRecording ? "Stop dictation" : "Start dictation")
      .accessibilityIdentifier("chat.speechInput")
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
  let canAcceptAttachments: Bool
  let isEditable: Bool
  let onTextEdit: (NSRange, String) -> Void
  let onTextStateChanged: (ComposerDraftState) -> Void
  let onSubmit: () -> Void
  let onMoveSuggestionSelection: (Int) -> KeyPress.Result
  let onCommitSuggestionSelection: () -> KeyPress.Result
  let onDismissSuggestions: () -> KeyPress.Result
  let onPasteboardAttachments: (NSPasteboard) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      draftBridge: draftBridge,
      onTextEdit: onTextEdit,
      onTextStateChanged: onTextStateChanged
    )
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
    context.coordinator.onTextEdit = onTextEdit
    context.coordinator.onTextStateChanged = onTextStateChanged
    draftBridge.bind(textView)
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
    }
    textView.canAcceptAttachments = canAcceptAttachments
    textView.onSubmit = onSubmit
    textView.onMoveSuggestionSelection = onMoveSuggestionSelection
    textView.onCommitSuggestionSelection = onCommitSuggestionSelection
    textView.onDismissSuggestions = onDismissSuggestions
    textView.onPasteboardAttachments = onPasteboardAttachments
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.textColor = .labelColor
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
    var onTextEdit: (NSRange, String) -> Void
    var onTextStateChanged: (ComposerDraftState) -> Void

    init(
      draftBridge: ComposerDraftBridge,
      onTextEdit: @escaping (NSRange, String) -> Void,
      onTextStateChanged: @escaping (ComposerDraftState) -> Void
    ) {
      self.draftBridge = draftBridge
      self.onTextEdit = onTextEdit
      self.onTextStateChanged = onTextStateChanged
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      onTextEdit(affectedCharRange, replacementString ?? "")
      return true
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else {
        return
      }

      let previousText = draftBridge.text
      draftBridge.noteTextDidChange(textView.string)
      onTextStateChanged(
        ComposerDraftState(text: textView.string, selectedRange: textView.selectedRange())
      )
      if previousText.isEmpty != textView.string.isEmpty {
        textView.needsDisplay = true
      }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      onTextStateChanged(
        ComposerDraftState(text: textView.string, selectedRange: textView.selectedRange())
      )
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
  var onMoveSuggestionSelection: ((Int) -> KeyPress.Result)?
  var onCommitSuggestionSelection: (() -> KeyPress.Result)?
  var onDismissSuggestions: (() -> KeyPress.Result)?
  var onPasteboardAttachments: ((NSPasteboard) -> Bool)?

  func replaceAllText(_ newText: String, selectedRange: NSRange? = nil) {
    let wasEmpty = string.isEmpty
    if string != newText {
      string = newText
    }
    setSelectedRange(
      selectedRange ?? NSRange(location: (newText as NSString).length, length: 0)
    )
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
      if didHandle(onMoveSuggestionSelection?(-1)) {
        return
      }
      super.keyDown(with: event)
    case 125:
      if didHandle(onMoveSuggestionSelection?(1)) {
        return
      }
      super.keyDown(with: event)
    case 48:
      if didHandle(onCommitSuggestionSelection?()) {
        return
      }
      super.keyDown(with: event)
    case 53:
      if didHandle(onDismissSuggestions?()) {
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
