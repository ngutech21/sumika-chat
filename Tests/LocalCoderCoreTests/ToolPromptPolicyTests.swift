import Foundation
import Testing

@testable import LocalCoderCore

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
  func nativeAgentPromptMentionsAvailableToolsWithoutXmlProtocol() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("edit_file"))
    #expect(prompt.contains("native tool calls"))
    #expect(!prompt.contains("<action"))
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
    #expect(!prompt.contains("<action"))
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
    #expect(!prompt.contains("<action"))
  }
}
