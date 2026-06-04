import Foundation
import Testing

@testable import LocalCoderCore

struct ModelFacingTranscriptTests {
  @Test
  func entryInitRejectsRoleBodyMismatch() {
    #expect(throws: ModelContextEntryError.roleMismatch(expected: .user, actual: .assistant)) {
      try ModelContextEntry(
        body: .userPrompt(UserPromptContext(prompt: "hello")),
        frozenContent: FrozenModelContent(role: .assistant, content: "hello")
      )
    }
  }

  @Test
  func entryDecodeRejectsRoleBodyMismatch() throws {
    let entry = try ModelFacingPromptRenderer.userPromptEntry(prompt: "hello")
    let data = try JSONEncoder().encode(entry)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var frozenContent = try #require(object["frozenContent"] as? [String: Any])
    frozenContent["role"] = "assistant"
    object["frozenContent"] = frozenContent
    let mismatchData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ModelContextEntryError.roleMismatch(expected: .user, actual: .assistant)) {
      _ = try JSONDecoder().decode(ModelContextEntry.self, from: mismatchData)
    }
  }

  @Test
  func codingSessionDecodeRequiresModelFacingTranscript() throws {
    let session = CodingSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      modelFacingTranscript: ModelFacingTranscript(
        entries: [
          try ModelFacingPromptRenderer.userPromptEntry(prompt: "summarize the file")
        ]
      ),
      systemPrompt: "Fallback prompt should not rewrite frozen history.",
      generationSettings: .codingDefault
    )
    let data = try JSONEncoder().encode(session)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "modelFacingTranscript")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(CodingSession.self, from: legacyData)
    }
  }

  @Test
  func finalToolResultFollowUpReplacesTerminalAssistantLedgerEntryWithCurrentPrompt() throws {
    let turnID = UUID()
    let callID = UUID()
    let mutator = ChatTranscriptMutator()
    var state = ChatSessionState.codingDefault
    mutator.appendModelFacingEntry(
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "create movies.html",
        systemContext: ["Tools are available."]
      ),
      to: &state
    )
    mutator.appendModelFacingEntry(
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "Tool call write_file requested."
      ),
      to: &state
    )
    mutator.appendModelFacingEntry(
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 18)
          )
        ),
        request: ToolCallRequest.validated(
          raw: RawToolCallRequest(
            id: callID,
            workspaceID: UUID(),
            sessionID: UUID(),
            toolName: .writeFile
          ),
          payload: .writeFile(WriteFileInput(path: "movies.html", content: "movies.html written"))
        )
      ),
      to: &state
    )

    mutator.appendFinalToolResultFollowUpBoundary(
      "Use the preceding tool result to answer the user's request.",
      turnID: turnID,
      systemPromptSnapshot: "No more tools may run in this response.",
      to: &state
    )

    #expect(
      state.modelFacingTranscript.entries.map(\.frozenContent.role) == [
        .user, .assistant, .user,
      ])
    #expect(
      !state.modelFacingTranscript.entries.contains { entry in
        if case .terminalToolResult = entry.body {
          return true
        }
        return false
      })
    let finalEntry = try #require(state.modelFacingTranscript.entries.last)
    guard case .toolObservation(let context) = finalEntry.body else {
      Issue.record("Expected the terminal result to become the current tool observation prompt.")
      return
    }
    #expect(context.toolName == .writeFile)
    #expect(
      finalEntry.frozenContent.content.contains("Summary: Wrote 18 bytes to movies.html."))
    #expect(
      finalEntry.frozenContent.content.contains(
        "Use the preceding tool result to answer the user's request."))
    #expect(finalEntry.frozenContent.content.contains("No more tools may run in this response."))
  }
}
