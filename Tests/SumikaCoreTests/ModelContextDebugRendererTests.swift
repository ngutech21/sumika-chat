import Foundation
import Testing

@testable import SumikaCore

struct ModelContextDebugRendererTests {
  @Test
  func renderIncludesSystemPromptAndRuntimeProjectedEntriesInOrder() throws {
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "Inspect README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "I will inspect it."),
    ])

    let document = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "Use concise answers."
    )

    #expect(document.systemPrompt.role == .system)
    #expect(document.systemPrompt.content == "Use concise answers.")
    #expect(document.entries.map(\.role) == [.user, .assistant])
    #expect(
      document.entries.map(\.content) == [
        "Inspect README.md",
        "I will inspect it.",
      ])
    #expect(document.renderedContext.contains("=== system ==="))
    #expect(document.renderedContext.contains("=== 1. user ==="))
    #expect(document.renderedContext.contains("=== 2. assistant ==="))
  }

  @Test
  func renderShowsToolResultsAsToolEntries() throws {
    let turnID = UUID()
    let callID = UUID()
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "run the smoke test"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .runCommand,
          payload: .runCommand(
            RunCommandResult(
              command: "just smoke",
              timeoutSeconds: 10,
              exitCode: 0,
              durationMs: 12,
              stdout: ToolTextOutput(text: "passed"),
              stderr: ToolTextOutput(text: "")
            ))
        ),
        request: runCommandRequest(callID: callID),
        originalUserRequest: "run the smoke test"
      ),
    ])

    let document = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "Tools are available."
    )

    #expect(document.entries.count == 2)
    #expect(document.entries.map(\.role) == [.user, .tool])
    let content = try #require(document.entries.last?.content)
    #expect(content.contains("Original user request:") == false)
    #expect(content.contains("<observation"))
    #expect(content.contains("passed"))
  }

  @Test
  func renderComputesCountsAndTokenEstimates() throws {
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "12345"),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "abcdefghi"),
    ])

    let document = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "abcd"
    )

    #expect(document.systemPrompt.characterCount == 4)
    #expect(document.systemPrompt.estimatedTokens == 1)
    #expect(document.entries[0].characterCount == 5)
    #expect(document.entries[0].estimatedTokens == 2)
    #expect(document.entries[1].characterCount == 9)
    #expect(document.entries[1].estimatedTokens == 3)
    #expect(document.totalCharacters == 18)
    #expect(document.totalEstimatedTokens == 6)
  }

  @Test
  func signatureIsStableAndChangesWhenModelFacingContentChanges() throws {
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "hello")
    ])

    let first = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "System"
    )
    let second = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "System"
    )
    let changedPrompt = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "Different system"
    )
    let changedEntry = try ModelContextDebugRenderer.render(
      transcript: ModelContextSnapshot(entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "goodbye")
      ]),
      systemPrompt: "System"
    )

    #expect(first.signature == second.signature)
    #expect(first.signature != changedPrompt.signature)
    #expect(first.signature != changedEntry.signature)
  }

  @Test
  func entryIDsAreStableAcrossRenders() throws {
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "hello"),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "hi"),
    ])

    let first = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "System"
    )
    let second = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "System"
    )

    #expect(first.systemPrompt.id == "system")
    #expect(first.entries.map(\.id) == ["1-user", "2-assistant"])
    #expect(first.entries.map(\.id) == second.entries.map(\.id))
  }

  @Test
  func renderDoesNotMutateSourceSnapshot() throws {
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "hello")
    ])
    let before = transcript

    _ = try ModelContextDebugRenderer.render(
      transcript: transcript,
      systemPrompt: "System"
    )

    #expect(transcript == before)
  }

  private func runCommandRequest(callID: UUID) -> ToolCallRequest {
    ToolCallRequest.validated(
      raw: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .runCommand,
        arguments: ["command": .string("just smoke")]
      ),
      payload: .runCommand(RunCommandInput(command: "just smoke", timeoutSeconds: 10))
    )
  }
}
