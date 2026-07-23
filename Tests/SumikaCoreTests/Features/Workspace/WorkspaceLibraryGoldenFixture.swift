import Foundation

@testable import SumikaCore

/// Deterministic full-coverage workspace library used by the persisted-schema
/// golden tests. Every UUID and Date is fixed so encoding the library always
/// produces byte-identical JSON.
///
/// Keep this builder in sync with the persisted schema on purpose: when a
/// schema change breaks the golden test, update the builder and regenerate the
/// fixture via `SUMIKA_REGENERATE_FIXTURES=1 xcrun swift test`.
enum WorkspaceLibraryGoldenFixture {
  static let workspaceID = fixedUUID("AAAAAAAA-0000-0000-0000-000000000001")
  static let chatSessionID = fixedUUID("BBBBBBBB-0000-0000-0000-000000000001")
  static let agentSessionID = fixedUUID("BBBBBBBB-0000-0000-0000-000000000002")
  static let assistantMessageID = fixedUUID("CCCCCCCC-0000-0000-0000-000000000003")
  static let completedToolCallID = fixedUUID("DDDDDDDD-0000-0000-0000-000000000001")
  static let awaitingToolCallID = fixedUUID("DDDDDDDD-0000-0000-0000-000000000002")
  static let deniedToolCallID = fixedUUID("DDDDDDDD-0000-0000-0000-000000000003")
  static let failedToolCallID = fixedUUID("DDDDDDDD-0000-0000-0000-000000000004")
  static let cancelledToolCallID = fixedUUID("DDDDDDDD-0000-0000-0000-000000000005")

  static func makeLibrary() -> WorkspaceLibrary {
    let workspace = Workspace(
      id: workspaceID,
      name: "Golden Project",
      rootURL: URL(filePath: "/tmp/golden-project", directoryHint: .isDirectory),
      bookmarkData: Data([1, 2, 3, 4]),
      sessions: [makeChatSession(), makeAgentSession()],
      createdAt: date(1_000),
      updatedAt: date(9_000)
    )
    return WorkspaceLibrary(
      workspaces: [workspace],
      activeWorkspaceID: workspaceID,
      activeSessionID: agentSessionID
    )
  }

