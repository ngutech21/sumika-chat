import Foundation
import Testing

@testable import LocalCoderCore

struct ToolPromptPolicyTests {
  @Test
  func disablesToolsWithoutWorkspace() {
    let policy = ToolPromptPolicy()

    let allowsTools = policy.shouldAllowToolCalls(
      workspace: nil,
      prompt: "read README.md",
      attachments: []
    )

    #expect(!allowsTools)
  }

  @Test
  func enablesToolsForAttachments() {
    let policy = ToolPromptPolicy()

    let allowsTools = policy.shouldAllowToolCalls(
      workspace: makeWorkspace(),
      prompt: "summarize this",
      attachments: [
        ChatAttachment(
          url: URL(filePath: "/tmp/README.md"),
          displayName: "README.md",
          kind: .text,
          content: "notes"
        )
      ]
    )

    #expect(allowsTools)
  }

  @Test
  func enablesToolsForExplicitCodeIntent() {
    let policy = ToolPromptPolicy()

    let allowsTools = policy.shouldAllowToolCalls(
      workspace: makeWorkspace(),
      prompt: "inspect the repository implementation",
      attachments: []
    )

    #expect(allowsTools)
  }

  @Test
  func enablesToolsForEditIntentWithoutFileKeyword() {
    let policy = ToolPromptPolicy()

    let allowsTools = policy.shouldAllowToolCalls(
      workspace: makeWorkspace(),
      prompt: "replace the h1 foo bar with a table with 3 columns",
      attachments: []
    )

    #expect(allowsTools)
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
    #expect(enabledPrompt.contains("LC_PAYLOAD_TEST"))
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
    #expect(prompt.contains("To inspect a file, use read_file."))
    #expect(prompt.contains("To find files by name, use glob_files or list_files."))
    #expect(prompt.contains("To search code contents, use search_files."))
    #expect(prompt.contains("To create a new file, use write_file"))
    #expect(prompt.contains("To modify an existing file, use read_file first"))
    #expect(prompt.contains("For targeted edits to existing files, use edit_file."))
    #expect(prompt.contains("Use write_file on an existing file only"))
    #expect(prompt.contains("Never edit existing files from memory."))
    #expect(prompt.contains("old_text must be copied exactly from current file content."))
    #expect(prompt.contains("Do not include line-number prefixes in old_text."))
    #expect(prompt.contains("old_text matches exactly once."))
    #expect(prompt.contains("If old_text is not found, read the file"))
    #expect(prompt.contains("Do not generate Python, shell, sed, awk, or helper scripts"))
  }

  @Test
  func afterToolResultCanContinuePromptIncludesEditToolInstructions() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultCanContinue,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer()
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("Use it to continue the user's request."))
    #expect(prompt.contains("If the result gives enough information to finish, answer directly."))
    #expect(prompt.contains("emit at most one edit_file"))
    #expect(prompt.contains("old_text copied exactly from that content"))
    #expect(prompt.contains("old_text was not found or was ambiguous"))
    #expect(prompt.contains("exact current text and more surrounding context"))
    #expect(prompt.contains("Emit at most one <action> block, then stop."))
    #expect(prompt.contains("Available tools:"))
    #expect(prompt.contains("edit_file"))
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
    #expect(prompt.contains("tool budget"))
    #expect(prompt.contains("Do not emit another <action> tag"))
    #expect(!prompt.contains("Available tools:"))
  }

  private func makeWorkspace() -> Workspace {
    Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project"),
      sessions: []
    )
  }
}
