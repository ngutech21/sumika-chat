import Foundation
import Testing

@testable import SumikaCore

struct ToolPromptPolicyTests {
  @Test
  func disabledModeReturnsBasePrompt() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .disabled,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(prompt == "Base")
  }

  @Test
  func nativeAgentPromptMentionsAvailableTools() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("edit_file"))
    #expect(prompt.contains("native tool calls"))
  }

  @Test
  func nativeAgentPromptOmitsTodoInstructionsWhenTodoWriteUnavailable() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false).toolRegistry
    )

    #expect(!prompt.contains("todo_write"))
    #expect(!prompt.contains("planned todo"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("edit_file"))
  }

  @Test
  func nativeInspectPromptRestrictsWrites() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .inspect,
      toolRegistry: ToolExecutorRegistry.readOnly.toolRegistry
    )

    #expect(prompt.contains("Read-only workspace tools"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("Never call write_file or edit_file"))
  }

  @Test
  func finalToolResultPromptDisablesFurtherToolCalls() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultFinal,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(prompt.contains("No more tools may run"))
    #expect(prompt.contains("Do not call another tool"))
  }

  @Test
  func followUpPromptMentionsTodoOnlyWhenTodoWriteAvailable() {
    let enabledPrompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultCanContinue,
      toolRegistry: ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: true).toolRegistry
    )
    let disabledPrompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultCanContinue,
      toolRegistry: ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false).toolRegistry
    )

    #expect(enabledPrompt.contains("todo_write"))
    #expect(disabledPrompt.contains("Available tools:"))
    #expect(!disabledPrompt.contains("todo_write"))
    #expect(!disabledPrompt.contains("planned todo"))
  }
}
