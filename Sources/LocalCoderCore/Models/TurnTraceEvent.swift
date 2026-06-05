import Foundation

public enum TurnTracePhase: String, Codable, CaseIterable, Equatable, Sendable {
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

public struct TurnTraceEvent: Codable, Equatable, Sendable {
  public let turnID: UUID?
  public let generationID: UUID?
  public let phase: TurnTracePhase
  public let durationMs: Double
  public let promptBytes: Int?
  public let promptTokens: Int?
  public let messageCount: Int?
  public let toolLoopIteration: Int?
  public let toolName: String?
  public let ttftMs: Double?
  public let tokensPerSecond: Double?
  public let cacheMode: String?
  public let cacheReason: String?
  public let interactionMode: WorkspaceInteractionMode?
  public let contextSignature: String?
  public let previousContextSignature: String?
  public let appendOnly: Bool?
  public let reusedMessageCount: Int?
  public let appendedMessageCount: Int?
  public let mismatchReason: String?
  public let firstMismatchIndex: Int?
  public let systemPromptChanged: Bool?
  public let currentPromptContextChanged: Bool?
  public let toolCallFormat: String?
  public let toolValidationStatus: String?
  public let toolValidationError: String?
  public let toolOriginalName: String?
  public let toolArgumentKeys: [String]?
  public let toolArguments: [ToolArgumentTrace]?

  public init(
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
    interactionMode: WorkspaceInteractionMode? = nil,
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
    toolArguments: [ToolArgumentTrace]? = nil
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
    self.interactionMode = interactionMode
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
  }
}

public struct ToolArgumentTrace: Codable, Equatable, Sendable {
  public let name: String
  public let valueType: String
  public let preview: String
  public let previewTruncated: Bool

  public init(
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

public protocol TurnTracing: Sendable {
  func recordTurnTraceEvent(_ event: TurnTraceEvent) async
}

public struct NoopTurnTracer: TurnTracing {
  public init() {}

  public func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    _ = event
  }
}

public struct TurnTraceMetadata: Sendable {
  public let turnID: UUID?
  public let generationID: UUID
  public let tracer: any TurnTracing
  public let toolLoopIteration: Int?
  public let interactionMode: WorkspaceInteractionMode?

  public init(
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

public enum TurnTraceContext {
  @TaskLocal public static var current: TurnTraceMetadata?
}
