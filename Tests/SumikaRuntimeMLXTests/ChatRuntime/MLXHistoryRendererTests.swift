import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MLXLMCommon
import Testing
import UniformTypeIdentifiers

@testable import SumikaCore
@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif

extension MLXGenerationInput {
  fileprivate var promptMessages: [Chat.Message] {
    MLXHistoryRenderer.chatMessages(
      from: promptSnapshot,
      images: images,
      supportsHistoricalReasoningPreservation: supportsHistoricalReasoningPreservation
    )
  }
}

@Suite(TemporaryDirectoryTrait(named: "sumika-mlx-history-tests"))
struct MLXHistoryRendererTests {
  @Test(arguments: EXIFOrientationExpectation.allCases)
  func imageInputsNormalizeEXIFOrientation(_ expectation: EXIFOrientationExpectation) throws {
    let fixture = try storedImageFixture(exifOrientation: expectation.rawValue)
    let storedDataBeforeProjection = try Data(contentsOf: fixture.storedURL)
    let storedHashBeforeProjection = ChatAttachmentStore.contentSHA256(
      for: storedDataBeforeProjection
    )

    let images = try MLXHistoryRenderer.imageInputs(
      from: [fixture.attachment],
      attachmentStore: fixture.store
    )

    let input = try #require(images.first)
    let modelImage = try input.asCIImage()
    let previewImage = try previewImage(from: fixture.storedURL)
    let isCIImage: Bool = if case .ciImage = input { true } else { false }
    let storedDataAfterProjection = try Data(contentsOf: fixture.storedURL)
    let storedHashAfterProjection = ChatAttachmentStore.contentSHA256(
      for: storedDataAfterProjection
    )

    #expect(images.count == 1)
    #expect(isCIImage)
    #expect(modelImage.extent.integral.size == expectation.size)
    #expect(modelImage.extent.integral == previewImage.extent.integral)
    #expect(markerSignature(of: modelImage) == expectation.markerSignature)
    #expect(markerSignature(of: modelImage) == markerSignature(of: previewImage))
    #expect(storedDataAfterProjection == storedDataBeforeProjection)
    #expect(storedHashBeforeProjection == fixture.attachment.contentSHA256)
    #expect(storedHashAfterProjection == storedHashBeforeProjection)
  }

  @Test
  func imageInputsRejectUndecodableStoredImage() throws {
    let fixture = try storedImageFixture(
      data: Data("not an image".utf8),
      displayName: "broken.jpg"
    )

    do {
      _ = try MLXHistoryRenderer.imageInputs(
        from: [fixture.attachment],
        attachmentStore: fixture.store
      )
      Issue.record("Expected unreadable image attachment error.")
    } catch MLXChatRuntimeError.unreadableImageAttachment(let name) {
      #expect(name == "broken.jpg")
      #expect(
        MLXChatRuntimeError.unreadableImageAttachment(name).errorDescription
          == "broken.jpg could not be decoded as an image."
      )
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func imageInputsRejectChangedStoredImageBeforeDecode() throws {
    let fixture = try storedImageFixture(exifOrientation: 1)
    try Data("changed after attachment".utf8).write(to: fixture.storedURL)

    do {
      _ = try MLXHistoryRenderer.imageInputs(
        from: [fixture.attachment],
        attachmentStore: fixture.store
      )
      Issue.record("Expected changed stored attachment error.")
    } catch ChatAttachmentError.changedStoredAttachment(let name) {
      #expect(name == fixture.attachment.displayName)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func generationHistorySnapshotCarriesImageSignaturesFromUserPromptEntry() throws {
    let imageAttachment = ChatAttachment(
      displayName: "car.jpg",
      payload: .image(
        ImageAttachmentPayload(mimeType: "image/jpeg", byteSize: 1024, contentSHA256: "abc123")
      )
    )
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "what is in the picture",
        attachments: [imageAttachment]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "A blue Mini Cooper."),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what color are the wheels?"),
    ]

    let snapshot = try MLXHistoryRenderer.generationInput(
      from: ModelPromptProjection(entries: entries)
    ).historySnapshot

    #expect(snapshot.count == 2)
    #expect(snapshot[0].imageSignatures == ["sha256:abc123"])
    #expect(snapshot[1].imageSignatures == [])
    #expect(snapshot[0].content.contains("abc123") == false)
  }

