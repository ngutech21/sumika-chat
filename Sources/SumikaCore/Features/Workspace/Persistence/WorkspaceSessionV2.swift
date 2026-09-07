import Foundation

/// Frozen v2 session envelope and tagged tool decoding. Unchanged leaf value types
/// are shared; new tool variants must never become valid v2 migration input.
struct WorkspaceSessionDocumentV2: Decodable {
  let version: Int
  let session: WorkspaceSessionV2
}

struct WorkspaceSessionV2: Decodable {
  let id: UUID
  let title: String
  let selectedModelID: ManagedModel.ID
  let turns: [WorkspaceTurnV2]
  let focusedFileState: FocusedFileState
  let modeSettings: ChatModeSettingsSet
  let interactionMode: WorkspaceInteractionMode
  let toolApprovalPolicy: ToolApprovalPolicy
  let selectedMCPServerIDs: [UUID]
  let todoState: TodoState?
  let createdAt: Date
  let updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, title, selectedModelID, turns, focusedFileState, modeSettings
    case interactionMode, toolApprovalPolicy, selectedMCPServerIDs, todoState
    case createdAt, updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    title = try container.decodeIfPresent(String.self, forKey: .title, default: "New Session")
    selectedModelID = try container.decodeIfPresent(
      String.self, forKey: .selectedModelID, default: "gemma4-12b-qat-4bit")
    turns = try container.decodeLossyArray([WorkspaceTurnV2].self, forKey: .turns)
    focusedFileState = try container.decodeIfPresent(
      FocusedFileState.self, forKey: .focusedFileState, default: .empty)
    modeSettings = try container.decodeIfPresent(
      ChatModeSettingsSet.self, forKey: .modeSettings, default: .defaultSettings)
    interactionMode = try container.decodeIfPresent(
      WorkspaceInteractionMode.self, forKey: .interactionMode, default: .chat)
    toolApprovalPolicy = try container.decodeIfPresent(
      ToolApprovalPolicy.self, forKey: .toolApprovalPolicy, default: .manual)
    selectedMCPServerIDs = try container.decodeIfPresent(
      [UUID].self, forKey: .selectedMCPServerIDs, default: [])
    todoState = try container.decodeIfPresent(TodoState.self, forKey: .todoState)
    createdAt = try container.decodeIfPresent(
      Date.self, forKey: .createdAt, default: decoder.defaultDate)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt, default: createdAt)
  }

  var value: ChatSession {
    ChatSession(
      id: id, title: title, selectedModelID: selectedModelID,
      turns: turns.map { item in
        var turn = item.value
        turn.markStreamingAssistantMessagesCancelled(at: turn.updatedAt)
        return turn
      },
      focusedFileState: focusedFileState, modeSettings: modeSettings,
      interactionMode: interactionMode, toolApprovalPolicy: toolApprovalPolicy,
      selectedMCPServerIDs: selectedMCPServerIDs, todoState: todoState,
      createdAt: createdAt, updatedAt: updatedAt
    )
  }
}

struct WorkspaceTurnV2: Decodable {
  let id: UUID
  let status: ChatTurnStatus
  let modelContextPolicy: ChatTurnModelContextPolicy
  let items: [WorkspaceTurnItemV2]
  let createdAt: Date
  let updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, status, modelContextPolicy, items, createdAt, updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    status = try container.decodeIfPresent(
      ChatTurnStatus.self, forKey: .status, default: .completed)
    modelContextPolicy = try container.decodeIfPresent(
      ChatTurnModelContextPolicy.self, forKey: .modelContextPolicy, default: .included)
    items = try container.decodeLossyArray([WorkspaceTurnItemV2].self, forKey: .items)
    createdAt = try container.decodeIfPresent(
      Date.self, forKey: .createdAt, default: decoder.defaultDate)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt, default: createdAt)
  }

  var value: ChatTurn {
    ChatTurn(
      id: id, status: status, modelContextPolicy: modelContextPolicy,
      items: items.map(\.value), createdAt: createdAt, updatedAt: updatedAt)
  }
}

private struct WorkspaceToolRecordV2: Decodable {
  let request: WorkspaceToolRequestV2
  let evaluation: ToolPermissionEvaluation
  let state: WorkspaceToolStateV2
  let approvalSource: ToolApprovalSource?
  let modelFollowUpNotice: String?

  var value: ToolCallRecord {
    ToolCallRecord(
      request: request.value, evaluation: evaluation, state: state.value,
      approvalSource: approvalSource, modelFollowUpNotice: modelFollowUpNotice)
  }
}

