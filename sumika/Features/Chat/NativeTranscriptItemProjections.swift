import AppKit
import SumikaCore

// Pure value-mapping projections from the persisted transcript model to the
// strings, flags, and styling the AppKit transcript views render. These have no
// AppKit view dependencies and are consumed by NativeChatMessageCellView and its
// subviews; kept module-internal so those views (and tests) can reach them.

extension NativeTranscriptRow {
  var accessibilityIdentifier: String {
    switch body {
    case .generationIndicator:
      "chat.generationSpinner"
    case .item(let item):
      item.nativeAccessibilityIdentifier
    }
  }

  var accessibilityLabel: String {
    switch body {
    case .generationIndicator:
      "Generating"
    case .item(let item):
      item.nativeAccessibilityLabel
    }
  }
}

extension RenderedChatTurnItem {
  var shouldShowAssistantPlaceholder: Bool {
    assistantMessage?.shouldShowAssistantPlaceholder ?? false
  }

  var isStreamingAssistantMessage: Bool {
    assistantMessage?.deliveryStatus == .streaming
  }

  var isStreamingAssistantThinkingMessage: Bool {
    guard case .assistantThinking(let message) = item else {
      return false
    }
    return message.deliveryStatus == .streaming
  }

  var assistantPlaceholderTitle: String {
    assistantMessage?.assistantPlaceholderTitle ?? "Generating"
  }

  var content: String {
    switch item {
    case .userMessage(let message):
      message.content
    case .assistantThinking(let message):
      message.content
    case .assistantMessage(let message):
      message.content
    case .tool:
      ""
    }
  }

  var visibleGenerationMetrics: ChatGenerationMetrics? {
    switch item {
    case .tool:
      nil
    case .assistantThinking, .assistantMessage, .userMessage:
      generationMetrics
    }
  }

  var nativeAccessibilityIdentifier: String {
    switch item {
    case .assistantThinking:
      "chat.assistantThinking"
    case .assistantMessage:
      "chat.assistantMessage"
    case .userMessage:
      "chat.userMessage"
    case .tool:
      "chat.toolCallMessage"
    }
  }

  var nativeAccessibilityLabel: String {
    switch item {
    case .userMessage:
      return "User message"
    case .assistantThinking:
      return "Assistant reasoning"
    case .assistantMessage:
      return shouldShowAssistantPlaceholder ? assistantPlaceholderTitle : "Assistant message"
    case .tool(let record):
      let parts: [String?] = [
        "Tool \(record.request.toolName.rawValue)",
        record.status.nativeDisplayName,
        record.approvalSource == .automatic ? "auto-approved" : nil,
      ]
      return parts.compactMap(\.self).joined(separator: ", ")
    }
  }

  var isNativeUserMessage: Bool {
    guard case .userMessage = item else {
      return false
    }
    return true
  }

  var nativeMaximumBubbleWidth: CGFloat {
    switch item {
    case .tool:
      460
    case .assistantThinking, .assistantMessage, .userMessage:
      680
    }
  }

  var canNativeCopyMessageContent: Bool {
    switch item {
    case .userMessage(let message):
      !message.content.isEmpty
    case .assistantThinking:
      false
    case .assistantMessage(let message):
      message.canCopyAssistantContent
    case .tool:
      false
    }
  }

  var nativeSpokenText: String? {
    guard case .assistantMessage = item else {
      return nil
    }
    return assistantSpokenText
  }

  var nativeAttachments: [ChatAttachment] {
    switch item {
    case .userMessage(let message):
      message.attachments
    case .assistantThinking:
      []
    case .assistantMessage(let message):
      message.attachments
    case .tool:
      []
    }
  }

  private var assistantMessage: AssistantTurnMessage? {
    guard case .assistantMessage(let message) = item else {
      return nil
    }
    return message
  }
}

extension ToolCallRecord {
  var transcriptToolCall: ToolCallModelMessage {
    var toolCall = ToolCallModelMessage(request: request)
    toolCall.arguments = toolCall.transcriptArguments
    return toolCall
  }

  var nativeAskUserInput: AskUserInput? {
    guard case .askUser(let input) = request.payload else {
      return nil
    }
    return input
  }

  var hasNativeToolDetails: Bool {
    !NativeToolDetailContent(record: self).isEmpty
  }
}

