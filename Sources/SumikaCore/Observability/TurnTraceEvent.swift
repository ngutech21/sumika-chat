import Foundation

package enum TurnTracePhase: String, Codable, CaseIterable, Equatable, Sendable {
  case contextBuild = "context_build"
  case tokenizeContextUsage = "tokenize_context_usage"
  case renderSystemPrompt = "render_system_prompt"
  case runtimeStreamStart = "runtime_stream_start"
  case runtimeTTFT = "runtime_ttft"
  case runtimeDecode = "runtime_decode"
  case runtimePartialDecode = "runtime_partial_decode"
  case toolParse = "tool_parse"
  case toolExecute = "tool_execute"
  case uiFlush = "ui_flush"
  case persist
  case memoryClear = "memory_clear"
}

package struct TurnTraceEvent: Codable, Equatable, Sendable {
  package let turnID: UUID?
  package let generationID: UUID?
  package let phase: TurnTracePhase
  package let durationMs: Double
  package let promptBytes: Int?
  package let promptTokens: Int?
  package let messageCount: Int?
  package let toolLoopIteration: Int?
  package let toolName: String?
  package let ttftMs: Double?
  package let tokensPerSecond: Double?
  package let cacheMode: String?
  package let cacheReason: String?
  package let memoryClearReason: String?
  package let interactionMode: WorkspaceInteractionMode?
  package let selectedMCPServerIDs: [UUID]?
  package let activeMCPToolCount: Int?
  package let contextSignature: String?
  package let previousContextSignature: String?
  package let appendOnly: Bool?
  package let reusedMessageCount: Int?
  package let appendedMessageCount: Int?
  package let mismatchReason: String?
  package let firstMismatchIndex: Int?
  package let systemPromptChanged: Bool?
  package let currentPromptContextChanged: Bool?
  package let toolCallFormat: String?
  package let toolValidationStatus: String?
  package let toolValidationError: String?
  package let toolOriginalName: String?
  package let toolArgumentKeys: [String]?
  package let toolArguments: [ToolArgumentTrace]?
  package let imageCount: Int?
  package let imageTypes: [String]?
  package let imageByteCount: Int?

  package init(
    turnID: UUID? = nil,
    generationID: UUID? = nil,
    phase: TurnTracePhase,
    durationMs: Double,
    promptBytes: Int? = nil,
    promptTokens: Int? = nil,
    messageCount: Int? = nil,
    toolLoopIteration: Int? = nil,
    toolName: String? = nil,
    ttftMs: Double? = nil,
    tokensPerSecond: Double? = nil,
    cacheMode: String? = nil,
    cacheReason: String? = nil,
    memoryClearReason: String? = nil,
    interactionMode: WorkspaceInteractionMode? = nil,
    selectedMCPServerIDs: [UUID]? = nil,
    activeMCPToolCount: Int? = nil,
    contextSignature: String? = nil,
    previousContextSignature: String? = nil,
    appendOnly: Bool? = nil,
    reusedMessageCount: Int? = nil,
    appendedMessageCount: Int? = nil,
    mismatchReason: String? = nil,
    firstMismatchIndex: Int? = nil,
    systemPromptChanged: Bool? = nil,
    currentPromptContextChanged: Bool? = nil,
    toolCallFormat: String? = nil,
    toolValidationStatus: String? = nil,
    toolValidationError: String? = nil,
    toolOriginalName: String? = nil,
    toolArgumentKeys: [String]? = nil,
    toolArguments: [ToolArgumentTrace]? = nil,
    imageCount: Int? = nil,
    imageTypes: [String]? = nil,
    imageByteCount: Int? = nil
  ) {
    self.turnID = turnID
    self.generationID = generationID
    self.phase = phase
    self.durationMs = durationMs
    self.promptBytes = promptBytes
    self.promptTokens = promptTokens
    self.messageCount = messageCount
    self.toolLoopIteration = toolLoopIteration
    self.toolName = toolName
    self.ttftMs = ttftMs
    self.tokensPerSecond = tokensPerSecond
    self.cacheMode = cacheMode
    self.cacheReason = cacheReason
    self.memoryClearReason = memoryClearReason
    self.interactionMode = interactionMode
    self.selectedMCPServerIDs = selectedMCPServerIDs
    self.activeMCPToolCount = activeMCPToolCount
    self.contextSignature = contextSignature
    self.previousContextSignature = previousContextSignature
    self.appendOnly = appendOnly
    self.reusedMessageCount = reusedMessageCount
    self.appendedMessageCount = appendedMessageCount
    self.mismatchReason = mismatchReason
    self.firstMismatchIndex = firstMismatchIndex
    self.systemPromptChanged = systemPromptChanged
    self.currentPromptContextChanged = currentPromptContextChanged
    self.toolCallFormat = toolCallFormat
    self.toolValidationStatus = toolValidationStatus
    self.toolValidationError = toolValidationError
    self.toolOriginalName = toolOriginalName
    self.toolArgumentKeys = toolArgumentKeys
    self.toolArguments = toolArguments
    self.imageCount = imageCount
    self.imageTypes = imageTypes
    self.imageByteCount = imageByteCount
  }
}

package struct ToolArgumentTrace: Codable, Equatable, Sendable {
  package let name: String
  package let valueType: String
  package let preview: String
  package let previewTruncated: Bool

  package init(
    name: String,
    valueType: String,
    preview: String,
    previewTruncated: Bool
  ) {
    self.name = name
    self.valueType = valueType
    self.preview = preview
    self.previewTruncated = previewTruncated
  }
}

package protocol TurnTracing: Sendable {
  func recordTurnTraceEvent(_ event: TurnTraceEvent) async
}

package struct NoopTurnTracer: TurnTracing {
  package init() {}

  package func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    _ = event
  }
}

package struct TurnTraceMetadata: Sendable {
  package let turnID: UUID?
  package let generationID: UUID
  package let tracer: any TurnTracing
  package let toolLoopIteration: Int?
  package let interactionMode: WorkspaceInteractionMode?

  package init(
    turnID: UUID?,
    generationID: UUID,
    tracer: any TurnTracing,
    toolLoopIteration: Int? = nil,
    interactionMode: WorkspaceInteractionMode? = nil
  ) {
    self.turnID = turnID
    self.generationID = generationID
    self.tracer = tracer
    self.toolLoopIteration = toolLoopIteration
    self.interactionMode = interactionMode
  }
}

package enum TurnTraceContext {
  @TaskLocal public static var current: TurnTraceMetadata?
}
