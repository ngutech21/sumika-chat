```mermaid
classDiagram
  direction TB

  class WorkspaceLibrary {
    workspaces: [Workspace]
    activeWorkspaceID
    activeSessionID
  }

  class Workspace {
    id
    name
    rootURL
    sessions: [ChatSession]
  }

  class ChatSession {
    id
    title
    selectedModelID
    transcript: ChatTranscriptState
  }

  class ChatTranscriptState {
    turns: [ChatTurn]
    toolCalls: [ToolCallRecord]
    modelFacingTranscript: ModelFacingTranscript
    focusedFileState: FocusedFileState
    systemPrompt
    generationSettings
    interactionMode
  }

  class ChatTurn {
    id
    status
    modelContextPolicy
    items: [ChatTurnItem]
  }

  class ChatTurnItem {
    <<enum>>
    userMessage(UserTurnMessage)
    assistantMessage(AssistantTurnMessage)
    toolCall(ToolCallRecord.ID)
    toolResult(ToolCallRecord.ID)
  }

  class UserTurnMessage {
    id
    content
    attachments: [ChatAttachment]
  }

  class AssistantTurnMessage {
    id
    content
    attachments: [ChatAttachment]
    generationMetrics
    deliveryStatus
  }

  class ToolCallRecord {
    id
    request: ToolCallRequest
    evaluation: ToolPermissionEvaluation
    state: ToolCallState
    events: [ToolCallEvent]
  }

  class ToolCallRequest {
    raw request
    typed payload
  }

  class ToolCallState {
    <<enum>>
    pending
    awaitingApproval
    approved
    running
    completed(ResultPayload)
    denied(ResultPayload)
    failed(ResultPayload)
    cancelled
  }

  class ModelFacingTranscript {
    entries: [ModelContextEntry]
    prompt snapshot
  }

  class FocusedFileState {
    activePath
    recentPaths
    snapshotsByPath
  }

  WorkspaceLibrary "1" --> "*" Workspace
  Workspace "1" --> "*" ChatSession
  ChatSession "1" --> "1" ChatTranscriptState

  ChatTranscriptState "1" --> "*" ChatTurn : canonical order
  ChatTranscriptState "1" --> "*" ToolCallRecord : canonical tool lifecycle
  ChatTranscriptState "1" --> "1" ModelFacingTranscript : persisted prompt snapshot
  ChatTranscriptState "1" --> "1" FocusedFileState

  ChatTurn "1" --> "*" ChatTurnItem
  ChatTurnItem --> UserTurnMessage : embeds user
  ChatTurnItem --> AssistantTurnMessage : embeds assistant
  ChatTurnItem ..> ToolCallRecord : references by ID

  ToolCallRecord "1" --> "1" ToolCallRequest
  ToolCallRecord "1" --> "1" ToolCallState
```