  /// Minimal chat-mode session: one completed user/assistant exchange.
  private static func makeChatSession() -> ChatSession {
    ChatSession(
      id: chatSessionID,
      title: "Chat Session",
      selectedModelID: "gemma4-12b-qat-4bit",
      turns: [
        ChatTurn(
          id: fixedUUID("EEEEEEEE-0000-0000-0000-000000000001"),
          status: .completed,
          items: [
            .userMessage(
              UserTurnMessage(
                id: fixedUUID("CCCCCCCC-0000-0000-0000-000000000001"),
                content: "Hello",
                attachments: [
                  ChatAttachment(
                    id: fixedUUID("CCCCCCCC-0000-0000-0000-00000000000A"),
                    displayName: "notes.txt",
                    payload: .text(
                      TextAttachmentPayload(
                        content: "attached text",
                        byteSize: 13,
                        contentSHA256: "fixed-hash"
                      )
                    ),
                    createdAt: date(2_000)
                  )
                ]
              )
            ),
            .assistantThinking(
              AssistantThinkingMessage(
                id: fixedUUID("CCCCCCCC-0000-0000-0000-000000000002"),
                content: "Considering a greeting.",
                deliveryStatus: .complete,
                startedAt: date(2_100),
                completedAt: date(2_200)
              )
            ),
            .assistantMessage(
              AssistantTurnMessage(
                id: assistantMessageID,
                content: "Hi there!",
                generationMetrics: ChatGenerationMetrics(
                  generatedTokenCount: 5,
                  tokensPerSecond: 42.5
                ),
                deliveryStatus: .complete,
                modelProjectionPolicy: .override("Hi!")
              )
            ),
          ],
          createdAt: date(2_000),
          updatedAt: date(2_300)
        )
      ],
      focusedFileState: .empty,
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(systemPrompt: "Chat prompt", generationSettings: .chatDefault),
        agent: ChatModeSettings(systemPrompt: "Agent prompt", generationSettings: .agentDefault)
      ),
      interactionMode: .chat,
      createdAt: date(1_500),
      updatedAt: date(2_400)
    )
  }

  /// Agent-mode session covering every persisted tool-call state.
  private static func makeAgentSession() -> ChatSession {
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    return ChatSession(
      id: agentSessionID,
      title: "Agent Session",
      selectedModelID: "gemma4-12b-qat-4bit",
      turns: [
        ChatTurn(
          id: fixedUUID("EEEEEEEE-0000-0000-0000-000000000002"),
          status: .awaitingApproval,
          modelContextPolicy: .included,
          items: [
            .userMessage(
              UserTurnMessage(
                id: fixedUUID("CCCCCCCC-0000-0000-0000-000000000004"),
                content: "Update the app file"
              )
            ),
            .tool(makeCompletedReadFileRecord()),
            .tool(makeAwaitingApprovalWriteFileRecord()),
            .tool(makeDeniedRunCommandRecord()),
            .tool(makeFailedEditFileRecord(path: path)),
            .tool(makeCancelledSearchRecord()),
          ],
          createdAt: date(5_000),
          updatedAt: date(6_000)
        )
      ],
      focusedFileState: FocusedFileState(
        activePath: path,
        recentPaths: [
          FocusedPath(
            path: path,
            source: .editFile,
            confidence: .active,
            updatedAt: date(5_500)
          )
        ],
        snapshots: [
          path: FocusedFileSnapshot(
            contentHash: "abc123",
            excerpt: "struct App {}",
            fullContentAvailable: true,
            updatedAt: date(5_600)
          )
        ]
      ),
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(systemPrompt: "Chat prompt", generationSettings: .chatDefault),
        agent: ChatModeSettings(systemPrompt: "Agent prompt", generationSettings: .agentDefault)
      ),
      interactionMode: .agent,
      todoState: TodoState(
        items: [
          TodoItem(id: "read", content: "Read the file", status: .completed),
          TodoItem(id: "edit", content: "Apply the change", status: .inProgress),
        ],
        updatedAt: date(5_900)
      ),
      createdAt: date(4_000),
      updatedAt: date(6_500)
    )
  }

  private static func makeCompletedReadFileRecord() -> ToolCallRecord {
    ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          id: completedToolCallID,
          workspaceID: workspaceID,
          sessionID: agentSessionID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")],
          createdAt: date(5_010)
        ),
        payload: .readFile(ReadFileInput(path: "README.md"))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: ["/tmp/golden-project/README.md"],
        workspaceRelativePaths: [WorkspaceRelativePath(rawValue: "README.md")]
      ),
      state: .completed(
        .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "# Golden", truncated: false, redacted: false)
          )
        )
      )
    )
  }

  private static func makeAwaitingApprovalWriteFileRecord() -> ToolCallRecord {
    ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          id: awaitingToolCallID,
          workspaceID: workspaceID,
          sessionID: agentSessionID,
          toolName: .writeFile,
          arguments: [
            "path": .string("Sources/App.swift"),
            "content": .string("struct App {}"),
          ],
          createdAt: date(5_020)
        ),
        payload: .writeFile(WriteFileInput(path: "Sources/App.swift", content: "struct App {}"))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Writing files inside the workspace requires approval.",
        riskLevel: .high,
        normalizedPaths: ["/tmp/golden-project/Sources/App.swift"],
        workspaceRelativePaths: [WorkspaceRelativePath(rawValue: "Sources/App.swift")]
      ),
      state: .awaitingApproval(
        preview: ToolResultPreview(
          text: "Write 13 bytes to Sources/App.swift.",
          affectedPaths: ["Sources/App.swift"]
        )
      )
    )
  }

  private static func makeDeniedRunCommandRecord() -> ToolCallRecord {
    ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          id: deniedToolCallID,
          workspaceID: workspaceID,
          sessionID: agentSessionID,
          toolName: .runCommand,
          arguments: ["command": .string("rm -rf build")],
          createdAt: date(5_030)
        ),
        payload: .runCommand(RunCommandInput(command: "rm -rf build", timeoutSeconds: 120))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Shell commands require approval.",
        riskLevel: .high
      ),
      state: .denied(
        .failure(
          ToolFailure(
            toolName: .runCommand,
            path: nil,
            reason: .permissionDenied
          )
        )
      ),
      modelFollowUpNotice: "The user denied run_command."
    )
  }

  private static func makeFailedEditFileRecord(path: WorkspaceRelativePath) -> ToolCallRecord {
    ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          id: failedToolCallID,
          workspaceID: workspaceID,
          sessionID: agentSessionID,
          toolName: .editFile,
          arguments: [
            "path": .string(path.rawValue),
            "old_text": .string("struct Old {}"),
            "new_text": .string("struct App {}"),
          ],
          createdAt: date(5_040)
        ),
        payload: .editFile(
          EditFileInput(path: path.rawValue, oldText: "struct Old {}", newText: "struct App {}")
        )
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Editing files inside the workspace requires approval.",
        riskLevel: .medium,
        workspaceRelativePaths: [path]
      ),
      state: .failed(
        .failure(
          ToolFailure(
            toolName: .editFile,
            path: path,
            reason: .executionError("old_text not found"),
            recovery: .readFile(path: path)
          )
        )
      )
    )
  }

  private static func makeCancelledSearchRecord() -> ToolCallRecord {
    ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          id: cancelledToolCallID,
          workspaceID: workspaceID,
          sessionID: agentSessionID,
          toolName: .searchFiles,
          arguments: ["pattern": .string("TODO")],
          createdAt: date(5_050)
        ),
        payload: .searchFiles(SearchFilesInput(pattern: "TODO", path: nil, include: nil))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Searching files inside the workspace is allowed.",
        riskLevel: .low
      ),
      state: .cancelled
    )
  }

  private static func date(_ seconds: Double) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  private static func fixedUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
      preconditionFailure("Invalid fixture UUID: \(value)")
    }
    return uuid
  }
}
