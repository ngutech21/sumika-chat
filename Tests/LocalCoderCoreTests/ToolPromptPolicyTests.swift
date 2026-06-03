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
  func afterToolResultCanContinuePromptIncludesEditToolInstructions() {
    let policy = ToolPromptPolicy()

    let prompt = policy.systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultCanContinue,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry,
      toolPromptRenderer: TaggedToolPromptRenderer()
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("emit one edit_file"))
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
