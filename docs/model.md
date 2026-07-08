```mermaid
classDiagram
  direction TB

  class WorkspaceLibrary {
    workspaces: [Workspace]
    activeWorkspaceID: Workspace.ID?
    activeSessionID: ChatSession.ID?
  }

  class Workspace {
    id: UUID
    name: String
    rootURL: URL
    bookmarkData: Data?
    sessions: [ChatSession]
    createdAt: Date
    updatedAt: Date
  }

  class ChatSession {
    id: UUID
    title: String
    selectedModelID: ManagedModel.ID
    turns: [ChatTurn]
    focusedFileState: FocusedFileState
    modeSettings: ChatModeSettingsSet
    interactionMode: WorkspaceInteractionMode
    todoState: TodoState?
    pendingAttachments: [ChatAttachment] transient
    activeAttachmentContext: ActiveAttachmentContext
    createdAt: Date
    updatedAt: Date
  }

  class ManagedModel {
    id: String
    displayName: String
    shortName: String
    summary: String
    detail: String
    huggingFaceRepoID: String
    localDirectoryName: String
    parameterSize: String
    estimatedDownloadSize: String
    isRecommended: Bool
    requiresLargeMemory: Bool
    stability: ManagedModelStability
    toolCallingPolicy: ToolCallingPolicy
    supportsImageInput: Bool
    reasoningTraceFormat: ReasoningTraceFormat
    defaultModeSettings: ChatModeSettingsSet
    defaultContextTokenLimit: Int
  }

  class ManagedModelStability {
    <<enum>>
    stable
    experimental
  }

  class ToolCallingPolicy {
    isEnabled: Bool
    allowsMultipleToolCalls: Bool
  }

  class ReasoningTraceFormat {
    <<enum>>
    none
    gemmaChannel
    qwenThinkTags
  }

  class ChatGenerationSettings {
    temperature: Double
    topP: Double
    topK: Int
    maxTokens: Int
    maxKVSize: Int?
    repetitionPenalty: Double
    reasoningEnabled: Bool
  }

  class ChatModeSettingsSet {
    chat: ChatModeSettings
    agent: ChatModeSettings
  }

  class ChatModeSettings {
    systemPrompt: String
    generationSettings: ChatGenerationSettings
  }

  class WorkspaceInteractionMode {
    <<enum>>
    chat
    agent
  }

  class ChatTurn {
    id: UUID
    status: ChatTurnStatus
    modelContextPolicy: ChatTurnModelContextPolicy
    items: [ChatTurnItem]
    createdAt: Date
    updatedAt: Date
  }

  class ChatTurnStatus {
    <<enum>>
    running
    awaitingApproval
    awaitingUserAnswer
    completed
    cancelled
    failed
  }

  class ChatTurnModelContextPolicy {
    <<enum>>
    included
    excluded
  }

  class ChatTurnItem {
    <<enum>>
    userMessage(UserTurnMessage)
    assistantMessage(AssistantTurnMessage)
    tool(ToolCallRecord)
  }

  class UserTurnMessage {
    id: UUID
    content: String
    attachments: [ChatAttachment]
    promptContext: CurrentPromptContext
  }

  class AssistantTurnMessage {
    id: UUID
    content: String
    modelProjectionPolicy: AssistantModelProjectionPolicy
    attachments: [ChatAttachment]
    generationMetrics: ChatGenerationMetrics?
    deliveryStatus: DeliveryStatus
  }

  class AssistantModelProjectionPolicy {
    <<enum>>
    visibleContent
    override(String)
    excluded
  }

  class DeliveryStatus {
    <<enum>>
    complete
    streaming
    cancelled
  }

  class ChatAttachment {
    id: AttachmentID
    displayName: String
    payload: ChatAttachmentPayload
    createdAt: Date
    kind: ChatAttachmentKind derived
  }

  class ChatAttachmentKind {
    <<enum>>
    text
    image
  }

  class ChatAttachmentPayload {
    <<enum>>
    text(TextAttachmentPayload)
    image(ImageAttachmentPayload)
  }

  class TextAttachmentPayload {
    content: String
    byteSize: Int
    contentSHA256: String
  }

  class ImageAttachmentPayload {
    mimeType: String
    byteSize: Int
    contentSHA256: String
  }

  class ActiveAttachmentContext {
    attachmentIDs: [AttachmentID]
  }

  class AttachmentID {
    UUID
  }

  class ChatGenerationMetrics {
    generatedTokenCount: Int
    tokensPerSecond: Double
    durationMs: Int
  }

  class TodoState {
    items: [TodoItem]
    updatedAt: Date
  }

  class TodoItem {
    id: String
    content: String
    status: TodoStatus
  }

  class TodoStatus {
    <<enum>>
    pending
    inProgress
    completed
    blocked
  }

  class ToolCallRecord {
    id: UUID derived
    request: ToolCallRequest
    evaluation: ToolPermissionEvaluation
    state: ToolCallState
  }

  class ToolCallRequest {
    id: UUID derived
    raw: RawToolCallRequest
    payload: ToolCallPayload
  }

  class RawToolCallRequest {
    id: UUID
    workspaceID: Workspace.ID
    sessionID: ChatSession.ID
    toolName: ToolName
    arguments: ToolCallArguments
    originalToolName: String?
    createdAt: Date
  }

  class ToolName {
    rawValue: String
  }

  class ToolArgumentValue {
    <<enum>>
    string(String)
    number(Double)
    bool(Bool)
    array([ToolArgumentValue])
    object([String: ToolArgumentValue])
    null
  }

  class ToolCallPayload {
    <<enum>>
    readFile(ReadFileInput)
    showFile(ReadFileInput)
    listFiles(ListFilesInput)
    globFiles(GlobFilesInput)
    searchFiles(SearchFilesInput)
    workspaceDiff(WorkspaceDiffInput)
    workspaceDiagnostics(WorkspaceDiagnosticsInput)
    writeFile(WriteFileInput)
    editFile(EditFileInput)
    runCommand(RunCommandInput)
    todoWrite(TodoWriteInput)
    askUser(AskUserInput)
    browserRefresh(BrowserRefreshInput)
    browserInspect(BrowserInspectInput)
    webSearch(WebSearchInput)
    webFetch(WebFetchInput)
    invalid(InvalidToolInput)
  }

  class ToolPermissionEvaluation {
    decision: ToolPermissionDecision
    reason: String
    riskLevel: ToolRiskLevel
    normalizedPaths: [String]
    workspaceRelativePaths: [WorkspaceRelativePath]
  }

  class ToolPermissionDecision {
    <<enum>>
    allowed
    requiresApproval
    denied
  }

  class ToolRiskLevel {
    <<enum>>
    low
    medium
    high
  }

  class ToolCallState {
    <<enum>>
    pending
    awaitingApproval(ToolResultPreview?)
    awaitingUserAnswer
    running
    completed(ToolResultPayload)
    denied(ToolResultPayload)
    failed(ToolResultPayload)
    cancelled
  }

  class ToolCallStatus {
    <<enum>>
    pending
    awaitingApproval
    awaitingUserAnswer
    denied
    running
    completed
    failed
    cancelled
  }

  class ToolResultPayload {
    <<enum>>
    readFile(ReadFileResult)
    listFiles(ListFilesResult)
    globFiles(GlobFilesResult)
    searchFiles(SearchFilesResult)
    workspaceDiff(WorkspaceDiffResult)
    workspaceDiagnostics(WorkspaceDiagnosticsResult)
    writeFile(WriteFileResult)
    editFile(EditFileResult)
    runCommand(RunCommandResult)
    todoWrite(TodoWriteResult)
    askUser(AskUserResult)
    browserRefresh(BrowserRefreshResult)
    browserInspect(BrowserInspectResult)
    webSearch(WebSearchToolResult)
    webFetch(WebFetchToolResult)
    invalidTool(InvalidToolResult)
    failure(ToolFailure)
  }

  class ToolResultPreview {
    status: ToolResultStatus
    text: String
    truncated: Bool
    redacted: Bool
    affectedPaths: [String]
  }

  class ToolResultStatus {
    <<enum>>
    success
    failed
    denied
  }

  class ModelPromptProjection {
    entries: [ModelContextEntry]
    projectedEntries(mode): [ProjectedModelContextEntry] derived
  }

  class ProjectedModelContextEntry {
    role: ModelContextRole
    content: String
    imageSignatures: [String]
  }

  class ModelContextEntry {
    id: UUID
    turnID: ChatTurn.ID?
    sourceMessageID: UUID?
    body: ModelContextEntryBody
    frozenContent: FrozenModelContent
  }

  class ModelContextEntryBody {
    <<enum>>
    userPrompt(UserPromptContext)
    assistantOutput(AssistantOutputContext)
    toolObservation(ToolObservationContext)
  }

  class UserPromptContext {
    prompt: String
    attachmentNames: [String]
    imageSignatures: [String]
    systemContext: [String]
    currentPromptContext: CurrentPromptContext?
  }

  class CurrentPromptContext {
    <<enum>>
    empty(ContextBudget)
    selected(CurrentPromptContextSelection)
  }

  class CurrentPromptContextSelection {
    blocks: NonEmptyPromptContextBlocks
    budget: ContextBudget
    truncation: PromptContextTruncation
  }

  class NonEmptyPromptContextBlocks {
    values: [PromptContextBlock]
  }

  class PromptContextBlock {
    <<enum>>
    attachedFile(AttachedFilePromptContext)
    focusedFile(FocusedFilePromptContext)
    ambiguousRecentFiles(AmbiguousRecentFilesPromptContext)
  }

  class ContextBudget {
    maxCharacters: Int
  }

  class PromptContextTruncation {
    <<enum>>
    none
    byCharacterBudget
  }

  class AssistantOutputContext {
    content: String
  }

  class ToolObservationContext {
    callID: UUID
    toolName: ToolName
    status: ToolResultStatus
    content: String
    toolReceipt: ToolReceipt?
    toolCall: ToolCallModelMessage?
    isTerminal: Bool
  }

  class ToolReceipt {
    callID: UUID
    toolName: ToolName
    status: ToolResultStatus
    affectedPaths: [WorkspaceRelativePath]
    summary: ToolReceiptSummary
    outputTruncated: Bool
    outputRedacted: Bool
  }

  class ToolReceiptSummary {
    text: String
    truncated: Bool
  }

  class ToolCallModelMessage {
    callID: UUID
    toolName: ToolName
    arguments: [ToolCallModelArgument]
    rawArguments: ToolCallArguments
  }

  class ToolCallModelArgument {
    name: String
    value: String
  }

  class FrozenModelContent {
    role: ModelContextRole
    content: String
    signature: String
  }

  class ModelContextRole {
    <<enum>>
    user
    assistant
  }

  class ModelContextDebugState {
    runtimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot?
  }

  class RuntimeCacheDebugSnapshot {
    generationID: UUID
    recordedAt: Date
    cacheMode: String
    cacheReason: String
    reuseStrategy: String
    appendDeltaStartIndex: Int?
    contextSignature: String
    previousContextSignature: String?
    appendOnly: Bool
    reusedMessageCount: Int
    appendedMessageCount: Int
    mismatchReason: String?
    firstMismatchIndex: Int?
    systemPromptChanged: Bool?
    currentPromptContextChanged: Bool?
  }

  class FocusedFileState {
    activePath: WorkspaceRelativePath?
    recentPaths: [FocusedPath]
    snapshots: [WorkspaceRelativePath: FocusedFileSnapshot]
    focusedAttachments: [AttachmentID]
  }

  class FocusedPath {
    path: WorkspaceRelativePath
    source: FocusedPathSource
    confidence: FocusConfidence
    updatedAt: Date
  }

  class FocusedPathSource {
    <<enum>>
    readFile
    writeFile
    editFile
    attachment
  }

  class FocusConfidence {
    <<enum>>
    active
    recent
    ambiguous
  }

  class FocusedFileSnapshot {
    contentHash: String
    excerpt: String?
    fullContentAvailable: Bool
    updatedAt: Date
  }

  class WorkspaceRelativePath {
    rawValue: String
  }

  WorkspaceLibrary "1" --> "*" Workspace
  Workspace "1" --> "*" ChatSession

  ChatSession "1" --> "*" ChatTurn : canonical turn records
  ChatSession ..> ModelPromptProjection : derived model input
  ChatSession "1" --> "1" FocusedFileState
  ChatSession "1" --> "1" ActiveAttachmentContext
  ChatSession "0..1" --> "1" TodoState
  ChatSession --> ManagedModel : selected model ID
  ChatSession --> ChatModeSettingsSet
  ChatSession --> WorkspaceInteractionMode
  ChatSession --> ChatAttachment : transient attachments

  ManagedModel --> ManagedModelStability
  ManagedModel --> ToolCallingPolicy
  ManagedModel --> ChatModeSettingsSet
  ChatModeSettingsSet --> ChatModeSettings
  ChatModeSettings --> ChatGenerationSettings

  ChatTurn "1" --> "*" ChatTurnItem : append-only membership
  ChatTurn --> ChatTurnStatus
  ChatTurn --> ChatTurnModelContextPolicy
  ChatTurnItem --> UserTurnMessage : embeds user
  ChatTurnItem --> AssistantTurnMessage : embeds assistant
  ChatTurnItem --> ToolCallRecord : embeds tool lifecycle
  UserTurnMessage --> ChatAttachment
  UserTurnMessage --> CurrentPromptContext
  AssistantTurnMessage --> ChatAttachment
  AssistantTurnMessage --> ChatGenerationMetrics
  AssistantTurnMessage --> DeliveryStatus
  AssistantTurnMessage --> AssistantModelProjectionPolicy

  ChatAttachment --> AttachmentID
  ChatAttachment --> ChatAttachmentKind
  ChatAttachment --> ChatAttachmentPayload
  ChatAttachmentPayload --> TextAttachmentPayload
  ChatAttachmentPayload --> ImageAttachmentPayload
  ActiveAttachmentContext --> AttachmentID

  TodoState "1" --> "*" TodoItem
  TodoItem --> TodoStatus

  ToolCallRecord "1" --> "1" ToolCallRequest
  ToolCallRecord "1" --> "1" ToolPermissionEvaluation
  ToolCallRecord "1" --> "1" ToolCallState
  ToolCallRequest --> RawToolCallRequest
  ToolCallRequest --> ToolCallPayload
  RawToolCallRequest --> ToolName
  RawToolCallRequest --> ToolArgumentValue
  ToolPermissionEvaluation --> ToolPermissionDecision
  ToolPermissionEvaluation --> ToolRiskLevel
  ToolPermissionEvaluation --> WorkspaceRelativePath
  ToolCallState --> ToolCallStatus : derived
  ToolCallState --> ToolResultPreview : approval preview
  ToolCallState --> ToolResultPayload : result payload
  ToolResultPayload --> ToolResultPreview : derived preview
  ToolResultPreview --> ToolResultStatus

  ModelPromptProjection "1" --> "*" ModelContextEntry
  ModelPromptProjection --> ProjectedModelContextEntry : derived projection
  ModelContextEntry --> ModelContextEntryBody
  ModelContextEntry --> FrozenModelContent
  ModelContextEntryBody --> UserPromptContext
  ModelContextEntryBody --> AssistantOutputContext
  ModelContextEntryBody --> ToolObservationContext
  UserPromptContext --> CurrentPromptContext
  UserPromptContext --> ModelContextRole : model role derived
  CurrentPromptContext --> CurrentPromptContextSelection
  CurrentPromptContextSelection --> NonEmptyPromptContextBlocks
  CurrentPromptContextSelection --> ContextBudget
  CurrentPromptContextSelection --> PromptContextTruncation
  NonEmptyPromptContextBlocks --> PromptContextBlock
  ToolObservationContext --> ToolName
  ToolObservationContext --> ToolResultStatus
  ToolObservationContext --> ToolReceipt
  ToolObservationContext --> ToolCallModelMessage
  ToolReceipt --> ToolName
  ToolReceipt --> ToolResultStatus
  ToolReceipt --> WorkspaceRelativePath
  ToolReceipt --> ToolReceiptSummary
  ToolCallModelMessage --> ToolName
  ToolCallModelMessage --> ToolCallModelArgument
  ToolCallModelMessage --> ToolArgumentValue
  FrozenModelContent --> ModelContextRole
  ProjectedModelContextEntry --> ModelContextRole
  ModelContextDebugState --> RuntimeCacheDebugSnapshot

  FocusedFileState --> WorkspaceRelativePath
  FocusedFileState --> FocusedPath
  FocusedFileState --> FocusedFileSnapshot
  FocusedFileState --> AttachmentID
  FocusedPath --> WorkspaceRelativePath
  FocusedPath --> FocusedPathSource
  FocusedPath --> FocusConfidence
```
