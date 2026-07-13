import Foundation
import Testing

@testable import SumikaCore

struct ModelPromptProjectionTests {
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
  func frozenContentDerivesSignatureFromRoleAndContent() {
    let content = FrozenModelContent(role: .user, content: "hello")

    #expect(content.signature == FrozenModelContent.signature(role: .user, content: "hello"))
  }

  @Test
  func currentPromptContextCodablePreservesTypedFocusedFileBlocks() throws {
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
    let consumedContext = currentPromptContext.consumedContext

    // The consumed context is the persisted form (UserTurnMessage.promptContext),
    // so its typed blocks must survive a JSON round trip.
    let decoded = try JSONDecoder().decode(
      CurrentPromptContext.self,
      from: JSONEncoder().encode(consumedContext)
    )

    #expect(decoded == consumedContext)
    guard case .selected(let selection) = decoded,
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
      _ = try JSONDecoder().decode(CurrentPromptContext.self, from: data)
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
      _ = try JSONDecoder().decode(CurrentPromptContext.self, from: data)
    }
  }

  @Test
  func chatSessionEncodingDoesNotPersistModelPromptProjection() throws {
    let session = ChatSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      turns: [
        ChatTurn(
          status: .completed,
          items: [.userMessage(UserTurnMessage(content: "summarize the file"))])
      ],
      modeSettings: testModeSettings(
        systemPrompt: "Fallback prompt should not rewrite frozen history.",
        generationSettings: .agentDefault
      )
    )
    let data = try JSONEncoder().encode(session)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["modelContextSnapshot"] == nil)
    object["modelContextSnapshot"] = ["entries": []]
    let dataWithIgnoredSnapshot = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatSession.self, from: dataWithIgnoredSnapshot)
    #expect(decoded.turns == session.turns)
  }

  @Test
  func writeToolResultFollowUpDoesNotAppendSyntheticUserPrompt() throws {
    let turnID = UUID()
    let callID = UUID()
    let request = ToolCallRequest.validated(
      raw: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .writeFile
      ),
      payload: .writeFile(WriteFileInput(path: "movies.html", content: "movies.html written"))
    )
    let record = ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed in test.",
        riskLevel: .low
      ),
      state: .completed(
        .writeFile(
          .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 18)
        ))
    )
    let state = ChatSession(
      turns: [
        ChatTurn(
          id: turnID,
          status: .completed,
          items: [
            .userMessage(
              UserTurnMessage(
                content: "create movies.html",
                promptContext: .empty(.focusedFileDefault)
              )),
            .assistantMessage(AssistantTurnMessage(content: "Tool call write_file requested.")),
            .tool(record),
          ])
      ]
    )

    let projection = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)
    #expect(
      projection.entries.map(\.frozenContent.role) == [
        .user, .assistant, .tool,
      ])
    let writeEntry = try #require(
      projection.entries.first { entry in
        if case .toolObservation(let context) = entry.body {
          return context.toolName == .writeFile && context.callID == callID
        }
        return false
      })
    guard case .toolObservation(let writeContext) = writeEntry.body else {
      Issue.record("Expected the write result to remain in model context history.")
      return
    }
    #expect(writeContext.toolName == .writeFile)
    #expect(writeContext.content.contains("Summary: Wrote 18 bytes to movies.html."))

    #expect(projection.entries.count == 3)
    #expect(
      projection.entries.contains { entry in
        if case .userPrompt(let context) = entry.body {
          return context.prompt
            == "Provide a brief final response based on the preceding tool result."
        }
        return false
      } == false
    )
  }

  @Test
  func duplicateToolObservationUsesNewCallIDAndOmitsPreviousCallIDFromContent() throws {
    let previousCallID = UUID()
    let duplicateCallID = UUID()
    let previousCallIDString = RuntimeToolCallID.string(for: previousCallID)
    let entry = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: ToolResultModelMessage(
        callID: duplicateCallID,
        toolName: .readFile,
        payload: .duplicateToolCall(
          DuplicateToolCallResult(
            previousCallID: previousCallID,
            message: "Duplicate of \(previousCallIDString): identical read_file already completed.",
            affectedPaths: [WorkspaceRelativePath(rawValue: "README.md")]
          ))
      ),
      request: readFileRequest(callID: duplicateCallID),
      originalUserRequest: nil
    )

    guard case .toolObservation(let context) = entry.body else {
      Issue.record("Expected duplicate result to project as a tool observation.")
      return
    }
    #expect(context.callID == duplicateCallID)
    #expect(context.toolReceipt?.callID == duplicateCallID)
    #expect(context.content.contains(previousCallIDString) == false)
    #expect(context.content.contains("\"kind\":\"duplicate_replay\""))
    #expect(context.toolReceipt?.summary.text.contains(previousCallIDString) == true)
  }

  @Test
  func textAndToolCallProjectsSingleAssistantToolBoundary() throws {
    let turnID = UUID()
    let callID = UUID()
    let request = readFileRequest(callID: callID)
    let record = ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed in test.",
        riskLevel: .low
      ),
      state: .completed(
        .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "Project overview")
          )))
    )
    let state = ChatSession(
      turns: [
        ChatTurn(
          id: turnID,
          status: .running,
          items: [
            .userMessage(UserTurnMessage(content: "read README.md")),
            .assistantMessage(AssistantTurnMessage(content: "I'll inspect README.md.")),
            .tool(record),
          ])
      ]
    )

    let projection = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    #expect(projection.entries.map(\.frozenContent.role) == [.user, .assistant, .tool])
    #expect(projection.entries[1].frozenContent.content == "I'll inspect README.md.")
    #expect(projection.entries.count == 3)
    guard case .toolObservation(let context) = projection.entries[2].body else {
      Issue.record("Expected tool observation after assistant boundary.")
      return
    }
    #expect(context.callID == callID)
    #expect(context.toolCall?.callID == callID)
  }

  @Test
  func failedEditFileResultEntryFreezesAsToolObservation() throws {
    let turnID = UUID()
    let callID = UUID()
    let path = WorkspaceRelativePath(rawValue: "README.md")
    let entry = try ModelFacingPromptRenderer.toolResultEntry(
      turnID: turnID,
      toolResult: ToolResultModelMessage(
        callID: callID,
        toolName: .editFile,
        payload: .editFile(
          .oldTextNotFound(
            path: path,
            currentContent: ToolTextOutput(text: "project notes\n"),
            recovery: .readFile(path: path)
          ))
      ),
      request: editFileRequest(callID: callID),
      originalUserRequest: "replace missing text in README"
    )

    #expect(entry.frozenContent.role == .tool)
    guard case .toolObservation(let context) = entry.body else {
      Issue.record("Expected failed edit_file result to be a model-facing tool observation.")
      return
    }
    #expect(context.toolName == .editFile)
    #expect(context.status == .failed)
    #expect(context.content.contains("edit_file failed: old_text was not found in README.md"))
    #expect(context.content.contains("First call read_file(path: \"README.md\")"))
    #expect(entry.frozenContent.content.contains("Original user request:") == false)
    #expect(entry.frozenContent.content.contains("replace missing text in README") == false)
    #expect(entry.frozenContent.content.contains("Tool observation:") == false)
    #expect(entry.frozenContent.content.contains("Do not retry edit_file from memory"))
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
    #expect(entry.frozenContent.content.contains("TOOL_RESULT_JSON:"))
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
    let transcript = ModelPromptProjection(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "I will read it."),
      toolEntry,
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "I read README.md."),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you do?"),
    ])

    let projected = transcript.projectedEntries(mode: .compactedHistoryForLaterTurns)

    #expect(projected[2].content.contains("Tool receipt: read_file"))
    #expect(projected[2].content.contains("Very large file body"))
    #expect(projected[2].content.contains("TOOL_RESULT_JSON:") == false)
    #expect(projected[4].content.contains("what did you do?"))
  }

  @Test
  func compactedProjectionKeepsActiveSameTurnToolFollowUpFull() throws {
    let toolEntry = try readFileToolResultEntry(
      callID: UUID(),
      content: "Project overview"
    )
    let transcript = ModelPromptProjection(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "I will read it."),
      toolEntry,
    ])

    let projected = transcript.projectedEntries(mode: .compactedHistoryForLaterTurns)

    #expect(projected[2].content.contains("TOOL_RESULT_JSON:"))
    #expect(projected[2].content.contains("Project overview"))
    #expect(projected[2].content.contains("Tool receipt:") == false)
  }

  @Test
  func toolObservationEntryFreezesToolObservationOnly() throws {
    let turnID = UUID()
    let callID = UUID()
    let transcript = ModelPromptProjection(entries: [
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
    #expect(projected.last?.role == .tool)
    #expect(projected.last?.content.contains("Original user request:") == false)
    #expect(projected.last?.content.contains("Assistant tool call:") == false)
    #expect(projected.last?.content.contains("\"tool\":\"run_command\"") == true)
    #expect(projected.last?.content.contains("Tool observation:") == false)
    #expect(projected.last?.content.contains("passed") == true)
  }

  @Test
  func consecutiveToolObservationsStayAppendOnlyInProjection() throws {
    let turnID = UUID()
    let readCallID = UUID()
    let commandCallID = UUID()
    let request = "read the README and run the smoke test"
    let transcript = ModelPromptProjection(entries: [
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

    // Each observation is its own stable tool message; earlier observations are
    // never re-rendered into later prompts, so the history stays append-only
    // and a cached KV prefix remains valid across tool-loop iterations.
    #expect(projected.count == 3)
    let firstObservation = try #require(projected[1].content as String?)
    #expect(projected[1].role == .tool)
    #expect(firstObservation.contains("Original user request:") == false)
    #expect(firstObservation.contains("\"tool\":\"read_file\""))
    #expect(firstObservation.contains("Project overview"))
    let secondObservation = try #require(projected[2].content as String?)
    #expect(projected[2].role == .tool)
    #expect(secondObservation.contains("Original user request:") == false)
    #expect(secondObservation.contains("\"tool\":\"run_command\""))
    #expect(secondObservation.contains("passed"))
    #expect(secondObservation.contains("Project overview") == false)
  }

  @Test
  func toolObservationWithoutOriginalRequestFreezesBareObservation() throws {
    let callID = UUID()
    let entry = try readFileToolResultEntry(callID: callID, content: "Project overview")

    #expect(entry.frozenContent.content.contains("TOOL_RESULT_JSON:"))
    #expect(entry.frozenContent.content.contains("Project overview"))
    #expect(entry.frozenContent.content.contains("Original user request:") == false)
  }

  @Test
  func writeToolResultPreservesToolReceiptMetadata() throws {
    let callID = UUID()
    let writeEntry = try ModelFacingPromptRenderer.toolResultEntry(
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

    guard case .toolObservation(let writeContext) = writeEntry.body else {
      Issue.record("Expected write tool result context.")
      return
    }

    let receipt = try #require(writeContext.toolReceipt)
    #expect(receipt.callID == callID)
    #expect(receipt.toolName == .writeFile)
    #expect(receipt.summary.text == "Wrote 18 bytes to movies.html.")
  }

  @Test
  func userPromptEntryFreezesImageSignaturesFromImageAttachments() throws {
    let imageAttachment = ChatAttachment(
      displayName: "car.jpg",
      payload: .image(
        ImageAttachmentPayload(mimeType: "image/jpeg", byteSize: 1024, contentSHA256: "abc123")
      )
    )
    let textAttachment = ChatAttachment(
      displayName: "notes.txt",
      payload: .text(
        TextAttachmentPayload(content: "notes", byteSize: 5, contentSHA256: "def456")
      )
    )

    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "what is in the picture",
      attachments: [imageAttachment, textAttachment]
    )

    guard case .userPrompt(let context) = entry.body else {
      Issue.record("Expected user prompt context.")
      return
    }
    #expect(context.imageSignatures == ["sha256:abc123"])
    #expect(entry.frozenContent.content.contains("abc123") == false)
  }

  @Test
  func attachmentContentSignatureFallsBackToAttachmentID() {
    let attachment = ChatAttachment(
      displayName: "car.jpg",
      payload: .image(
        ImageAttachmentPayload(mimeType: "image/jpeg", byteSize: 1, contentSHA256: ""))
    )

    #expect(attachment.contentSignature == "attachment:\(attachment.id.uuidString)")
  }

  @Test
  func imageSignaturesProjectIntoFullHistory() throws {
    let imageAttachment = ChatAttachment(
      displayName: "car.jpg",
      payload: .image(
        ImageAttachmentPayload(mimeType: "image/jpeg", byteSize: 1024, contentSHA256: "abc123")
      )
    )
    let transcript = ModelPromptProjection(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "what is in the picture",
        attachments: [imageAttachment]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "A blue Mini Cooper."),
    ])

    let projected = transcript.projectedEntries(mode: .fullHistory)
    #expect(projected[0].imageSignatures == ["sha256:abc123"])
    #expect(projected[1].imageSignatures == [])
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

  private func editFileRequest(callID: UUID) -> ToolCallRequest {
    ToolCallRequest.validated(
      raw: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .editFile
      ),
      payload: .editFile(
        EditFileInput(
          path: "README.md",
          oldText: "missing text",
          newText: "replacement"
        ))
    )
  }
}
