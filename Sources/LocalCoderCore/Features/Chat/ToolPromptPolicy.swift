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
    sessionID: ChatSession.ID?
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
    toolPromptRenderer: any ToolPromptRendering,
    toolCallingPolicy: ToolCallingPolicy = .taggedAction
  ) -> String {
    switch mode {
    case .disabled, .enabled(false):
      return basePrompt
    case .inspect:
      guard toolCallingPolicy.strategy != .nativeGemma4 else {
        return nativeInspectSystemPrompt(
          basePrompt: basePrompt,
          toolRegistry: toolRegistry,
          toolCallingPolicy: toolCallingPolicy
        )
      }
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
        - To review current workspace changes, use workspace_diff.
        - If enough information is already visible in context, answer directly.
        - Never emit write_file or edit_file actions in Inspect mode.
        """,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    case .afterInspectToolResultCanContinue:
      guard toolCallingPolicy.strategy != .nativeGemma4 else {
        return nativeFollowUpSystemPrompt(
          basePrompt: basePrompt,
          toolRegistry: toolRegistry,
          readOnly: true,
          toolCallingPolicy: toolCallingPolicy
        )
      }
      return [
        basePrompt,
        """
        You received a read-only tool result. Answer now if sufficient, or call one more
        read-only tool using the same action format. Do not modify files.
        Available tools: \(availableToolNames(in: toolRegistry)).
        """,
      ].joined(separator: "\n\n")
    case .afterToolResultCanContinue:
      guard toolCallingPolicy.strategy != .nativeGemma4 else {
        return nativeFollowUpSystemPrompt(
          basePrompt: basePrompt,
          toolRegistry: toolRegistry,
          readOnly: false,
          toolCallingPolicy: toolCallingPolicy
        )
      }
      return [
        basePrompt,
        """
        You received a tool result. Answer now if sufficient, or call one more tool using
        the same action format. If editing, call edit_file with exact old_text copied from
        current file content.
        Available tools: \(availableToolNames(in: toolRegistry)).
        """,
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
      guard toolCallingPolicy.strategy != .nativeGemma4 else {
        return nativeAgentSystemPrompt(
          basePrompt: basePrompt,
          toolRegistry: toolRegistry,
          toolCallingPolicy: toolCallingPolicy
        )
      }
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
        - To review current workspace changes, use workspace_diff.
        - To run build, test, lint, or project verification commands after approval, use run_command.
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

        run_command rules:
        - For destructive commands such as rm, mv, or overwrite operations, use explicit workspace-relative
          operands like ./tmp and include -- before path operands when the command supports it, e.g. rm -rf -- ./tmp.

        Do not generate Python, shell, sed, awk, or helper scripts to write files.
        """,
        toolPromptRenderer.renderToolInstructions(
          registry: toolRegistry,
          payloadDelimiter: payloadDelimiter
        ),
      ].joined(separator: "\n\n")
    }
  }

  private func availableToolNames(in registry: ToolRegistry) -> String {
    registry.tools.map(\.name.rawValue).joined(separator: ", ")
  }

  private func nativeInspectSystemPrompt(
    basePrompt: String,
    toolRegistry: ToolRegistry,
    toolCallingPolicy: ToolCallingPolicy
  ) -> String {
    [
      basePrompt,
      """
      Read-only workspace tools are available through the native tool-calling interface.
      Use the provided tool schemas when you need to inspect workspace files. Do not modify files.
      Available tools: \(availableToolNames(in: toolRegistry)).
      \(nativeMultipleToolCallInstruction(policy: toolCallingPolicy))

      Read-only workflow:
      - To display file contents directly to the user, use show_file.
      - To inspect, explain, summarize, search within, or reason about a file, use read_file.
      - To find files by name, use glob_files or list_files.
      - To search code contents, use search_files.
      - To review current workspace changes, use workspace_diff.
      - If enough information is already visible in context, answer directly.
      - Never call write_file or edit_file in Inspect mode.
      """,
    ].joined(separator: "\n\n")
  }

  private func nativeAgentSystemPrompt(
    basePrompt: String,
    toolRegistry: ToolRegistry,
    toolCallingPolicy: ToolCallingPolicy
  ) -> String {
    [
      basePrompt,
      """
      Workspace tools are available through the native tool-calling interface.
      Use the provided tool schemas for workspace file inspection and modification.
      Available tools: \(availableToolNames(in: toolRegistry)).
      \(nativeMultipleToolCallInstruction(policy: toolCallingPolicy))

      File workflow:
      - To display file contents directly to the user, use show_file.
      - To inspect, explain, summarize, search within, reason about, or modify a file, use read_file.
      - To find files by name, use glob_files or list_files.
      - To search code contents, use search_files.
      - To review current workspace changes, use workspace_diff.
      - To run build, test, lint, or project verification commands after approval, use run_command.
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

      run_command rules:
      - For destructive commands such as rm, mv, or overwrite operations, use explicit workspace-relative
        operands like ./tmp and include -- before path operands when the command supports it, e.g. rm -rf -- ./tmp.

      Do not generate Python, shell, sed, awk, or helper scripts to write files.
      """,
    ].joined(separator: "\n\n")
  }

  private func nativeFollowUpSystemPrompt(
    basePrompt: String,
    toolRegistry: ToolRegistry,
    readOnly: Bool,
    toolCallingPolicy: ToolCallingPolicy
  ) -> String {
    let modeInstruction =
      readOnly
      ? "Answer now if sufficient, or call read-only tools using the native tool interface."
      : "Answer now if sufficient, or call tools using the native tool interface."
    return [
      basePrompt,
      """
      You received a tool result. \(modeInstruction)
      Available tools: \(availableToolNames(in: toolRegistry)).
      \(nativeMultipleToolCallInstruction(policy: toolCallingPolicy))
      """,
    ].joined(separator: "\n\n")
  }

  private func nativeMultipleToolCallInstruction(policy: ToolCallingPolicy) -> String {
    guard policy.allowsMultipleToolCalls else {
      return "Emit at most one native tool call, then wait for the result."
    }
    return
      "You may emit multiple native tool calls only when they are independent and can run before "
      + "seeing any result. For dependent steps, emit one tool call and wait for the result."
  }
}
