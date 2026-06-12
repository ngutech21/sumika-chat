import Foundation
import Testing

@testable import LocalCoderCore

struct ModelContextSnapshotTests {
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
    frozenContent["signature"] = FrozenModelContent.signature(role: .assistant, content: "hello")
    object["frozenContent"] = frozenContent
    let mismatchData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ModelContextEntryError.roleMismatch(expected: .user, actual: .assistant)) {
      _ = try JSONDecoder().decode(ModelContextEntry.self, from: mismatchData)
    }
  }

  @Test
  func frozenContentDerivesSignatureFromRoleAndContent() {
    let content = FrozenModelContent(role: .user, content: "hello")

    #expect(content.signature == FrozenModelContent.signature(role: .user, content: "hello"))
  }

  @Test
  func frozenContentDecodeRejectsForgedSignature() throws {
    let content = FrozenModelContent(role: .user, content: "hello")
    let data = try JSONEncoder().encode(content)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["signature"] = "forged"
    let forgedData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(FrozenModelContent.self, from: forgedData)
    }
  }

  @Test
  func frozenContentCodableRoundTripsDerivedSignature() throws {
    let content = FrozenModelContent(role: .assistant, content: "done")

    let decoded = try JSONDecoder().decode(
      FrozenModelContent.self,
      from: JSONEncoder().encode(content)
    )

    #expect(decoded == content)
    #expect(decoded.signature == FrozenModelContent.signature(role: .assistant, content: "done"))
  }

  @Test
  func userPromptContextCodablePreservesTypedCurrentPromptContext() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/Foo.swift")
    let focusedState = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "let value = 1",
          fullContentAvailable: true
        )
      ]
    )
    let currentPromptContext = ChatModelContextBuilder().currentPromptContext(
      userInput: "explain",
      mode: .agent,
      focusedFileState: focusedState
    )
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "explain",
      systemContext: currentPromptContext.renderedBlocks,
      currentPromptContext: currentPromptContext.consumedContext
    )

    let decoded = try JSONDecoder().decode(
      ModelContextEntry.self,
      from: JSONEncoder().encode(entry)
    )

    #expect(decoded == entry)
    guard case .userPrompt(let context) = decoded.body,
      case .selected(let selection) = context.currentPromptContext,
      case .focusedFile(let focusedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected decoded typed focused file context.")
      return
    }
    #expect(focusedFile.path == path)
    #expect(focusedFile.source == .readFile)
    #expect(focusedFile.contentHash == "hash")
    #expect(focusedFile.excerpt?.text == "let value = 1")
  }

  @Test
  func frozenContentSignatureIgnoresTypedCurrentPromptContextMetadata() throws {
    let typedContext = CurrentPromptContextRenderer.renderedContext(.empty(.focusedFileDefault))
      .consumedContext
    let plainEntry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "hello",
      systemContext: ["System"]
    )
    let typedEntry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "hello",
      systemContext: ["System"],
      currentPromptContext: typedContext
    )

    #expect(typedEntry.frozenContent.content == plainEntry.frozenContent.content)
    #expect(typedEntry.frozenContent.signature == plainEntry.frozenContent.signature)
  }

  @Test
  func consumedSelectedContextDecodeRejectsEmptyBlocks() throws {
    let data = Data(
      """
      {
        "kind": "selected",
        "selected": {
          "blocks": [],
          "budget": 4000,
          "truncation": "none"
        }
      }
      """.utf8)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(ConsumedCurrentPromptContext.self, from: data)
    }
  }

  @Test
  func consumedAmbiguousRecentFilesDecodeRejectsEmptyPaths() throws {
    let data = Data(
      """
      {
        "kind": "selected",
        "selected": {
          "blocks": [
            {
              "kind": "ambiguousRecentFiles",
              "ambiguousRecentFiles": {
                "paths": []
              }
            }
          ],
          "budget": 4000,
          "truncation": "none"
        }
      }
      """.utf8)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(ConsumedCurrentPromptContext.self, from: data)
    }
  }

  @Test
  func chatSessionDecodeRequiresModelContextSnapshot() throws {
    let session = ChatSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      modelContextSnapshot: ModelContextSnapshot(
        entries: [
          try ModelFacingPromptRenderer.userPromptEntry(prompt: "summarize the file")
        ]
      ),
      systemPrompt: "Fallback prompt should not rewrite frozen history.",
      generationSettings: .codingDefault
    )
    let data = try JSONEncoder().encode(session)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "modelContextSnapshot")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(ChatSession.self, from: legacyData)
    }
  }

  @Test
  func finalToolResultFollowUpReplacesTerminalAssistantLedgerEntryWithCurrentPrompt() throws {
    let turnID = UUID()
    let callID = UUID()
    let mutator = ChatTranscriptMutator()
    var state = ChatSession.codingDefault
    mutator.appendModelContextEntry(
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "create movies.html",
        systemContext: ["Tools are available."]
      ),
      to: &state
    )
    mutator.appendModelContextEntry(
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "Tool call write_file requested."
      ),
      to: &state
    )
    mutator.appendModelContextEntry(
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
        ),
        originalUserRequest: nil
      ),
      to: &state
    )

    mutator.appendFinalToolResultFollowUpBoundary(
      "Use the preceding tool result to answer the user's request.",
      turnID: turnID,
      to: &state
    )

    #expect(
      state.modelContextSnapshot.entries.map(\.frozenContent.role) == [
        .user, .assistant, .user,
      ])
    #expect(
      !state.modelContextSnapshot.entries.contains { entry in
        if case .terminalToolResult = entry.body {
          return true
        }
        return false
      })
    let finalEntry = try #require(state.modelContextSnapshot.entries.last)
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
    #expect(!finalEntry.frozenContent.content.contains("No more tools may run in this response."))
  }

  @Test
  func toolResultEntryStoresTypedToolReceiptMetadata() throws {
    let callID = UUID()
    let entry = try readFileToolResultEntry(
      callID: callID,
      content: "Project overview",
      truncated: true,
      redacted: true
    )

    guard case .toolObservation(let context) = entry.body else {
      Issue.record("Expected tool observation context.")
      return
    }
    let receipt = try #require(context.toolReceipt)
    #expect(receipt.callID == callID)
    #expect(receipt.toolName == .readFile)
    #expect(receipt.status == .success)
    #expect(receipt.affectedPaths == [WorkspaceRelativePath(rawValue: "README.md")])
    #expect(receipt.summary.text == "Project overview")
    #expect(receipt.outputTruncated)
    #expect(receipt.outputRedacted)
    #expect(entry.frozenContent.content.contains("<observation"))
  }

  @Test
  func toolReceiptSummaryIsDeterministicallyTruncated() throws {
    let longContent = String(repeating: "a", count: 700)
    let entry = try readFileToolResultEntry(callID: UUID(), content: longContent)

    guard case .toolObservation(let context) = entry.body else {
      Issue.record("Expected tool observation context.")
      return
    }
    let receipt = try #require(context.toolReceipt)
    #expect(receipt.summary.text == String(longContent.prefix(600)))
    #expect(receipt.summary.truncated)
    #expect(receipt.outputTruncated)
  }

  @Test
  func compactedProjectionRendersPreviousTurnToolObservationAsReceipt() throws {
    let toolEntry = try readFileToolResultEntry(
      callID: UUID(),
      content: "Very large file body that should not remain in later history."
    )
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "I will read it."),
      toolEntry,
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "I read README.md."),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you do?"),
    ])

    let projected = transcript.projectedEntries(mode: .compactedHistoryForLaterTurns)

    #expect(projected[2].content.contains("Tool receipt: read_file"))
    #expect(projected[2].content.contains("Very large file body"))
    #expect(projected[2].content.contains("<observation") == false)
    #expect(projected[4].content.contains("what did you do?"))
  }

  @Test
  func compactedProjectionKeepsActiveSameTurnToolFollowUpFull() throws {
    let toolEntry = try readFileToolResultEntry(
      callID: UUID(),
      content: "Project overview"
    )
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "I will read it."),
      toolEntry,
    ])

    let projected = transcript.projectedEntries(mode: .compactedHistoryForLaterTurns)

    #expect(projected[2].content.contains("<observation"))
    #expect(projected[2].content.contains("Project overview"))
    #expect(projected[2].content.contains("Tool receipt:") == false)
  }

  @Test
  func toolObservationEntryFreezesSameTurnFollowUpPrompt() throws {
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

    let projected = transcript.projectedEntries(mode: .fullHistory)

    #expect(projected.count == 2)
    #expect(projected.last?.content.contains("Original user request:") == true)
    #expect(projected.last?.content.contains("run the smoke test") == true)
    #expect(projected.last?.content.contains("Assistant tool call:") == true)
    #expect(projected.last?.content.contains("tool=\"run_command\"") == true)
    #expect(projected.last?.content.contains("Tool observation:") == true)
    #expect(projected.last?.content.contains("passed") == true)
  }

  @Test
  func consecutiveToolObservationsStayAppendOnlyInProjection() throws {
    let turnID = UUID()
    let readCallID = UUID()
    let commandCallID = UUID()
    let request = "read the README and run the smoke test"
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: request
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: readFileRequest(callID: readCallID),
        originalUserRequest: request
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: commandCallID,
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
        request: runCommandRequest(callID: commandCallID),
        originalUserRequest: request
      ),
    ])

    let projected = transcript.projectedEntries(mode: .fullHistory)

    // Each observation is its own stable message; earlier observations are
    // never re-rendered into later prompts, so the history stays append-only
    // and a cached KV prefix remains valid across tool-loop iterations.
    #expect(projected.count == 3)
    let firstObservation = try #require(projected[1].content as String?)
    #expect(firstObservation.contains("Original user request:"))
    #expect(firstObservation.contains("tool=\"read_file\""))
    #expect(firstObservation.contains("Project overview"))
    let secondObservation = try #require(projected[2].content as String?)
    #expect(secondObservation.contains("Original user request:"))
    #expect(secondObservation.contains("tool=\"run_command\""))
    #expect(secondObservation.contains("passed"))
    #expect(secondObservation.contains("Project overview") == false)
  }

  @Test
  func toolObservationWithoutOriginalRequestFreezesBareObservation() throws {
    let callID = UUID()
    let entry = try readFileToolResultEntry(callID: callID, content: "Project overview")

    #expect(entry.frozenContent.content.contains("<observation"))
    #expect(entry.frozenContent.content.contains("Project overview"))
    #expect(entry.frozenContent.content.contains("Original user request:") == false)
  }

  @Test
  func finalToolResultFollowUpPreservesToolReceiptMetadata() throws {
    let callID = UUID()
    let terminalEntry = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: ToolResultModelMessage(
        callID: callID,
        toolName: .writeFile,
        payload: .writeFile(
          .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 18)
        )
      ),
      request: writeFileRequest(callID: callID),
      originalUserRequest: nil
    )

    guard case .terminalToolResult(let terminalContext) = terminalEntry.body else {
      Issue.record("Expected terminal tool result context.")
      return
    }

    let followUpEntry = try ModelFacingPromptRenderer.finalToolResultPromptEntry(
      terminalToolResult: terminalContext,
      followUpInstruction: "Use the preceding tool result to answer the user's request.",
      originalUserRequest: nil
    )

    guard case .toolObservation(let context) = followUpEntry.body else {
      Issue.record("Expected tool observation context.")
      return
    }
    let receipt = try #require(context.toolReceipt)
    #expect(receipt.callID == callID)
    #expect(receipt.toolName == .writeFile)
    #expect(receipt.summary.text == "Wrote 18 bytes to movies.html.")
  }

  @Test
  func toolReceiptMetadataCodableRoundTripsInTranscript() throws {
    let entry = try readFileToolResultEntry(callID: UUID(), content: "Project overview")
    let transcript = ModelContextSnapshot(entries: [entry])

    let decoded = try JSONDecoder().decode(
      ModelContextSnapshot.self,
      from: JSONEncoder().encode(transcript)
    )

    #expect(decoded == transcript)
    guard case .toolObservation(let context) = decoded.entries[0].body else {
      Issue.record("Expected decoded tool observation context.")
      return
    }
    #expect(context.toolReceipt?.summary.text == "Project overview")
  }

  private func readFileToolResultEntry(
    callID: UUID,
    content: String,
    truncated: Bool = false,
    redacted: Bool = false,
    originalUserRequest: String? = nil
  ) throws -> ModelContextEntry {
    try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: ToolResultModelMessage(
        callID: callID,
        toolName: .readFile,
        payload: .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: content, truncated: truncated, redacted: redacted)
          ))
      ),
      request: readFileRequest(callID: callID),
      originalUserRequest: originalUserRequest
    )
  }

  private func readFileRequest(callID: UUID) -> ToolCallRequest {
    ToolCallRequest.validated(
      raw: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .readFile
      ),
      payload: .readFile(ReadFileInput(path: "README.md"))
    )
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

  private func writeFileRequest(callID: UUID) -> ToolCallRequest {
    ToolCallRequest.validated(
      raw: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .writeFile
      ),
      payload: .writeFile(WriteFileInput(path: "movies.html", content: "<html></html>"))
    )
  }
}
