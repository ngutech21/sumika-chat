import Foundation

public enum ToolPromptMode: Equatable, Sendable {
  case disabled
  case enabled(Bool)
  case inspect
  case afterInspectToolResultCanContinue
  case afterToolResultCanContinue
  case afterToolResultFinal
}

public enum ToolAvailability: Equatable, Sendable {
  case unavailable
  case availableForWorkspace
}

public struct ToolPromptPolicy: Sendable {
  private let payloadDelimiter: String

  public init(payloadDelimiter: String = "LC_PAYLOAD_V1") {
    self.payloadDelimiter = payloadDelimiter
  }

  public func toolAvailability(
    workspace: Workspace?,
    sessionID: CodingSession.ID?
  ) -> ToolAvailability {
    guard
      let workspace,
      let sessionID,
      workspace.sessions.contains(where: { $0.id == sessionID })
    else {
      return .unavailable
    }

    return .availableForWorkspace
  }

  public func systemPrompt(
    basePrompt: String,
    mode: ToolPromptMode,
    toolRegistry: ToolRegistry,
    toolPromptRenderer: any ToolPromptRendering
  ) -> String {
    switch mode {
    case .disabled, .enabled(false):
      return basePrompt
    case .inspect:
      return [
        basePrompt,
        """
        When read-only tools are available, use them to inspect workspace files and answer
        questions about the project. Do not modify files.

        Tool-use protocol:
        - Emit exactly one complete <action> block, then stop.
        - Do not include explanatory text before or after an <action>.
        - Do not wrap actions in Markdown fences.
        - Use workspace-relative paths.

        Read-only workflow:
        - To display file contents directly to the user, use show_file.
        - To inspect, explain, summarize, search within, or reason about a file, use read_file.
        - To find files by name, use glob_files or list_files.
        - To search code contents, use search_files.
        - If enough information is already visible in context, answer directly.
        - Never emit write_file or edit_file actions in Inspect mode.
        """,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    case .afterInspectToolResultCanContinue:
      return [
        basePrompt,
        """
        You just received a read-only tool result. Use it to answer the user's request or
        continue inspecting the workspace. If the result gives enough information to finish,
        answer directly. If more read-only context is needed, emit at most one <action> block,
        then stop. Do not modify files.
        """,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    case .afterToolResultCanContinue:
      return [
        basePrompt,
        """
        You just received a tool result. Use it to continue the user's request.
        If the result gives enough information to finish, answer directly.
        If the user asked you to modify an existing file and the result contains current file
        content, emit at most one edit_file action using old_text copied exactly from that content.
        If a previous edit_file failed because old_text was not found or was ambiguous, retry with
        exact current text and more surrounding context. Emit at most one <action> block, then stop.
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
        You just received a tool result. No more tools may run in this response.
        Answer the user's request directly. Do not emit another <action> tag.
        If more work is needed, briefly say what remains and ask the user to send another message.
        """,
      ].joined(separator: "\n\n")
    case .enabled(true):
      return [
        basePrompt,
        """
        When tools are available, use them for workspace file inspection and modification.

        Tool-use protocol:
        - Emit exactly one complete <action> block, then stop.
        - Do not include explanatory text before or after an <action>.
        - Do not wrap actions in Markdown fences.
        - Use workspace-relative paths.

        File workflow:
        - To display file contents directly to the user, use show_file.
        - To inspect, explain, summarize, search within, reason about, or modify a file, use read_file.
        - To find files by name, use glob_files or list_files.
        - To search code contents, use search_files.
        - To create a new file, use write_file with the complete file content.
        - To modify an existing file, use read_file first unless the exact current file content is
          already visible in this request context.
        - For targeted edits to existing files, use edit_file.
        - Use write_file on an existing file only for intentional full-file replacement.
        - Never edit existing files from memory.

        edit_file rules:
        - old_text must be copied exactly from current file content.
        - Do not include line-number prefixes in old_text.
        - Include enough surrounding context so old_text matches exactly once.
        - If old_text is not found, read the file and retry with exact copied text.
        - If old_text matches multiple locations, retry with more surrounding context.

        Do not generate Python, shell, sed, awk, or helper scripts to write files.
        """,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    }
  }
}
