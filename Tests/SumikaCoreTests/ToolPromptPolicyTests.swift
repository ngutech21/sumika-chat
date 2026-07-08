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
    #expect(!prompt.contains("edit_file"))
    #expect(!prompt.contains("run_command"))
    #expect(!prompt.contains("Inspect before editing"))
  }

  @Test
  func finalToolResultPromptKeepsStableAgentInstructions() {
    let prompt = ToolPromptPolicy().systemPrompt(
      basePrompt: "Base",
      mode: .afterToolResultFinal,
      toolRegistry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(prompt.contains("Workspace tools are available"))
    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("edit_file"))
    #expect(!prompt.contains("No more tools may run"))
    #expect(!prompt.contains("Do not call another tool"))
    #expect(!prompt.contains("Do not include generated file contents"))
    #expect(
      prompt.contains(
        "Never say files were changed unless a successful write_file or edit_file result exists in this turn."
      ))
    #expect(
      prompt.contains(
        "Failed or invalid write/edit tool results mean no workspace change happened."
      ))
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
      enabledPrompt.contains(
        "Never say files were changed unless a successful write_file or edit_file result exists in this turn."
      ))
    #expect(
      enabledPrompt.contains(
        "Failed or invalid write/edit tool results mean no workspace change happened."
      ))
    #expect(disabledPrompt.contains("Available tools:"))
    #expect(!disabledPrompt.contains("todo_write"))
    #expect(!disabledPrompt.contains("planned todo"))
  }
}

struct TerminalToolResultPolicyTests {
  @Test
  func onlySuccessfulWriteAndEditResultsAreTerminal() {
    #expect(
      TerminalToolResultPolicy.isTerminalWriteResult(toolName: .writeFile, resultStatus: .success))
    #expect(
      TerminalToolResultPolicy.isTerminalWriteResult(toolName: .editFile, resultStatus: .success))
    #expect(
      !TerminalToolResultPolicy.isTerminalWriteResult(toolName: .writeFile, resultStatus: .failed))
    #expect(
      !TerminalToolResultPolicy.isTerminalWriteResult(toolName: .readFile, resultStatus: .success))
  }

  @Test
  func followUpModeAfterTerminalWriteHonorsToolProfile() {
    let record = completedWriteRecord()

    #expect(TerminalToolResultPolicy.isTerminalWriteResult(record))
    #expect(
      TerminalToolResultPolicy.followUpPromptMode(after: record, toolProfile: .agent)
        == .afterToolResultFinal)
    #expect(
      TerminalToolResultPolicy.followUpPromptMode(after: record, toolProfile: .chatWeb)
        == .afterChatWebToolResultFinal)
  }

  @Test
  func followUpModeAfterNonTerminalResultContinuesPerProfile() {
    let record = completedReadRecord()

    #expect(!TerminalToolResultPolicy.isTerminalWriteResult(record))
    #expect(
      TerminalToolResultPolicy.followUpPromptMode(after: record, toolProfile: .agent)
        == .afterToolResultCanContinue)
    #expect(
      TerminalToolResultPolicy.followUpPromptMode(after: record, toolProfile: .chatWeb)
        == .afterChatWebToolResultCanContinue)
    #expect(
      TerminalToolResultPolicy.followUpPromptMode(
        after: record,
        toolProfile: .agent,
        default: .disabled
      ) == .disabled)
  }

  @Test
  func forceFinalOverridesNonTerminalResult() {
    let record = completedReadRecord()

    #expect(
      TerminalToolResultPolicy.followUpPromptMode(
        after: record,
        toolProfile: .agent,
        forceFinal: true
      ) == .afterToolResultFinal)
  }

  private func completedWriteRecord() -> ToolCallRecord {
    let path = WorkspaceRelativePath(rawValue: "index.html")
    return makePolicyRecord(
      toolName: .writeFile,
      payload: .writeFile(WriteFileInput(path: path.rawValue, content: "<h1>Hello</h1>")),
      state: .completed(.writeFile(.success(path: path, bytesWritten: 14)))
    )
  }

  private func completedReadRecord() -> ToolCallRecord {
    let path = WorkspaceRelativePath(rawValue: "README.md")
    return makePolicyRecord(
      toolName: .readFile,
      payload: .readFile(ReadFileInput(path: path.rawValue)),
      state: .completed(.readFile(.success(path: path, content: ToolTextOutput(text: "Notes"))))
    )
  }

  private func makePolicyRecord(
    toolName: ToolName,
    payload: ToolCallPayload,
    state: ToolCallState
  ) -> ToolCallRecord {
    ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          workspaceID: UUID(),
          sessionID: UUID(),
          toolName: toolName
        ),
        payload: payload
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .low
      ),
      state: state
    )
  }
}
