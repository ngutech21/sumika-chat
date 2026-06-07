import Foundation
import Testing

@testable import LocalCoderCore

struct ToolPromptPolicyTests {
  @Test
  func toolAvailabilityIsUnavailableWithoutWorkspace() {
    let policy = ToolPromptPolicy()
    let sessionID = UUID()

    let availability = policy.toolAvailability(
      workspace: nil,
      sessionID: sessionID
    )

    #expect(availability == .unavailable)
  }

  @Test
  func toolAvailabilityIsUnavailableWithoutSession() {
    let policy = ToolPromptPolicy()
    let sessionID = UUID()

    let availability = policy.toolAvailability(
      workspace: makeWorkspace(sessionID: sessionID),
      sessionID: nil
    )

    #expect(availability == .unavailable)
  }

  @Test
  func toolAvailabilityIsUnavailableForUnknownSession() {
    let policy = ToolPromptPolicy()
    let sessionID = UUID()

    let availability = policy.toolAvailability(
      workspace: makeWorkspace(sessionID: sessionID),
      sessionID: UUID()
    )

    #expect(availability == .unavailable)
  }

  @Test
  func toolAvailabilityIsAvailableForWorkspaceSession() {
    let policy = ToolPromptPolicy()
    let sessionID = UUID()

    let availability = policy.toolAvailability(
      workspace: makeWorkspace(sessionID: sessionID),
      sessionID: sessionID
    )

    #expect(availability == .availableForWorkspace)
  }