  @Test
  func mlxGenerationInputConsumesCoreProviderProjectionWithoutDrift() throws {
    let callID = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000041")
    )
    let arguments: ToolCallArguments = ["path": .string("README.md")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: arguments
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            )
          )
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: arguments
        ),
        originalUserRequest: nil
      ),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "summarize it"),
    ]
    let transcript = ModelPromptProjection(entries: entries)
    let coreSegments = try #require(
      ProviderPromptProjection.generationSegments(from: transcript)
    )

    let input = try MLXHistoryRenderer.generationInput(from: transcript)

    #expect(input.historySnapshot == coreSegments.history.messages)
    #expect(input.promptSnapshot == coreSegments.prompt.messages)
    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.promptMessages.map(\.role) == [.tool, .user])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawFunction = try #require(
      rawToolCalls.first?["function"] as? [String: any Sendable]
    )
    #expect(rawFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(
      rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID)
    )
  }

  @Test
  func qwenCapabilityEncodesHistoricalReasoningOnlyAtMLXAdapterBoundary() throws {
    let transcript = ModelPromptProjection(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "Solve it"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: "The result is 42.",
        historicalReasoning: HistoricalAssistantReasoning(
          content: "I should calculate carefully."
        )
      ),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "Explain it"),
    ])

    let supported = try MLXHistoryRenderer.generationInput(
      from: transcript,
      reasoningEnabled: false,
      supportsHistoricalReasoningPreservation: true
    )
    let unsupported = try MLXHistoryRenderer.generationInput(
      from: transcript,
      reasoningEnabled: false,
      supportsHistoricalReasoningPreservation: false
    )

    #expect(
      supported.history[1].content
        == "<think>\nI should calculate carefully.\n</think>\n\nThe result is 42.")
    #expect(supported.historySnapshot[1].content == "The result is 42.")
    #expect(supported.historySnapshot[1].reasoningContent == "I should calculate carefully.")
    #expect(supported.additionalContext["enable_thinking"] as? Bool == false)
    #expect(supported.additionalContext["preserve_thinking"] as? Bool == true)
    #expect(unsupported.history[1].content == "The result is 42.")
    #expect(unsupported.additionalContext["preserve_thinking"] == nil)

    let toolBoundary = MLXHistoryRenderer.chatMessages(
      from: [
        ProviderPromptMessage(
          role: Chat.Message.Role.assistant.rawValue,
          content: "I will inspect it.",
          reasoningContent: "The file is relevant.",
          toolCalls: [
            ProviderToolCall(
              id: "call-1",
              name: ToolName.readFile.rawValue,
              arguments: ["path": .string("README.md")]
            )
          ]
        )
      ],
      supportsHistoricalReasoningPreservation: true
    )
    let rawToolBoundary = DefaultMessageGenerator().generate(messages: toolBoundary)
    let rawToolCalls = try #require(
      rawToolBoundary.first?["tool_calls"] as? [[String: any Sendable]]
    )
    let rawFunction = try #require(
      rawToolCalls.first?["function"] as? [String: any Sendable]
    )
    #expect(rawFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(
      toolBoundary.first?.content
        == "<think>\nThe file is relevant.\n</think>\n\nI will inspect it.")
  }

  @Test
  func qwenReasoningEffortIsSuppliedOnlyWhileReasoningIsEnabled() throws {
    let transcript = ModelPromptProjection(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "Solve it")
    ])

    let medium = try MLXHistoryRenderer.generationInput(
      from: transcript,
      reasoningEnabled: true,
      reasoningEffort: .medium
    )
    let disabled = try MLXHistoryRenderer.generationInput(
      from: transcript,
      reasoningEnabled: false,
      reasoningEffort: .medium
    )
    let templateDefault = try MLXHistoryRenderer.generationInput(
      from: transcript,
      reasoningEnabled: true
    )

    #expect(medium.additionalContext["reasoning_effort"] as? String == "medium")
    #expect(disabled.additionalContext["reasoning_effort"] == nil)
    #expect(templateDefault.additionalContext["reasoning_effort"] == nil)
  }

  @Test
  func templateMessagesUseFrozenTranscriptContent() throws {
    let callID = UUID()
    let transcript = ModelPromptProjection(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "create index.htm"),
        try ModelFacingPromptRenderer.assistantOutputEntry(
          content: writeFileToolCall(
            callID: callID,
            arguments: [
              "path": .string("index.htm"),
              "content": .string("<html></html>"),
            ]
          ).modelContextContent
        ),
        try ModelFacingPromptRenderer.toolResultEntry(
          toolResult: ToolResultModelMessage(
            callID: callID,
            toolName: .writeFile,
            payload: .writeFile(
              .success(path: WorkspaceRelativePath(rawValue: "index.htm"), bytesWritten: 13))
          ),
          request: toolRequest(
            callID: callID,
            toolName: .writeFile,
            arguments: [
              "path": .string("index.htm"),
              "content": .string("<html></html>"),
            ]
          ),
          originalUserRequest: nil
        ),
        try ModelFacingPromptRenderer.userPromptEntry(
          prompt: "change the background color to green",
          systemContext: ["Use concise coding steps."]
        ),
      ]
    )

    let rendered = try renderedGenerationMessages(
      from: transcript,
      systemPrompt: "This runtime argument must not rewrite frozen content."
    )
    let rawMessages = DefaultMessageGenerator().generate(messages: rendered)
    let rawAssistantToolCalls = try #require(
      rawMessages[2]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )

    #expect(rendered[0].role == .system)
    #expect(rendered.map(\.role) == [.system, .user, .assistant, .tool, .user])
    #expect(!rendered[1].content.contains("System instructions:"))
    #expect(rendered[0].content.contains("This runtime argument must not rewrite"))
    #expect(rendered[4].content.contains("System instructions:"))
    #expect(rendered[4].content.contains("Use concise coding steps."))
    #expect(!rendered[4].content.contains("This runtime argument must not rewrite"))
    #expect(rendered[2].content.isEmpty)
    #expect(rawAssistantFunction["name"] as? String == ToolName.writeFile.rawValue)
    #expect(rendered[3].content.contains("TOOL_RESULT_JSON:"))
    #expect(rendered[3].content.contains("\"tool\":\"write_file\""))
    #expect(rendered[3].content.contains("Summary:"))
    #expect(rendered[3].content.contains("Wrote 13 bytes to index.htm."))
    #expect(rendered[3].content.contains("Tool receipt:") == false)
  }

  @Test
  func runtimeHistoryPrependsSystemPromptWithoutEmbeddingItInUserHistory() throws {
    let callID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "create index.htm"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: writeFileToolCall(
          callID: callID,
          arguments: ["path": .string("index.htm")]
        ).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "index.htm"), bytesWritten: 13))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .writeFile,
          arguments: [
            "path": .string("index.htm"),
            "content": .string("<html></html>"),
          ]
        ),
        originalUserRequest: nil
      ),
    ]

    let history = try renderedGenerationMessages(
      from: ModelPromptProjection(entries: entries),
      systemPrompt: "Use concise coding steps."
    )

    #expect(history.map(\.role) == [.system, .user, .assistant, .tool])
    #expect(history[0].content.contains("Use concise coding steps."))
    #expect(!history[1].content.contains("System instructions:"))
    #expect(!history[1].content.contains("Use concise coding steps."))
    #expect(!history[3].content.contains("Use concise coding steps."))
  }

  @Test
  func renderedHistoryDoesNotRewriteFirstUserWhenToolPromptModeChanges() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "create index.htm",
      systemContext: ["When tools are available, use them."]
    )
    let initialRendered = try renderedGenerationMessages(
      from: ModelPromptProjection(entries: [initialUser]),
      systemPrompt: "When tools are available, use them."
    )
    let entries = [
      initialUser,
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: "Tool call write_file requested."),
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "Tool write_file completed with status success.",
        systemContext: ["No more tools may run in this response."]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "Done."),
    ]

    let history = try generationHistoryMessages(from: entries)

    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(history[0].content == initialRendered[1].content)
    #expect(history[2].content.contains("No more tools may run in this response."))
    #expect(!history[0].content.contains("No more tools may run in this response."))
  }

  @Test
  func templateMessagesPreserveFocusedFileSystemContextInsideUserMessage() throws {
    let transcript = ModelPromptProjection(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(
          prompt: "change the background color to green",
          systemContext: [
            """
            Current focused file: index.htm
            Source: previous write_file
            Known content excerpt:
            <html><body><table><tr><td>Movie</td></tr></table></body></html>
            Explicit file paths in the user request or tool call take precedence.
            """
          ]
        )
      ]
    )

    let rendered = try renderedGenerationMessages(
      from: transcript,
      systemPrompt: "A later runtime argument must not rewrite frozen content."
    )

    #expect(rendered.map(\.role) == [.system, .user])
    #expect(rendered[0].content.contains("A later runtime argument must not rewrite"))
    #expect(rendered[1].content.contains("Current focused file: index.htm"))
    #expect(rendered[1].content.contains("<html><body><table>"))
    #expect(rendered[1].content.contains("User request:"))
    #expect(rendered[1].content.contains("change the background color to green"))
  }

  @Test
  func generationPromptPreservesFocusedFileSystemContextOnFirstTurn() throws {
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "explain this",
        systemContext: [
          """
          Current focused file: index.htm
          Source: previous read_file
          Known content excerpt:
          <h1>Dashboard</h1>
          Explicit file paths in the user request or tool call take precedence.
          """
        ]
      )
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.isEmpty)
    #expect(!prompt.content.contains("Use concise coding steps."))
    #expect(prompt.content.contains("Current focused file: index.htm"))
    #expect(prompt.content.contains("<h1>Dashboard</h1>"))
    #expect(prompt.content.contains("User request:"))
    #expect(prompt.content.contains("explain this"))
  }

  @Test
  func currentPromptContextDoesNotRewriteHistoricalUserMessage() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "summarize the current page",
      systemContext: []
    )
    let initialRendered = try renderedGenerationMessages(
      from: ModelPromptProjection(entries: [initialUser]),
      systemPrompt: "Use concise coding steps."
    )
    let entries = [
      initialUser,
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "The page has a small table."),
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "change the heading",
        systemContext: [
          """
          Current focused file: robots.html
          Source: previous read_file
          Known content excerpt:
          <table><tr><td>Robot</td></tr></table>
          Explicit file paths in the user request or tool call take precedence.
          """
        ]
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content == initialRendered[1].content)
    #expect(!history[0].content.contains("Current focused file: robots.html"))
    #expect(!history[0].content.contains("No more tools may run in this response."))
    #expect(!prompt.content.contains("No more tools may run in this response."))
    #expect(prompt.content.contains("Current focused file: robots.html"))
    #expect(prompt.content.contains("<table><tr><td>Robot</td></tr></table>"))
    #expect(prompt.content.contains("change the heading"))
  }

  @Test
  func templateMessagesDoNotTeachModelInternalInvalidToolActions() throws {
    let callID = UUID()
    let turnID = UUID()
    let transcript = ModelPromptProjection(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(
          turnID: turnID,
          prompt: "change the table heading"
        ),
        try ModelFacingPromptRenderer.toolResultEntry(
          turnID: turnID,
          toolResult: ToolResultModelMessage(
            callID: callID,
            toolName: .invalid,
            payload: .invalidTool(
              InvalidToolResult(
                originalName: "edit_file",
                reason: .parserError("Assistant described a tool call without an action block.")
              ))
          ),
          request: ToolCallRequest.invalid(
            raw: RawToolCallRequest(
              id: callID,
              workspaceID: UUID(),
              sessionID: UUID(),
              toolName: .invalid
            ),
            input: InvalidToolInput(
              originalName: "edit_file",
              rawArguments: [:],
              reason: .parserError("Assistant described a tool call without an action block.")
            )
          ),
          originalUserRequest: "change the table heading"
        ),
      ]
    )

    let rendered = try renderedGenerationMessages(
      from: transcript,
      systemPrompt: "Use concise coding steps."
    )

    #expect(rendered.map(\.role) == [.system, .user])
    #expect(!rendered.contains { $0.content.contains("<|tool_call>call:invalid") })
    #expect(rendered[1].content.contains("The tool call was invalid"))
  }

  @Test
  func toolObservationFollowUpUsesStructuredToolResultPromptBatch() throws {
    let callID = UUID()
    let turnID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        originalUserRequest: "read README.md"
      ),
    ]
    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.promptMessages.map(\.role) == [.tool])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )
    let runtimeCallID = RuntimeToolCallID.string(for: callID)
    #expect(rawAssistantToolCall["id"] as? String == runtimeCallID)
    #expect(rawAssistantFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(rawMessages[2]["tool_call_id"] as? String == runtimeCallID)
    #expect(input.promptMessages[0].content.contains("TOOL_RESULT_JSON:"))
    #expect(input.promptMessages[0].content.contains("\"tool\":\"read_file\""))
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptMessages[0].content.contains(runtimeCallID) == false)
    #expect(input.promptMessages[0].content.contains(callID.uuidString) == false)
    #expect(input.promptSnapshot.map(\.role) == ["tool"])
    #expect(input.promptSnapshot[0].toolCallID == runtimeCallID)
  }

  @Test
  func toolObservationFollowUpNoticeRendersOnlyInToolContent() throws {
    let callID = UUID()
    let turnID = UUID()
    let notice = "Continue from the observation without repeating the same read_file call."
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        originalUserRequest: "read README.md",
        modelFollowUpNotice: notice
      ),
    ]

    let input = try generationInput(from: entries)
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.promptMessages.map(\.role) == [.tool])
    #expect(rawAssistantToolCall["id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(rawAssistantFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(input.history[0].content.contains("[Follow-up]") == false)
    #expect(input.history[1].content.contains("[Follow-up]") == false)
    #expect(input.promptMessages[0].content.contains("TOOL_RESULT_JSON:"))
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptMessages[0].content.contains("\"next_step\":\"\(notice)\""))
    #expect(input.promptMessages[0].content.contains("Original user request:") == false)
    #expect(input.promptSnapshot[0].content == input.promptMessages[0].content)
  }

  @Test
  func multipleToolObservationFollowUpUsesStructuredToolResultPromptBatch() throws {
    let readCallID = UUID()
    let listCallID = UUID()
    let turnID = UUID()
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let listArguments: ToolCallArguments = ["path": .string(".")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md and list files"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          toolCallContent(callID: readCallID, toolName: .readFile, arguments: readArguments),
          toolCallContent(callID: listCallID, toolName: .listFiles, arguments: listArguments),
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: readCallID,
          toolName: .readFile,
          arguments: readArguments
        ),
        originalUserRequest: "read README.md and list files"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: listCallID,
          toolName: .listFiles,
          payload: .listFiles(
            ListFilesResult(
              root: WorkspaceRelativePath(rawValue: "."),
              entries: [
                WorkspaceFileEntry(
                  path: WorkspaceRelativePath(rawValue: "README.md"),
                  kind: .file,
                )
              ]
            ))
        ),
        request: toolRequest(
          callID: listCallID,
          toolName: .listFiles,
          arguments: listArguments
        ),
        originalUserRequest: "read README.md and list files"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    #expect(rawAssistantToolCalls.count == 2)
    let firstToolCall = try #require(rawAssistantToolCalls.first)
    let secondToolCall = try #require(rawAssistantToolCalls.dropFirst().first)
    let firstFunction = try #require(firstToolCall["function"] as? [String: any Sendable])
    let secondFunction = try #require(secondToolCall["function"] as? [String: any Sendable])
    #expect(firstToolCall["id"] as? String == RuntimeToolCallID.string(for: readCallID))
    #expect(firstFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(secondToolCall["id"] as? String == RuntimeToolCallID.string(for: listCallID))
    #expect(secondFunction["name"] as? String == ToolName.listFiles.rawValue)
    #expect(input.promptMessages.map(\.role) == [.tool, .tool])
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: readCallID))
    #expect(rawMessages[3]["tool_call_id"] as? String == RuntimeToolCallID.string(for: listCallID))
  }

  @Test
  func toolCallAfterAssistantPreambleReplaysAsSingleStructuredAssistantMessage() throws {
    let callID = UUID()
    let turnID = UUID()
    let arguments: ToolCallArguments = ["path": .string("README.md")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "I'll inspect that."
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: callID, toolName: .readFile, arguments: arguments),
        originalUserRequest: "read README.md"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.historySnapshot[1].content == "I'll inspect that.")
    #expect(input.historySnapshot[1].toolCalls.count == 1)
    #expect(input.promptMessages.map(\.role) == [.tool])
  }

  @Test
  func redactedWriteFileBoundaryReplaysAsStructuredToolCall() throws {
    let callID = UUID()
    let turnID = UUID()
    let arguments: ToolCallArguments = [
      "path": .string("movies.html"),
      "content": .string("<html></html>"),
    ]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "create movies.html"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: writeFileToolCall(callID: callID, arguments: arguments).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
        ),
        request: toolRequest(callID: callID, toolName: .writeFile, arguments: arguments),
        originalUserRequest: "create movies.html"
      ),
    ]

    let input = try generationInput(from: entries)
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )
    let rawArguments = try #require(rawAssistantFunction["arguments"] as? [String: any Sendable])

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.historySnapshot[1].content.isEmpty)
    #expect(rawAssistantToolCall["id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(rawAssistantFunction["name"] as? String == ToolName.writeFile.rawValue)
    #expect(rawArguments["content"] as? String == "<html></html>")
    #expect(input.promptMessages.map(\.role) == [.tool])
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID))
  }

  @Test
  func writeResultFollowUpIncludesEntireStructuredResultGroup() throws {
    let readCallID = UUID()
    let writeCallID = UUID()
    let turnID = UUID()
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let writeArguments: ToolCallArguments = [
      "path": .string("movies.html"),
      "content": .string("<html></html>"),
    ]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md and create movies.html"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          ToolCallModelMessage(
            rawRequest: RawToolCallRequest(
              id: readCallID,
              workspaceID: UUID(),
              sessionID: UUID(),
              toolName: .readFile,
              arguments: readArguments
            )
          ).modelContextContent,
          writeFileToolCall(callID: writeCallID, arguments: writeArguments).modelContextContent,
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: readCallID, toolName: .readFile, arguments: readArguments),
        originalUserRequest: "read README.md and create movies.html"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: writeCallID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
        ),
        request: toolRequest(callID: writeCallID, toolName: .writeFile, arguments: writeArguments),
        originalUserRequest: "read README.md and create movies.html"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(
      input.historySnapshot[1].toolCalls.map(\.id) == [
        RuntimeToolCallID.string(for: readCallID),
        RuntimeToolCallID.string(for: writeCallID),
      ])
    #expect(input.promptMessages.map(\.role) == [.tool, .tool])
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptMessages[1].content.contains("Wrote 13 bytes to movies.html."))
    #expect(!input.promptMessages[1].content.contains("Original user request:"))
  }

  @Test
  func mixedDeniedAndSuccessfulBatchKeepsCallAndResultOrder() throws {
    let deniedCallID = UUID()
    let successfulCallID = UUID()
    let turnID = UUID()
    let deniedArguments: ToolCallArguments = [
      "path": .string("denied.txt"),
      "content": .string("denied"),
    ]
    let successfulArguments: ToolCallArguments = [
      "path": .string("accepted.txt"),
      "content": .string("accepted"),
    ]
    let deniedRequest = toolRequest(
      callID: deniedCallID,
      toolName: .writeFile,
      arguments: deniedArguments
    )
    let successfulRequest = toolRequest(
      callID: successfulCallID,
      toolName: .writeFile,
      arguments: successfulArguments
    )
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "write both files"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          ToolCallModelMessage(request: deniedRequest).modelContextContent,
          ToolCallModelMessage(request: successfulRequest).modelContextContent,
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: deniedCallID,
          toolName: .writeFile,
          payload: .failure(
            ToolFailure(
              toolName: .writeFile,
              path: WorkspaceRelativePath(rawValue: "denied.txt"),
              reason: .userDenied
            ))
        ),
        request: deniedRequest,
        originalUserRequest: "write both files"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: successfulCallID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "accepted.txt"),
              bytesWritten: 8
            ))
        ),
        request: successfulRequest,
        originalUserRequest: "write both files"
      ),
    ]

    let input = try generationInput(from: entries)
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )

    #expect(
      rawAssistantToolCalls.compactMap { $0["id"] as? String } == [
        RuntimeToolCallID.string(for: deniedCallID),
        RuntimeToolCallID.string(for: successfulCallID),
      ])
    #expect(
      rawMessages[2]["tool_call_id"] as? String
        == RuntimeToolCallID.string(for: deniedCallID))
    #expect(
      rawMessages[3]["tool_call_id"] as? String
        == RuntimeToolCallID.string(for: successfulCallID))
    #expect(input.promptMessages[0].content.contains("\"status\":\"denied\""))
    #expect(input.promptMessages[0].content.contains("\"kind\":\"user_denied\""))
    #expect(input.promptMessages[0].content.contains("Tool call denied by user."))
    #expect(input.promptMessages[1].content.contains("Wrote 8 bytes to accepted.txt."))
  }

  @Test
  func laterUserTurnHistoryKeepsStructuredToolResult() throws {
    let callID = UUID()
    let turnID = UUID()
    let transcript = ModelPromptProjection(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        originalUserRequest: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "README.md is a project file."
      ),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you read?"),
    ])

    let history = try generationHistoryMessages(from: transcript.entries)

    #expect(history.map(\.role) == [.user, .assistant, .tool, .assistant])
    #expect(history[2].content.contains("TOOL_RESULT_JSON:"))
    #expect(history[2].content.contains("Project overview"))
    #expect(history[2].content.contains("Tool receipt:") == false)
    #expect(history[3].content.contains("README.md is a project file."))
  }

  // The native tool result is rendered as the same structured tool message in
  // both the prompt batch and later history, so the cached KV prefix survives
  // the turn boundary.
  @Test
  func writeToolResultFollowUpUsesStructuredToolResultAsPrompt() throws {
    let callID = UUID()
    let turnID = UUID()
    let writeResult = ToolResultModelMessage(
      callID: callID,
      toolName: .writeFile,
      payload: .writeFile(
        .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
    )
    let writeRequest = toolRequest(
      callID: callID,
      toolName: .writeFile,
      arguments: [
        "path": .string("movies.html"),
        "content": .string("<html></html>"),
      ]
    )
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "create movies.html"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: writeFileToolCall(
          callID: callID,
          arguments: [
            "path": .string("movies.html"),
            "content": .string("<html></html>"),
          ]
        ).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: writeResult,
        request: writeRequest,
        originalUserRequest: nil
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(prompt.role == .tool)
    #expect(!prompt.content.contains("Original user request:"))
    #expect(prompt.content.contains("Summary: Wrote 13 bytes to movies.html."))
    #expect(!prompt.content.contains("Do not include generated file contents"))
    #expect(!prompt.content.contains("No more tools may run in this response."))
  }

  @Test
  func unstructuredWriteResultReplaysAsOrdinaryUserObservation() throws {
    let callID = UUID()
    let writeResult = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: ToolResultModelMessage(
        callID: callID,
        toolName: .writeFile,
        payload: .writeFile(
          .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13)
        )
      ),
      request: toolRequest(
        callID: callID,
        toolName: .writeFile,
        arguments: [
          "path": .string("movies.html"),
          "content": .string("<html></html>"),
        ]
      ),
      originalUserRequest: nil
    )

    let rendered = try renderedGenerationMessages(
      from: ModelPromptProjection(entries: [writeResult]),
      systemPrompt: ""
    )

    #expect(rendered.map(\.role) == [.user])
    #expect(rendered[0].content.contains("\"tool\":\"write_file\""))
    #expect(rendered[0].content.contains("Summary: Wrote 13 bytes to movies.html."))
  }

  private func renderedGenerationMessages(
    from transcript: ModelPromptProjection,
    systemPrompt: String
  ) throws -> [Chat.Message] {
    let input = try MLXHistoryRenderer.generationInput(from: transcript)
    return try MLXHistoryRenderer.runtimeHistoryMessages(
      systemPrompt: systemPrompt,
      history: input.history
    ) + input.promptMessages
  }

  private func storedImageFixture(exifOrientation: Int) throws -> StoredImageFixture {
    let directoryURL = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let sourceURL = directoryURL.appending(
      path: "orientation-\(exifOrientation).jpg",
      directoryHint: .notDirectory
    )
    try writeMarkerJPEG(to: sourceURL, exifOrientation: exifOrientation)
    let data = try Data(contentsOf: sourceURL)
    let store = ChatAttachmentStore(baseURL: directoryURL.appending(path: "attachments"))
    let id = AttachmentID()
    let storedURL = try store.storeFile(
      from: sourceURL,
      id: id,
      displayName: sourceURL.lastPathComponent
    )
    let attachment = ChatAttachment(
      id: id,
      displayName: sourceURL.lastPathComponent,
      payload: .image(
        ImageAttachmentPayload(
          mimeType: "image/jpeg",
          byteSize: data.count,
          contentSHA256: ChatAttachmentStore.contentSHA256(for: data)
        )
      )
    )
    return StoredImageFixture(
      store: store,
      attachment: attachment,
      storedURL: storedURL
    )
  }

  private func storedImageFixture(data: Data, displayName: String) throws -> StoredImageFixture {
    let directoryURL = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let sourceURL = directoryURL.appending(path: displayName, directoryHint: .notDirectory)
    try data.write(to: sourceURL)
    let store = ChatAttachmentStore(baseURL: directoryURL.appending(path: "attachments"))
    let id = AttachmentID()
    let storedURL = try store.storeFile(from: sourceURL, id: id, displayName: displayName)
    let attachment = ChatAttachment(
      id: id,
      displayName: displayName,
      payload: .image(
        ImageAttachmentPayload(
          mimeType: "image/jpeg",
          byteSize: data.count,
          contentSHA256: ChatAttachmentStore.contentSHA256(for: data)
        )
      )
    )
    return StoredImageFixture(
      store: store,
      attachment: attachment,
      storedURL: storedURL
    )
  }

  private func writeMarkerJPEG(to url: URL, exifOrientation: Int) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw EXIFImageFixtureError.couldNotCreateDestination
    }
    CGImageDestinationAddImage(
      destination,
      try markerImage(),
      [kCGImagePropertyOrientation: exifOrientation] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw EXIFImageFixtureError.couldNotFinalizeDestination
    }
  }

  private func markerImage() throws -> CGImage {
    let width = 40
    let height = 20
    var pixels: [UInt8] = []
    pixels.reserveCapacity(width * height * 4)
    for row in 0..<height {
      for column in 0..<width {
        let color: (UInt8, UInt8, UInt8) =
          switch (column < width / 2, row < height / 2) {
          case (true, true): (255, 0, 0)
          case (false, true): (0, 255, 0)
          case (true, false): (0, 0, 255)
          case (false, false): (255, 255, 0)
          }
        pixels.append(contentsOf: [color.0, color.1, color.2, 255])
      }
    }
    guard
      let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else {
      throw EXIFImageFixtureError.couldNotCreateMarkerImage
    }
    return image
  }

  private func previewImage(from url: URL) throws -> CIImage {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1_024,
        ] as CFDictionary
      )
    else {
      throw EXIFImageFixtureError.couldNotCreatePreviewImage
    }
    return CIImage(cgImage: image)
  }

  private func markerSignature(of image: CIImage) -> String {
    let extent = image.extent.integral
    let width = Int(extent.width)
    let height = Int(extent.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    CIContext(options: [.cacheIntermediates: false]).render(
      image,
      toBitmap: &pixels,
      rowBytes: width * 4,
      bounds: extent,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )

    func marker(atColumn column: Int, row: Int) -> Character {
      let offset = (row * width + column) * 4
      let red = Int(pixels[offset])
      let green = Int(pixels[offset + 1])
      let blue = Int(pixels[offset + 2])
      if red > 160, green > 160, blue < 100 {
        return "Y"
      }
      if red > green, red > blue {
        return "R"
      }
      if green > red, green > blue {
        return "G"
      }
      return "B"
    }

    return String([
      marker(atColumn: width / 4, row: height / 4),
      marker(atColumn: 3 * width / 4, row: height / 4),
      marker(atColumn: width / 4, row: 3 * height / 4),
      marker(atColumn: 3 * width / 4, row: 3 * height / 4),
    ])
  }

  private func generationHistoryMessages(
    from entries: [ModelContextEntry]
  ) throws -> [Chat.Message] {
    let currentPrompt = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "Current runtime test prompt."
    )
    return try generationInput(from: entries + [currentPrompt]).history
  }

  private func generationInput(
    from entries: [ModelContextEntry]
  ) throws -> MLXGenerationInput {
    try MLXHistoryRenderer.generationInput(from: ModelPromptProjection(entries: entries))
  }

  private func generationHistoryAndPrompt(
    from entries: [ModelContextEntry]
  ) throws -> (history: [Chat.Message], prompt: Chat.Message) {
    let input = try generationInput(from: entries)
    return (input.history, try #require(input.promptMessages.last))
  }

  private func writeFileToolCall(
    callID: UUID,
    arguments: ToolCallArguments
  ) -> ToolCallModelMessage {
    ToolCallModelMessage(
      rawRequest: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .writeFile,
        arguments: arguments
      ))
  }

  private func toolCallContent(
    callID: UUID,
    toolName: ToolName,
    arguments: ToolCallArguments
  ) -> String {
    ToolCallModelMessage(
      rawRequest: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: toolName,
        arguments: arguments
      )
    ).modelContextContent
  }

  private func toolRequest(
    callID: UUID,
    toolName: ToolName,
    arguments: ToolCallArguments
  ) -> ToolCallRequest {
    let rawRequest = RawToolCallRequest(
      id: callID,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
    return ToolCallRequestValidator().validate(
      rawRequest,
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )
  }

}

private struct StoredImageFixture {
  let store: ChatAttachmentStore
  let attachment: ChatAttachment
  let storedURL: URL
}

private enum EXIFImageFixtureError: Error {
  case couldNotCreateDestination
  case couldNotFinalizeDestination
  case couldNotCreateMarkerImage
  case couldNotCreatePreviewImage
}

enum EXIFOrientationExpectation: Int, CaseIterable, Sendable {
  case upright = 1
  case upMirrored = 2
  case down = 3
  case downMirrored = 4
  case leftMirrored = 5
  case right = 6
  case rightMirrored = 7
  case left = 8

  var size: CGSize {
    switch self {
    case .upright, .upMirrored, .down, .downMirrored:
      CGSize(width: 40, height: 20)
    case .leftMirrored, .right, .rightMirrored, .left:
      CGSize(width: 20, height: 40)
    }
  }

  var markerSignature: String {
    switch self {
    case .upright: "RGBY"
    case .upMirrored: "GRYB"
    case .down: "YBGR"
    case .downMirrored: "BYRG"
    case .leftMirrored: "RBGY"
    case .right: "BRYG"
    case .rightMirrored: "YGBR"
    case .left: "GYRB"
    }
  }
}
