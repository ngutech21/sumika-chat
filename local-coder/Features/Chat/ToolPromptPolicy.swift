import Foundation

nonisolated enum ToolPromptMode: Sendable {
  case disabled
  case enabled(Bool)
  case afterToolResult
}

nonisolated struct ToolPromptPolicy: Sendable {
  private let payloadDelimiter: String

  init(payloadDelimiter: String = "LC_PAYLOAD_V1") {
    self.payloadDelimiter = payloadDelimiter
  }

  func shouldAllowToolCalls(
    workspace: Workspace?,
    prompt: String,
    attachments: [ChatAttachment]
  ) -> Bool {
    guard workspace != nil else {
      return false
    }

    if !attachments.isEmpty {
      return true
    }

    let normalizedPrompt = prompt.lowercased()
    let explicitToolIntentPhrases = [
      "read ",
      "open ",
      "show ",
      "inspect",
      "look at",
      "list files",
      "list the files",
      "what files",
      "which files",
      "file",
      "folder",
      "directory",
      "workspace",
      "repo",
      "repository",
      "project",
      "source",
      "code",
      "implementation",
      "readme",
    ]

    if explicitToolIntentPhrases.contains(where: { normalizedPrompt.contains($0) }) {
      return true
    }

    return ChatAttachmentLimits.supportedTextFileExtensions.contains { fileExtension in
      normalizedPrompt.contains(".\(fileExtension)")
    }
  }

  func systemPrompt(
    basePrompt: String,
    mode: ToolPromptMode,
    toolRegistry: ToolRegistry,
    toolPromptRenderer: any ToolPromptRendering
  ) -> String {
    switch mode {
    case .disabled, .enabled(false):
      return basePrompt
    case .afterToolResult:
      return [
        basePrompt,
        """
        You just received a tool result. Use it to answer the user's request directly.
        Do not emit another <action> tag in this response.
        """,
      ].joined(separator: "\n\n")
    case .enabled(true):
      return [
        basePrompt,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    }
  }
}