private struct WorkspaceToolRequestV2: Decodable {
  let value: ToolCallRequest
  private enum CodingKeys: String, CodingKey { case raw, payload }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decode(RawToolCallRequest.self, forKey: .raw)
    let payload = try container.decode(WorkspaceToolInputV2.self, forKey: .payload).value
    guard payload.matches(raw.toolName) else {
      throw DecodingError.dataCorruptedError(
        forKey: .payload, in: container,
        debugDescription: "Mismatched v2 tool request.")
    }
    value = .validated(raw: raw, payload: payload)
  }
}

private struct WorkspaceToolPreviewV2: Decodable {
  let status: ToolResultStatus
  let text: String
  let truncated: Bool
  let redacted: Bool
  let affectedPaths: [String]
  let resultPayload: WorkspaceToolResultV2?

  private enum CodingKeys: String, CodingKey {
    case status, text, truncated, redacted, affectedPaths, resultPayload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decodeIfPresent(
      ToolResultStatus.self, forKey: .status, default: .success)
    text = try container.decodeIfPresent(String.self, forKey: .text, default: "")
    truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated, default: false)
    redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted, default: false)
    affectedPaths = try container.decodeIfPresent(
      [String].self, forKey: .affectedPaths, default: [])
    resultPayload = try container.decodeIfPresent(
      WorkspaceToolResultV2.self, forKey: .resultPayload)
  }

  var value: ToolResultPreview {
    ToolResultPreview(
      status: status, text: text, truncated: truncated, redacted: redacted,
      affectedPaths: affectedPaths.map(WorkspaceRelativePath.init(rawValue:)),
      resultPayload: resultPayload?.value)
  }
}

struct WorkspaceTurnItemV2: Decodable {
  let value: ChatTurnItem

  private enum CodingKeys: String, CodingKey {
    case kind
    case payload
  }

  private enum Kind: String, Codable {
    case userMessage
    case assistantThinking
    case assistantMessage
    case tool
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .userMessage:
      value = .userMessage(try container.decode(UserTurnMessage.self, forKey: .payload))
    case .assistantThinking:
      value = .assistantThinking(
        try container.decode(AssistantThinkingMessage.self, forKey: .payload)
      )
    case .assistantMessage:
      value = .assistantMessage(try container.decode(AssistantTurnMessage.self, forKey: .payload))
    case .tool:
      value = .tool(try container.decode(WorkspaceToolRecordV2.self, forKey: .payload).value)
    }
  }

}

private struct WorkspaceToolStateV2: Decodable {
  let value: ToolCallState

  private enum CodingKeys: String, CodingKey {
    case kind
    case preview
    case payload
  }

  private enum Kind: String, Codable {
    case pending
    case awaitingApproval
    case awaitingUserAnswer
    case running
    case completed
    case denied
    case failed
    case cancelled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .pending:
      value = .pending
    case .awaitingApproval:
      value = .awaitingApproval(
        preview: try container.decodeIfPresent(WorkspaceToolPreviewV2.self, forKey: .preview)?.value
      )
    case .awaitingUserAnswer:
      value = .awaitingUserAnswer
    case .running:
      value = .running
    case .completed:
      value = .completed(try container.decode(WorkspaceToolResultV2.self, forKey: .payload).value)
    case .denied:
      value = .denied(try container.decode(WorkspaceToolResultV2.self, forKey: .payload).value)
    case .failed:
      value = .failed(try container.decode(WorkspaceToolResultV2.self, forKey: .payload).value)
    case .cancelled:
      value = .cancelled
    }
  }

}

private struct WorkspaceToolInputV2: Decodable {
  let value: ToolCallPayload

  private enum CodingKeys: String, CodingKey {
    case kind
    case payload
  }

