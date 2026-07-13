import Foundation
import Testing

@testable import SumikaCore

struct ChatModelContextBuilderTests {
  @Test
  func filtersProjectionEntriesFromExcludedTurns() throws {
    let includedTurnID = UUID()
    let excludedTurnID = UUID()
    let state = ChatSession(
      turns: [
        ChatTurn(
          id: includedTurnID,
          status: .completed,
          items: [
            .userMessage(UserTurnMessage(content: "included prompt")),
            .assistantMessage(AssistantTurnMessage(content: "included")),
          ]),
        ChatTurn(
          id: excludedTurnID,
          status: .cancelled,
          modelContextPolicy: .excluded,
          items: [.userMessage(UserTurnMessage(content: "large listing"))]
        ),
      ],
      pendingAttachments: [],
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      )
    )

    let transcript = ChatModelContextBuilder().transcript(from: state)

    #expect(transcript.entries.map(\.frozenContent.role) == [.user, .assistant])
    #expect(transcript.entries[0].frozenContent.content == "included prompt")
    #expect(transcript.entries[1].frozenContent.content == "included")
  }

  @Test
  func includesExcludedTurnWhenItIsTheActiveTurn() throws {
    let turnID = UUID()
    let state = ChatSession(
      turns: [
        ChatTurn(
          id: turnID,
          status: .cancelled,
          modelContextPolicy: .excluded,
          items: [.userMessage(UserTurnMessage(content: "README.md"))]
        )
      ],
      pendingAttachments: [],
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      )
    )

    let transcript = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    #expect(transcript.entries.map(\.frozenContent.content) == ["README.md"])
  }

  @Test
  func assistantProjectionPolicyOverridesOrExcludesVisibleContent() throws {
    let state = ChatSession(
      turns: [
        ChatTurn(
          status: .completed,
          items: [
            .assistantMessage(AssistantTurnMessage(content: "Visible content.")),
            .assistantMessage(
              AssistantTurnMessage(
                content: "Large direct tool response.",
                modelProjectionPolicy: .override("Displayed direct tool result.")
              )),
            .assistantMessage(
              AssistantTurnMessage(
                content: "Visible but excluded from model context.",
                modelProjectionPolicy: .excluded
              )),
          ])
      ]
    )

    let transcript = ChatModelContextBuilder().transcript(from: state)

    #expect(transcript.entries.map(\.frozenContent.role) == [.assistant, .assistant])
    #expect(
      transcript.entries.map(\.frozenContent.content) == [
        "Visible content.",
        "Displayed direct tool result.",
      ])
  }

  @Test
  func currentPromptSystemContextFreezesRenderedFocusedFileContextIntoUserPrompt() throws {
    let path = WorkspaceRelativePath(rawValue: "index.html")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(
          path: path,
          source: .writeFile,
          confidence: .active,
          updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "<h1>Hello</h1>",
          fullContentAvailable: true
        )
      ]
    )

    let currentPromptContext = ChatModelContextBuilder().currentPromptContext(
      userInput: "summarize this",
      mode: .chat,
      focusedFileState: state
    )
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "summarize this",
      systemContext: ["System"] + currentPromptContext.renderedBlocks,
      currentPromptContext: currentPromptContext.consumedContext
    )

    #expect(
      entry.body
        == .userPrompt(
          UserPromptContext(
            prompt: "summarize this",
            systemContext: ["System"] + currentPromptContext.renderedBlocks,
            currentPromptContext: currentPromptContext.consumedContext
          )
        ))
    guard case .userPrompt(let userPromptContext) = entry.body,
      case .selected(let consumedSelection) = userPromptContext.currentPromptContext,
      case .focusedFile(let consumedFocusedFile) = consumedSelection.blocks.values[0]
    else {
      Issue.record("Expected typed focused file context snapshot.")
      return
    }
    #expect(consumedFocusedFile.path == path)
    #expect(consumedFocusedFile.source == .writeFile)
    #expect(consumedFocusedFile.contentHash == "hash")
    #expect(consumedFocusedFile.excerpt?.text == "<h1>Hello</h1>")
    #expect(entry.frozenContent.content.contains("Current focused file: index.html"))
    #expect(entry.frozenContent.content.contains("Source: previous write_file"))
    #expect(entry.frozenContent.content.contains("Known content excerpt:"))
    #expect(entry.frozenContent.content.contains("<h1>Hello</h1>"))
  }

  @Test
  func currentPromptSystemContextFreezesRenderedAttachedFileContextIntoUserPrompt() throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/project/Sources/Foo.swift"),
      displayName: "Foo.swift",
      kind: .text,
      content: "func attached() {}"
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory)
    )

    let currentPromptContext = ChatModelContextBuilder().currentPromptContext(
      userInput: "explain attached",
      mode: .agent,
      focusedFileState: .empty,
      attachments: [attachment],
      workspace: workspace
    )
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "explain attached",
      attachments: [attachment],
      systemContext: ["System"] + currentPromptContext.renderedBlocks,
      currentPromptContext: currentPromptContext.consumedContext
    )

    #expect(
      entry.body
        == .userPrompt(
          UserPromptContext(
            prompt: "explain attached",
            attachmentNames: ["Foo.swift"],
            systemContext: ["System"] + currentPromptContext.renderedBlocks,
            currentPromptContext: currentPromptContext.consumedContext
          )
        ))
    guard case .userPrompt(let userPromptContext) = entry.body,
      case .selected(let consumedSelection) = userPromptContext.currentPromptContext,
      case .attachedFile(let consumedAttachment) = consumedSelection.blocks.values[0]
    else {
      Issue.record("Expected typed attached file context snapshot.")
      return
    }
    #expect(consumedAttachment.path == WorkspaceRelativePath(rawValue: "Foo.swift"))
    #expect(consumedAttachment.displayName == "Foo.swift")
    #expect(consumedAttachment.excerpt?.text == "func attached() {}")
    #expect(entry.frozenContent.content.contains("Attached file: Foo.swift"))
    #expect(entry.frozenContent.content.contains("Attached content excerpt:"))
    #expect(entry.frozenContent.content.contains("func attached() {}"))
    #expect(entry.frozenContent.content.contains("Attached context:") == false)
    #expect(entry.frozenContent.content.contains("File: Foo.swift") == false)
  }

  @Test
  func toolResultAppendIsPrefixStableWhenTranscriptMutates() throws {
    let turnID = UUID()
    let sourceMessageID = UUID()
    let toolRecord = makeCompletedReadFileRecord()
    var state = ChatSession(
      turns: [
        ChatTurn(
          id: turnID,
          status: .running,
          items: [
            .assistantMessage(
              AssistantTurnMessage(
                id: sourceMessageID,
                content: "I will read README.md."
              ))
          ]
        )
      ],
      pendingAttachments: [],
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      )
    )
    let before = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    ChatTranscriptMutator().recordToolCall(toolRecord, turnID: turnID, in: &state)
    let after = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)

    #expect(
      Array(after.entries.prefix(before.entries.count)).map(\.frozenContent)
        == before.entries.map(\.frozenContent))
    #expect(
      Array(after.entries.prefix(before.entries.count)).map(\.sourceMessageID)
        == before.entries.map(\.sourceMessageID))
    #expect(state.transcriptItemsForTesting.map(\.kindForTesting) == [.assistant, .toolResult])
    #expect(after.entries.last?.sourceMessageID == toolRecord.id)
  }

  @Test
  func partiallyResolvedToolBatchIsSuppressedUntilEveryResultExists() throws {
    let first = makeCompletedReadFileRecord()
    var second = makeReadFileRecord(state: .awaitingApproval(preview: nil))
    let turnID = UUID()
    var state = ChatSession(
      turns: [
        ChatTurn(
          id: turnID,
          status: .awaitingApproval,
          items: [
            .userMessage(UserTurnMessage(content: "Inspect both files.")),
            .tool(first),
            .assistantThinking(AssistantThinkingMessage(content: "Same model response.")),
            .tool(second),
          ]
        )
      ]
    )

    let partial = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)
    #expect(partial.entries.map(\.frozenContent.role) == [.user])

    second.state = .completed(
      .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "second result")
        )))
    ChatTranscriptMutator().updateToolCallRecord(second, in: &state)

    let resolved = ChatModelContextBuilder().transcript(from: state, includingTurnID: turnID)
    #expect(resolved.entries.map(\.frozenContent.role) == [.user, .assistant, .tool, .tool])
    #expect(Array(resolved.entries.suffix(2)).map(\.sourceMessageID) == [first.id, second.id])
  }

  @Test
  func completeReadFileSnapshotsAlternateFullAndCompactReuse() throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let state = ChatSession(
      turns: (1...4).map { index in
        ChatTurn(
          status: .completed,
          items: [
            .userMessage(
              UserTurnMessage(
                content: "Continue \(index)",
                promptContext: context
              ))
          ]
        )
      }
    )

    let entries = ChatModelContextBuilder().transcript(from: state).entries

    #expect(entries.count == 4)
    #expect(entries.map(isCompactReuse) == [false, true, false, true])
    #expect(entries[0].frozenContent.content.contains("Known content excerpt:"))
    #expect(entries[2].frozenContent.content.contains("Known content excerpt:"))
  }

  @Test
  func writeAndEditFileSnapshotsNeverUseCompactReuse() throws {
    for source in [FocusedPathSource.writeFile, .editFile] {
      let context = focusedFileContext(source: source, fullContentAvailable: true)
      let state = ChatSession(
        turns: [
          focusedFileTurn(content: "First", context: context),
          focusedFileTurn(content: "Second", context: context),
        ]
      )

      let entries = ChatModelContextBuilder().transcript(from: state).entries

      #expect(entries.count == 2)
      #expect(entries.allSatisfy { !isCompactReuse($0) })
      #expect(entries.allSatisfy { $0.frozenContent.content.contains("Known content excerpt:") })
    }
  }

  @Test
  func partialReadFileSnapshotNeverUsesCompactReuse() throws {
    let completeContext = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let partialContext = focusedFileContext(source: .readFile, fullContentAvailable: false)
    let state = ChatSession(
      turns: [
        focusedFileTurn(content: "First", context: completeContext),
        focusedFileTurn(content: "Partial", context: partialContext),
        focusedFileTurn(content: "Second", context: completeContext),
      ]
    )

    let entries = ChatModelContextBuilder().transcript(from: state).entries

    #expect(entries.count == 3)
    #expect(entries.allSatisfy { !isCompactReuse($0) })
    #expect(entries.allSatisfy { $0.frozenContent.content.contains("Known content excerpt:") })
  }

  @Test
  func excludedTurnInvalidatesFocusedFileReuseAnchor() throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let state = ChatSession(
      turns: [
        focusedFileTurn(content: "First", context: context),
        ChatTurn(
          status: .cancelled,
          modelContextPolicy: .excluded,
          items: [.userMessage(UserTurnMessage(content: "Excluded"))]
        ),
        focusedFileTurn(content: "Second", context: context),
      ]
    )

    let entries = ChatModelContextBuilder().transcript(from: state).entries

    #expect(entries.count == 2)
    #expect(entries.allSatisfy { !isCompactReuse($0) })
  }

  @Test
  func differentFocusedFileIdentityReplacesReuseAnchor() throws {
    let firstContext = focusedFileContext(
      source: .readFile,
      fullContentAvailable: true,
      path: "Sources/App.swift",
      contentHash: "app-hash"
    )
    let secondContext = focusedFileContext(
      source: .readFile,
      fullContentAvailable: true,
      path: "Sources/Other.swift",
      contentHash: "other-hash"
    )
    let state = ChatSession(
      turns: [
        focusedFileTurn(content: "First", context: firstContext),
        focusedFileTurn(content: "Other", context: secondContext),
        focusedFileTurn(content: "First again", context: firstContext),
      ]
    )

    let entries = ChatModelContextBuilder().transcript(from: state).entries

    #expect(entries.count == 3)
    #expect(entries.allSatisfy { !isCompactReuse($0) })
  }

  @Test
  func mutatingAndUnknownToolsConservativelyInvalidateReuseAnchor() throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)

    for record in [
      makeCompletedWriteFileRecord(),
      makeCompletedEditFileRecord(),
      makeCompletedRunCommandRecord(),
      makeCompletedMCPRecord(),
      makeUnknownToolRecord(),
    ] {
      let state = ChatSession(
        turns: [
          focusedFileTurn(content: "First", context: context),
          ChatTurn(status: .completed, items: [.tool(record)]),
          focusedFileTurn(content: "Second", context: context),
        ]
      )

      let entries = ChatModelContextBuilder().transcript(from: state).entries
      let userEntries = entries.filter { entry in
        if case .userPrompt = entry.body {
          return true
        }
        return false
      }

      #expect(userEntries.count == 2)
      #expect(userEntries.allSatisfy { !isCompactReuse($0) })
      #expect(
        userEntries.allSatisfy {
          $0.frozenContent.content.contains("Known content excerpt:")
        })
    }
  }

  @Test
  func partialFailedTruncatedAndRedactedReadsInvalidateReuseAnchor() throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let path = WorkspaceRelativePath(rawValue: "README.md")
    let records = [
      makeReadFileRecord(
        input: ReadFileInput(path: path.rawValue, offset: 2),
        state: .completed(
          .readFile(
            .success(path: path, content: ToolTextOutput(text: "partial"))
          ))
      ),
      makeReadFileRecord(
        input: ReadFileInput(path: path.rawValue, limit: 20),
        state: .completed(
          .readFile(
            .success(path: path, content: ToolTextOutput(text: "limited"))
          ))
      ),
      makeReadFileRecord(
        state: .failed(
          .readFile(.failed(path: path, reason: .executionError("failed")))
        )
      ),
      makeReadFileRecord(
        state: .completed(
          .readFile(
            .success(
              path: path,
              content: ToolTextOutput(text: "truncated", truncated: true)
            ))
        )
      ),
      makeReadFileRecord(
        state: .completed(
          .readFile(
            .success(
              path: path,
              content: ToolTextOutput(text: "redacted", redacted: true)
            ))
        )
      ),
    ]

    for record in records {
      let state = ChatSession(
        turns: [
          focusedFileTurn(content: "First", context: context),
          ChatTurn(status: .completed, items: [.tool(record)]),
          focusedFileTurn(content: "Second", context: context),
        ]
      )
      let userEntries = ChatModelContextBuilder().transcript(from: state).entries.filter { entry in
        if case .userPrompt = entry.body {
          return true
        }
        return false
      }

      #expect(userEntries.count == 2)
      #expect(userEntries.allSatisfy { !isCompactReuse($0) })
    }
  }

  @Test
  func completeReadFileObservationPreservesReuseAnchor() throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let state = ChatSession(
      turns: [
        focusedFileTurn(content: "First", context: context),
        ChatTurn(status: .completed, items: [.tool(makeCompletedReadFileRecord())]),
        focusedFileTurn(content: "Second", context: context),
      ]
    )
    let userEntries = ChatModelContextBuilder().transcript(from: state).entries.filter { entry in
      if case .userPrompt = entry.body {
        return true
      }
      return false
    }

    #expect(userEntries.count == 2)
    #expect(!isCompactReuse(userEntries[0]))
    #expect(isCompactReuse(userEntries[1]))
  }

  @Test(arguments: [8_000, 8_001])
  func providerProjectedByteBoundaryControlsCompactReuse(interveningBytes: Int) throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let assistantRoleBytes = ModelContextRole.assistant.rawValue.utf8.count
    let state = ChatSession(
      turns: [
        ChatTurn(
          status: .completed,
          items: [
            .userMessage(UserTurnMessage(content: "First", promptContext: context)),
            .assistantMessage(
              AssistantTurnMessage(
                content: String(
                  repeating: "x",
                  count: interveningBytes - assistantRoleBytes
                )
              )),
          ]
        ),
        focusedFileTurn(content: "Second", context: context),
      ]
    )
    let fullProjection = ChatModelContextBuilder(
      focusedFileReusePolicy: .disabled
    ).transcript(from: state)
    let providerProjection = ProviderPromptProjection.normalized(from: fullProjection)
    let anchorID = fullProjection.entries[0].id
    let candidateID = fullProjection.entries[2].id

    let measuredBytes = providerProjection.byteLedger.interveningByteCount(
      afterSourceEntryID: anchorID,
      beforeSourceEntryID: candidateID
    )
    let optimized = ChatModelContextBuilder().transcript(from: state)

    #expect(measuredBytes == interveningBytes)
    #expect(isCompactReuse(optimized.entries[2]) == (interveningBytes == 8_000))
  }

  @Test(arguments: [8_000, 8_001])
  func mergedUserRoleByteBoundaryControlsCompactReuse(interveningBytes: Int) throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let separatorBytes = 2 * "\n\n".utf8.count
    let state = ChatSession(
      turns: [
        focusedFileTurn(content: "First", context: context),
        ChatTurn(
          status: .completed,
          items: [
            .userMessage(
              UserTurnMessage(
                content: String(repeating: "x", count: interveningBytes - separatorBytes)
              ))
          ]
        ),
        focusedFileTurn(content: "Second", context: context),
      ]
    )
    let fullProjection = ChatModelContextBuilder(
      focusedFileReusePolicy: .disabled
    ).transcript(from: state)
    let providerProjection = ProviderPromptProjection.normalized(from: fullProjection)
    let measuredBytes = providerProjection.byteLedger.interveningByteCount(
      afterSourceEntryID: fullProjection.entries[0].id,
      beforeSourceEntryID: fullProjection.entries[2].id
    )
    let optimized = ChatModelContextBuilder().transcript(from: state)

    #expect(providerProjection.messages.count == 1)
    #expect(measuredBytes == interveningBytes)
    #expect(isCompactReuse(optimized.entries[2]) == (interveningBytes == 8_000))
  }

  @Test
  func appendingReusableFocusedFileTurnPreservesEntryAndProviderPrefix() throws {
    let context = focusedFileContext(source: .readFile, fullContentAvailable: true)
    let firstTurn = ChatTurn(
      status: .completed,
      items: [
        .userMessage(UserTurnMessage(content: "First", promptContext: context)),
        .assistantMessage(AssistantTurnMessage(content: "Ready for the next step.")),
      ]
    )
    let firstProjection = ChatModelContextBuilder().transcript(
      from: ChatSession(turns: [firstTurn])
    )
    let appendedProjection = ChatModelContextBuilder().transcript(
      from: ChatSession(
        turns: [
          firstTurn,
          focusedFileTurn(content: "Second", context: context),
        ]
      )
    )
    let firstProviderProjection = ProviderPromptProjection.normalized(from: firstProjection)
    let appendedProviderProjection = ProviderPromptProjection.normalized(
      from: appendedProjection
    )

    #expect(
      Array(appendedProjection.entries.prefix(firstProjection.entries.count)).map(\.frozenContent)
        == firstProjection.entries.map(\.frozenContent))
    #expect(
      Array(appendedProjection.entries.prefix(firstProjection.entries.count)).map(\.body)
        == firstProjection.entries.map(\.body))
    #expect(
      Array(appendedProjection.entries.prefix(firstProjection.entries.count)).map(
        \.sourceMessageID
      ) == firstProjection.entries.map(\.sourceMessageID))
    #expect(
      Array(
        appendedProviderProjection.messages.prefix(firstProviderProjection.messages.count)
      ) == firstProviderProjection.messages)
    #expect(isCompactReuse(appendedProjection.entries.last))
  }

  private func focusedFileContext(
    source: FocusedPathSource,
    fullContentAvailable: Bool,
    path pathValue: String = "Sources/App.swift",
    contentHash: String = "stable-hash"
  ) -> CurrentPromptContext {
    let path = WorkspaceRelativePath(rawValue: pathValue)
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: source, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: contentHash,
          excerpt: "struct App { let value = 1 }",
          fullContentAvailable: fullContentAvailable
        )
      ]
    )
    return CurrentPromptContextSelector().selectContext(
      userInput: "Continue",
      mode: .agent,
      focusedFileState: state,
      budget: .focusedFileDefault
    )
  }

  private func focusedFileTurn(
    content: String,
    context: CurrentPromptContext
  ) -> ChatTurn {
    ChatTurn(
      status: .completed,
      items: [
        .userMessage(UserTurnMessage(content: content, promptContext: context))
      ]
    )
  }

  private func isCompactReuse(_ entry: ModelContextEntry?) -> Bool {
    entry?.frozenContent.content.contains(
      "Same known complete snapshot as in the recent context; content is not repeated."
    ) == true
  }

  private func makeCompletedRunCommandRecord() -> ToolCallRecord {
    let command = "touch generated.txt"
    let input = RunCommandInput(command: command, timeoutSeconds: 10)
    return ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          workspaceID: UUID(),
          sessionID: UUID(),
          toolName: .runCommand,
          arguments: ["command": .string(command)]
        ),
        payload: .runCommand(input)
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed in test.",
        riskLevel: .high
      ),
      state: .completed(
        .runCommand(
          RunCommandResult(
            command: command,
            timeoutSeconds: 10,
            exitCode: 0,
            durationMs: 1,
            stdout: ToolTextOutput(text: ""),
            stderr: ToolTextOutput(text: "")
          )))
    )
  }

  private func makeCompletedWriteFileRecord() -> ToolCallRecord {
    let path = WorkspaceRelativePath(rawValue: "generated.txt")
    let input = WriteFileInput(path: path.rawValue, content: "generated")
    return completedToolRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          workspaceID: UUID(),
          sessionID: UUID(),
          toolName: .writeFile,
          arguments: [
            "path": .string(input.path),
            "content": .string(input.content),
          ]
        ),
        payload: .writeFile(input)
      ),
      result: .writeFile(.success(path: path, bytesWritten: input.content.utf8.count))
    )
  }

  private func makeCompletedEditFileRecord() -> ToolCallRecord {
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let input = EditFileInput(path: path.rawValue, oldText: "old", newText: "new")
    return completedToolRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          workspaceID: UUID(),
          sessionID: UUID(),
          toolName: .editFile,
          arguments: [
            "path": .string(input.path),
            "old_text": .string(input.oldText),
            "new_text": .string(input.newText),
          ]
        ),
        payload: .editFile(input)
      ),
      result: .editFile(.success(path: path, diff: nil, matchStrategy: .exact))
    )
  }

  private func makeCompletedMCPRecord() -> ToolCallRecord {
    let input = MCPToolInput(
      serverID: UUID(),
      serverName: "Test",
      serverSlug: "test",
      remoteToolName: "inspect",
      arguments: [:]
    )
    return completedToolRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          workspaceID: UUID(),
          sessionID: UUID(),
          toolName: input.qualifiedName,
          arguments: [:]
        ),
        payload: .mcp(input)
      ),
      result: .mcp(
        MCPToolResult(
          serverName: input.serverName,
          remoteToolName: input.remoteToolName,
          content: [.text("complete")],
          isError: false
        ))
    )
  }

  private func completedToolRecord(
    request: ToolCallRequest,
    result: ToolResultPayload
  ) -> ToolCallRecord {
    ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed in test.",
        riskLevel: .high
      ),
      state: .completed(result)
    )
  }

  private func makeUnknownToolRecord() -> ToolCallRecord {
    let toolName = ToolName(rawValue: "unknown_workspace_tool")
    let reason = InvalidToolCallReason.unknownToolName(toolName.rawValue)
    return ToolCallRecord(
      request: ToolCallRequest.invalid(
        raw: RawToolCallRequest(
          workspaceID: UUID(),
          sessionID: UUID(),
          toolName: toolName,
          arguments: [:]
        ),
        input: InvalidToolInput(
          originalName: toolName.rawValue,
          rawArguments: [:],
          reason: reason
        )
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: reason.message,
        riskLevel: .low
      ),
      state: .failed(
        .invalidTool(
          InvalidToolResult(originalName: toolName.rawValue, reason: reason)
        ))
    )
  }

  private func makeCompletedReadFileRecord() -> ToolCallRecord {
    makeReadFileRecord(
      state: .completed(
        .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "contents", truncated: false, redacted: false)
          )))
    )
  }

  private func makeReadFileRecord(state: ToolCallState) -> ToolCallRecord {
    makeReadFileRecord(input: ReadFileInput(path: "README.md"), state: state)
  }

  private func makeReadFileRecord(
    input: ReadFileInput,
    state: ToolCallState
  ) -> ToolCallRecord {
    var arguments: ToolCallArguments = ["path": .string(input.path)]
    if let offset = input.offset {
      arguments["offset"] = .number(Double(offset))
    }
    if let limit = input.limit {
      arguments["limit"] = .number(Double(limit))
    }
    let rawRequest = RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .readFile,
      arguments: arguments
    )
    let request = ToolCallRequest.validated(
      raw: rawRequest,
      payload: .readFile(input)
    )
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed in test.",
        riskLevel: .low
      ),
      state: state
    )
  }
}