extension ToolDisplayPayload {
  var nativeOutputTitle: String? {
    switch self {
    case .fileContent:
      "File content"
    case .fileList:
      "Files"
    case .searchResults:
      "Matches"
    case .workspaceDiff:
      "Diff"
    case .summary(_, let text, _):
      text.isEmpty ? nil : "Result"
    }
  }

  var nativeOutputText: String? {
    let text =
      switch self {
      case .fileContent(_, let content):
        content.text
      case .fileList(_, let entries, _):
        entries.isEmpty
          ? "(empty)"
          : entries.map { entry in
            entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
          }.joined(separator: "\n")
      case .searchResults(_, _, let matches, _):
        matches.isEmpty
          ? "(no matches)"
          : matches.map { "\($0.path.rawValue):\($0.line): \($0.snippet)" }
            .joined(separator: "\n")
      case .workspaceDiff(_, let content):
        content.text
      case .summary(_, let text, _):
        text
      }
    return text.isEmpty ? nil : text
  }

  var nativeAffectedPaths: [String] {
    switch self {
    case .fileContent(let path, _):
      [path.rawValue]
    case .fileList(let root, _, _), .searchResults(let root, _, _, _):
      [root.rawValue]
    case .workspaceDiff(let path, _):
      path.map { [$0.rawValue] } ?? []
    case .summary(_, _, let paths):
      paths.map(\.rawValue)
    }
  }

  var nativeFlags: [String] {
    switch self {
    case .fileContent(_, let content), .workspaceDiff(_, let content):
      content.nativeFlags
    case .fileList(_, _, let truncated), .searchResults(_, _, _, let truncated):
      truncated ? ["truncated"] : []
    case .summary:
      []
    }
  }
}

extension ToolTextOutput {
  var nativeFlags: [String] {
    var flags: [String] = []
    if truncated {
      flags.append("truncated")
    }
    if redacted {
      flags.append("redacted")
    }
    return flags
  }
}

extension ToolResultPreview {
  var nativeFlags: [String] {
    var flags: [String] = []
    if truncated {
      flags.append("truncated")
    }
    if redacted {
      flags.append("redacted")
    }
    return flags
  }
}

extension ToolCallModelMessage {
  var nativeHeaderSummary: String? {
    func argumentValue(named name: String) -> String? {
      guard let value = arguments.first(where: { $0.name == name })?.value,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      return value
    }

    switch toolName {
    case .runCommand:
      return argumentValue(named: "command")
    case .writeFile, .editFile, .readFile, .showFile:
      return argumentValue(named: "path")
    case .webSearch:
      return argumentValue(named: "query")
    case .webFetch:
      return argumentValue(named: "url")
    case .browserInspect:
      return argumentValue(named: "selector") ?? "document.body"
    case .browserRefresh:
      return argumentValue(named: "hard")
    default:
      return nil
    }
  }
}

extension ToolCallStatus {
  var nativeDisplayName: String {
    switch self {
    case .pending:
      "pending"
    case .awaitingApproval:
      "approval"
    case .awaitingUserAnswer:
      "question"
    case .denied:
      "denied"
    case .running:
      "running"
    case .completed:
      "done"
    case .failed:
      "failed"
    case .cancelled:
      "cancelled"
    }
  }

  var nativeIsInProgress: Bool {
    switch self {
    case .pending, .running:
      true
    case .awaitingApproval, .awaitingUserAnswer, .denied, .completed, .failed, .cancelled:
      false
    }
  }

  var nativeQuietSystemImage: String {
    switch self {
    case .completed:
      "checkmark"
    case .failed, .denied:
      "xmark"
    case .cancelled:
      "minus"
    case .awaitingApproval, .awaitingUserAnswer:
      "exclamationmark"
    case .pending, .running:
      "ellipsis"
    }
  }

  var nativeQuietColor: NSColor {
    switch self {
    case .completed:
      .systemGreen
    case .failed, .denied:
      .systemOrange
    case .cancelled:
      .secondaryLabelColor
    case .awaitingApproval, .awaitingUserAnswer:
      .systemOrange
    case .pending, .running:
      .secondaryLabelColor
    }
  }
}

extension ChatGenerationMetrics {
  var visibleSummary: String {
    "\(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
  }
}