  private enum Kind: String, Codable {
    case readDocument
    case readFile
    case readSkillResource
    case showFile
    case listFiles
    case globFiles
    case searchFiles
    case workspaceDiff
    case workspaceDiagnostics
    case writeFile
    case editFile
    case runCommand
    case todoWrite
    case askUser
    case finishTask
    case browserRefresh
    case browserInspect
    case webSearch
    case webFetch
    case mcp
    case invalid
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .readDocument:
      value = .readDocument(try container.decode(ReadDocumentInput.self, forKey: .payload))
    case .readFile:
      value = .readFile(try container.decode(ReadFileInput.self, forKey: .payload))
    case .readSkillResource:
      value = .readSkillResource(
        try container.decode(ReadSkillResourceInput.self, forKey: .payload)
      )
    case .showFile:
      value = .showFile(try container.decode(ReadFileInput.self, forKey: .payload))
    case .listFiles:
      value = .listFiles(try container.decode(ListFilesInput.self, forKey: .payload))
    case .globFiles:
      value = .globFiles(try container.decode(GlobFilesInput.self, forKey: .payload))
    case .searchFiles:
      value = .searchFiles(try container.decode(SearchFilesInput.self, forKey: .payload))
    case .workspaceDiff:
      value = .workspaceDiff(try container.decode(WorkspaceDiffInput.self, forKey: .payload))
    case .workspaceDiagnostics:
      value = .workspaceDiagnostics(
        try container.decode(WorkspaceDiagnosticsInput.self, forKey: .payload)
      )
    case .writeFile:
      value = .writeFile(try container.decode(WriteFileInput.self, forKey: .payload))
    case .editFile:
      value = .editFile(try container.decode(EditFileInput.self, forKey: .payload))
    case .runCommand:
      value = .runCommand(try container.decode(RunCommandInput.self, forKey: .payload))
    case .todoWrite:
      value = .todoWrite(try container.decode(TodoWriteInput.self, forKey: .payload))
    case .askUser:
      value = .askUser(try container.decode(AskUserInput.self, forKey: .payload))
    case .finishTask:
      value = .finishTask(try container.decode(FinishTaskInput.self, forKey: .payload))
    case .browserRefresh:
      value = .browserRefresh(try container.decode(BrowserRefreshInput.self, forKey: .payload))
    case .browserInspect:
      value = .browserInspect(try container.decode(BrowserInspectInput.self, forKey: .payload))
    case .webSearch:
      value = .webSearch(try container.decode(WebSearchInput.self, forKey: .payload))
    case .webFetch:
      value = .webFetch(try container.decode(WebFetchInput.self, forKey: .payload))
    case .mcp:
      value = .mcp(try container.decode(MCPToolInput.self, forKey: .payload))
    case .invalid:
      value = .invalid(try container.decode(InvalidToolInput.self, forKey: .payload))
    }
  }

}

private struct WorkspaceToolResultV2: Decodable {
  let value: ToolResultPayload

  private enum CodingKeys: String, CodingKey {
    case kind
    case payload
  }

  private enum Kind: String, Codable {
    case readDocument
    case readFile
    case readSkillResource
    case listFiles
    case globFiles
    case searchFiles
    case workspaceDiff
    case workspaceDiagnostics
    case writeFile
    case editFile
    case runCommand
    case todoWrite
    case askUser
    case finishTask
    case browserRefresh
    case browserInspect
    case webSearch
    case webFetch
    case mcp
    case duplicateToolCall
    case invalidTool
    case failure
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .readDocument:
      value = .readDocument(try container.decode(ReadDocumentResult.self, forKey: .payload))
    case .readFile:
      value = .readFile(try container.decode(ReadFileResult.self, forKey: .payload))
    case .readSkillResource:
      value = .readSkillResource(
        try container.decode(ReadSkillResourceResult.self, forKey: .payload)
      )
    case .listFiles:
      value = .listFiles(try container.decode(ListFilesResult.self, forKey: .payload))
    case .globFiles:
      value = .globFiles(try container.decode(GlobFilesResult.self, forKey: .payload))
    case .searchFiles:
      value = .searchFiles(try container.decode(SearchFilesResult.self, forKey: .payload))
    case .workspaceDiff:
      value = .workspaceDiff(
        try container.decode(WorkspaceDiffResultV3.self, forKey: .payload).value)
    case .workspaceDiagnostics:
      value = .workspaceDiagnostics(
        try container.decode(WorkspaceDiagnosticsResult.self, forKey: .payload)
      )
    case .writeFile:
      value = .writeFile(try container.decode(WriteFileResult.self, forKey: .payload))
    case .editFile:
      value = .editFile(try container.decode(EditFileResult.self, forKey: .payload))
    case .runCommand:
      value = .runCommand(try container.decode(RunCommandResult.self, forKey: .payload))
    case .todoWrite:
      value = .todoWrite(try container.decode(TodoWriteResult.self, forKey: .payload))
    case .askUser:
      value = .askUser(try container.decode(AskUserResult.self, forKey: .payload))
    case .finishTask:
      value = .finishTask(try container.decode(FinishTaskResult.self, forKey: .payload))
    case .browserRefresh:
      value = .browserRefresh(try container.decode(BrowserRefreshResult.self, forKey: .payload))
    case .browserInspect:
      value = .browserInspect(try container.decode(BrowserInspectResult.self, forKey: .payload))
    case .webSearch:
      value = .webSearch(try container.decode(WebSearchToolResult.self, forKey: .payload))
    case .webFetch:
      value = .webFetch(try container.decode(WebFetchToolResult.self, forKey: .payload))
    case .mcp:
      value = .mcp(try container.decode(MCPToolResult.self, forKey: .payload))
    case .duplicateToolCall:
      value = .duplicateToolCall(
        try container.decode(DuplicateToolCallResult.self, forKey: .payload)
      )
    case .invalidTool:
      value = .invalidTool(try container.decode(InvalidToolResult.self, forKey: .payload))
    case .failure:
      value = .failure(try container.decode(ToolFailure.self, forKey: .payload))
    }
  }

}