  @Test
  func includesToolInstructionsOnlyWhenEnabled() {
    let policy = ToolPromptPolicy(payloadDelimiter: "LC_PAYLOAD_TEST")
    let registry = ToolExecutorRegistry.readOnly.toolRegistry
    let renderer = TaggedToolPromptRenderer()

    let disabledPrompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .disabled,
      toolRegistry: registry,
      toolPromptRenderer: renderer
    )
    let enabledPrompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: registry,
      toolPromptRenderer: renderer
    )

    #expect(disabledPrompt == "Base")
    #expect(enabledPrompt.contains("Base"))
    #expect(enabledPrompt.contains("read_file"))
    #expect(enabledPrompt.contains("show_file"))
    #expect(enabledPrompt.contains("LC_PAYLOAD_TEST"))
  }

  @Test
  func inspectPromptIncludesOnlyReadOnlyTools() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .inspect,
      toolRegistry: ToolExecutorRegistry.readOnly.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer()
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("Tools:"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("show_file"))
    #expect(prompt.contains("list_files"))
    #expect(prompt.contains("glob_files"))
    #expect(prompt.contains("search_files"))
    #expect(prompt.contains("workspace_diff"))
    #expect(prompt.contains("Do not modify files"))
    #expect(!prompt.contains("- write_file("))
    #expect(!prompt.contains("- edit_file("))
  }

  @Test
  func enabledPromptIncludesStrictToolWorkflowRules() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer()
    )

    #expect(prompt.contains("Emit exactly one complete <action> block, then stop."))
    #expect(prompt.contains("Do not include explanatory text before or after an <action>."))
    #expect(prompt.contains("Do not wrap actions in Markdown fences."))
    #expect(prompt.contains("Use workspace-relative paths."))
    #expect(prompt.contains("To display file contents directly to the user, use show_file."))
    #expect(prompt.contains("To inspect, explain, summarize, search within, reason about"))
    #expect(prompt.contains("To find files by name, use glob_files or list_files."))
    #expect(prompt.contains("To search code contents, use search_files."))
    #expect(prompt.contains("To review current workspace changes, use workspace_diff."))
    #expect(prompt.contains("first call todo_write with the full current plan as 2 to 6 items"))
    #expect(prompt.contains("Never send only the next step."))
    #expect(prompt.contains("run_command"))
    #expect(prompt.contains("To create a new file, use write_file"))
    #expect(prompt.contains("To modify an existing file, use read_file first"))
    #expect(prompt.contains("For targeted edits to existing files, use edit_file."))
    #expect(prompt.contains("Use write_file on an existing file only"))
    #expect(prompt.contains("Never edit existing files from memory."))
    #expect(prompt.contains("old_text must be copied exactly from current file content."))
    #expect(prompt.contains("Do not include line-number prefixes in old_text."))
    #expect(prompt.contains("old_text matches exactly once."))
    #expect(prompt.contains("If old_text is not found, read the file"))
    #expect(prompt.contains("For destructive commands such as rm"))
    #expect(prompt.contains("rm -rf -- ./tmp"))
    #expect(prompt.contains("Do not generate Python, shell, sed, awk, or helper scripts"))
  }

  @Test
  func nativeGemma4PromptAllowsOnlyIndependentMultipleToolCalls() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer(),
      toolCallingPolicy: .nativeGemma4
    )

    #expect(prompt.contains("native tool-calling interface"))
    #expect(prompt.contains("multiple native tool calls only when they are independent"))
    #expect(prompt.contains("For dependent steps, emit one tool call and wait for the result."))
    #expect(!prompt.contains("<action"))
  }

  @Test
  func afterToolResultCanContinuePromptUsesCompactContinuation() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultCanContinue,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer()
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("You received a tool result."))
    #expect(prompt.contains("Answer now if sufficient"))
    #expect(prompt.contains("call one more tool using"))
    #expect(prompt.contains("same action format"))
    #expect(prompt.contains("do not call todo_write again unless the plan actually changed"))
    #expect(prompt.contains("call edit_file with exact old_text copied from"))
    #expect(prompt.contains("current file content"))
    #expect(
      prompt.contains(
        "Available tools: read_file, show_file, list_files, glob_files, search_files, workspace_diff, workspace_diagnostics, edit_file, write_file, run_command, todo_write, ask_user, web_search, web_fetch."
      ))
    #expect(prompt.contains("edit_file"))
    #expect(!prompt.contains("Tool calling:"))
    #expect(!prompt.contains("Tools:"))
    #expect(!prompt.contains(#"<action name="read_file">"#))
    #expect(!prompt.contains("Multiline payload example:"))
  }

  @Test
  func afterInspectToolResultPromptUsesReadOnlyCompactContinuation() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .afterInspectToolResultCanContinue,
      toolRegistry: ToolExecutorRegistry.readOnly.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer()
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("You received a read-only tool result."))
    #expect(prompt.contains("Answer now if sufficient"))
    #expect(prompt.contains("call one more"))
    #expect(prompt.contains("same action format"))
    #expect(
      prompt.contains(
        "Available tools: read_file, show_file, list_files, glob_files, search_files, workspace_diff, workspace_diagnostics."
      ))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("list_files"))
    #expect(prompt.contains("glob_files"))
    #expect(prompt.contains("search_files"))
    #expect(prompt.contains("workspace_diff"))
    #expect(prompt.contains("Do not modify files"))
    #expect(!prompt.contains("edit_file"))
    #expect(!prompt.contains("write_file"))
    #expect(!prompt.contains("Tool calling:"))
    #expect(!prompt.contains("Tools:"))
    #expect(!prompt.contains(#"<action name="read_file">"#))
    #expect(!prompt.contains("Multiline payload example:"))
  }

  @Test
  func nativeInspectToolResultPromptDoesNotMentionTodoWrite() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .afterInspectToolResultCanContinue,
      toolRegistry: ToolExecutorRegistry.readOnly.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer(),
      toolCallingPolicy: .nativeGemma4
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("read-only tools using the native tool interface"))
    #expect(
      prompt.contains(
        "Available tools: read_file, show_file, list_files, glob_files, search_files, workspace_diff, workspace_diagnostics."
      ))
    #expect(!prompt.contains("todo_write"))
    #expect(!prompt.contains("Plan updated."))
  }

  @Test
  func finalToolResultPromptDisablesFurtherToolActions() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultFinal,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer()
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("No more tools may run in this response."))
    #expect(prompt.contains("Do not emit another <action> tag."))
    #expect(!prompt.contains("tool budget"))
    #expect(!prompt.contains("Available tools:"))
  }

  private func makeWorkspace(sessionID: ChatSession.ID) -> Workspace {
    Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project"),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
  }
}
