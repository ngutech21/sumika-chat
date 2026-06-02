import Foundation

nonisolated enum ToolPromptMode: Sendable {
  case disabled
  case enabled(Bool)
  case afterToolResultCanContinue
  case afterToolResultFinal
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
      "edit",
      "modify",
      "replace",
      "change",
      "update",
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
    case .afterToolResultCanContinue:
      return [
        basePrompt,
        """
        You just received a tool result. If the result gives enough information to finish,
        answer the user's request directly. If the user asked you to modify an existing file
        and this result contains the file content needed for an exact edit, emit one edit_file
        action with exact old_text and new_text.
        """,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    case .afterToolResultFinal:
      return [
        basePrompt,
        """
        You just received a tool result and the tool budget for this request is exhausted.
        Answer the user's request directly. Do not emit another <action> tag in this response.
        If more work is needed, briefly say what remains and ask the user to send another message.
        """,
      ].joined(separator: "\n\n")
    case .enabled(true):
      return [
        basePrompt,
        """
        When the user asks you to create a file, emit a write_file action with the full desired
        file content. When the user asks you to modify an existing file, prefer read_file followed
        by edit_file with exact old_text and new_text. Do not generate Python, shell, or other
        helper scripts to write files.
        """,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    }
  }
}
