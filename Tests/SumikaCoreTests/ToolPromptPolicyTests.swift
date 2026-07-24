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
  func nativeAgentPromptKeepsCompactWorkflowRules() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(prompt.contains("Base"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("edit_file"))
    #expect(prompt.contains("finish_task"))
    #expect(prompt.contains("call it exactly once and alone"))
    #expect(prompt.contains("complete user-visible final response in summary"))
    #expect(prompt.contains("After a successful edit/write, inspect or verify as needed"))
    #expect(prompt.contains("Never print tool-call XML, JSON"))
    #expect(prompt.contains("native tool calls"))
    #expect(!prompt.contains("Available tools:"))
  }

  @Test
  func nativeAgentPromptHonorsSingleNativeToolCallPolicy() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .enabled(true),
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry,
      toolCallingPolicy: ToolCallingPolicy(isEnabled: true, allowsMultipleToolCalls: false)
    )

    #expect(prompt.contains("Emit at most one native tool call"))
    #expect(!prompt.contains("You may emit multiple native tool calls"))
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
  func mutationContinuationDoesNotRequireUnavailableFinishTask() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultCanContinue,
      toolRegistry: ToolRegistry(tools: [.readFile, .writeFile])
    )

    #expect(prompt.contains("After a successful edit/write, inspect or verify as needed"))
    #expect(prompt.contains("provide the final answer directly"))
    #expect(!prompt.contains("call finish_task"))
  }

  @Test
  func nativeChatWebPromptMentionsOnlyWebToolsAndPrivacyBoundary() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .chatWeb,
      toolRegistry: ToolExecutorRegistry.chatWeb.toolRegistry
    )

    #expect(prompt.contains("Public web tools"))
    #expect(prompt.contains("web_search"))
    #expect(prompt.contains("web_fetch"))
    #expect(prompt.contains("Never send private code"))
    #expect(prompt.contains("untrusted reference material"))
    #expect(prompt.contains("Never print tool-call XML, JSON envelopes"))
    #expect(!prompt.contains("edit_file"))
    #expect(!prompt.contains("run_command"))
    #expect(!prompt.contains("finish_task"))
    #expect(!prompt.contains("Inspect before editing"))
  }

  @Test
  func finalToolResultPromptKeepsStableAgentInstructions() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultFinal,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(prompt.contains("Use available workspace tools"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("edit_file"))
    #expect(!prompt.contains("No more tools may run"))
    #expect(!prompt.contains("Do not call another tool"))
    #expect(!prompt.contains("Do not include generated file contents"))
    #expect(
      prompt.contains("Never claim a change without a successful result"))
    #expect(
      prompt.contains("a failed or invalid result means no change"))
  }

  @Test
  func chatWebFinalPromptKeepsChatWebInstructionsNotAgentRules() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .afterChatWebToolResultFinal,
      toolRegistry: ToolExecutorRegistry.chatWeb.toolRegistry
    )

    #expect(prompt.contains("Public web tools"))
    #expect(prompt.contains("web_search"))
    #expect(!prompt.contains("Workspace tools are available"))
    #expect(!prompt.contains("edit_file"))
    #expect(!prompt.contains("run_command"))
  }

  @Test
  func isFinalAndFinalModeCoverBothProfiles() {
    #expect(ToolPromptMode.afterToolResultFinal.isFinal)
    #expect(ToolPromptMode.afterChatWebToolResultFinal.isFinal)
    #expect(!ToolPromptMode.afterToolResultCanContinue.isFinal)
    #expect(!ToolPromptMode.afterToolBudgetExhausted.isFinal)
    #expect(!ToolPromptMode.afterChatWebToolResultCanContinue.isFinal)
    #expect(!ToolPromptMode.chatWeb.isFinal)

    #expect(ToolPromptMode.finalMode(for: .agent) == .afterToolResultFinal)
    #expect(ToolPromptMode.finalMode(for: .chatWeb) == .afterChatWebToolResultFinal)
    #expect(ToolPromptMode.finalMode(for: .disabled) == .disabled)
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
    #expect(
      enabledPrompt.contains("Never claim a change without a successful result"))
    #expect(
      enabledPrompt.contains("a failed or invalid result means no change"))
    #expect(!disabledPrompt.contains("Available tools:"))
    #expect(!disabledPrompt.contains("todo_write"))
    #expect(!disabledPrompt.contains("planned todo"))
  }
}

struct ToolFollowUpPromptPolicyTests {
  @Test
  func ordinaryToolResultsIncludingMutationsContinuePerProfile() {
    #expect(
      ToolFollowUpPromptPolicy.promptMode(for: .agent) == .afterToolResultCanContinue)
    #expect(
      ToolFollowUpPromptPolicy.promptMode(for: .chatWeb)
        == .afterChatWebToolResultCanContinue)
    #expect(
      ToolFollowUpPromptPolicy.promptMode(
        for: .agent,
        default: .disabled
      ) == .disabled)
  }

  @Test
  func everyTypedForceFinalReasonUsesProfileAppropriateFinalMode() {
    let reasons: [ToolFollowUpFinalReason] = [
      .denial,
      .blockedDuplicate,
      .repeatedRunCommandFailure,
      .toolBatchBudgetExhausted,
    ]

    for reason in reasons {
      #expect(
        ToolFollowUpPromptPolicy.promptMode(
          for: .agent,
          finalReason: reason
        ) == .afterToolResultFinal)
      #expect(
        ToolFollowUpPromptPolicy.promptMode(
          for: .chatWeb,
          finalReason: reason
        ) == .afterChatWebToolResultFinal)
    }
  }
}
