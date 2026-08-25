import Foundation

package enum ApplicationActivationState: String, Codable, Equatable, Sendable {
  case active
  case inactive
  case unavailable
}

package enum ApplicationVisibilityState: String, Codable, Equatable, Sendable {
  case shown
  case hidden
  case unavailable
}

package enum ApplicationOcclusionState: String, Codable, Equatable, Sendable {
  case visible
  case occluded
  case unavailable
}

package enum MainWindowVisibilityState: String, Codable, Equatable, Sendable {
  case visible
  case occluded
  case minimized
  case notVisible = "not_visible"
  case unavailable
}

package enum GenerationActivityRequest: String, Codable, Equatable, Sendable {
  case none
  case userInitiatedAllowingIdleSystemSleep = "user_initiated_allowing_idle_system_sleep"
}

package enum RuntimeStreamOutcome: String, Codable, Equatable, Sendable {
  case completed
  case cancelled
  case failed
  case outputLimit = "output_limit"
  case interrupted
  case toolCallBoundary = "tool_call_boundary"
  case downstreamTerminated = "downstream_terminated"
}

package struct RuntimeApplicationStateSnapshot: Equatable, Sendable {
  package let applicationActivation: ApplicationActivationState
  package let applicationVisibility: ApplicationVisibilityState
  package let applicationOcclusion: ApplicationOcclusionState
  package let mainWindowVisibility: MainWindowVisibilityState

  package static let unavailable = Self(
    applicationActivation: .unavailable,
    applicationVisibility: .unavailable,
    applicationOcclusion: .unavailable,
    mainWindowVisibility: .unavailable
  )

  package init(
    applicationActivation: ApplicationActivationState,
    applicationVisibility: ApplicationVisibilityState,
    applicationOcclusion: ApplicationOcclusionState,
    mainWindowVisibility: MainWindowVisibilityState
  ) {
    self.applicationActivation = applicationActivation
    self.applicationVisibility = applicationVisibility
    self.applicationOcclusion = applicationOcclusion
    self.mainWindowVisibility = mainWindowVisibility
  }
}

package typealias RuntimeApplicationStateSnapshotProvider =
  @Sendable () -> RuntimeApplicationStateSnapshot

package enum TurnTracePhase: String, Codable, CaseIterable, Equatable, Sendable {
  case contextBuild = "context_build"
  case renderSystemPrompt = "render_system_prompt"
  case runtimeStreamStart = "runtime_stream_start"
  case runtimeStreamEnd = "runtime_stream_end"
  case runtimeTTFT = "runtime_ttft"
  case runtimePrefill = "runtime_prefill"
  case runtimeDecode = "runtime_decode"
  case runtimePartialDecode = "runtime_partial_decode"
  case runtimeMemory = "runtime_memory"
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
  package let activatedSkillIDs: [String]?
  package let activatedSkillContentHashes: [String]?
  package let activatedSkillCharacterCount: Int?
  package let contextSignature: String?
  package let previousContextSignature: String?
  package let appendOnly: Bool?
  package let reusedMessageCount: Int?
  package let appendedMessageCount: Int?
  package let mismatchReason: String?
  package let firstMismatchIndex: Int?
  package let systemPromptChanged: Bool?
  package let toolCallFormat: String?
  package let toolValidationStatus: String?
  package let toolValidationError: String?
  package let toolOriginalName: String?
  package let toolArgumentKeys: [String]?
  package let toolArguments: [ToolArgumentTrace]?
  package let imageCount: Int?
  package let imageTypes: [String]?
  package let imageByteCount: Int?
  package let generatedTokenCount: Int?
  package let generatedTokenCountIsEstimate: Bool?
  package let applicationActivation: ApplicationActivationState?
  package let applicationVisibility: ApplicationVisibilityState?
  package let applicationOcclusion: ApplicationOcclusionState?
  package let mainWindowVisibility: MainWindowVisibilityState?
  package let generationActivityRequest: GenerationActivityRequest?
  package let runtimeStreamOutcome: RuntimeStreamOutcome?

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
    activatedSkillIDs: [String]? = nil,
    activatedSkillContentHashes: [String]? = nil,
    activatedSkillCharacterCount: Int? = nil,
    contextSignature: String? = nil,
    previousContextSignature: String? = nil,
    appendOnly: Bool? = nil,
    reusedMessageCount: Int? = nil,
    appendedMessageCount: Int? = nil,
    mismatchReason: String? = nil,
    firstMismatchIndex: Int? = nil,
    systemPromptChanged: Bool? = nil,
    toolCallFormat: String? = nil,
    toolValidationStatus: String? = nil,
    toolValidationError: String? = nil,
    toolOriginalName: String? = nil,
    toolArgumentKeys: [String]? = nil,
    toolArguments: [ToolArgumentTrace]? = nil,
    imageCount: Int? = nil,
    imageTypes: [String]? = nil,
    imageByteCount: Int? = nil,
    generatedTokenCount: Int? = nil,
    generatedTokenCountIsEstimate: Bool? = nil,
    applicationActivation: ApplicationActivationState? = nil,
    applicationVisibility: ApplicationVisibilityState? = nil,
    applicationOcclusion: ApplicationOcclusionState? = nil,
    mainWindowVisibility: MainWindowVisibilityState? = nil,
    generationActivityRequest: GenerationActivityRequest? = nil,
    runtimeStreamOutcome: RuntimeStreamOutcome? = nil
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
    self.activatedSkillIDs = activatedSkillIDs
    self.activatedSkillContentHashes = activatedSkillContentHashes
    self.activatedSkillCharacterCount = activatedSkillCharacterCount
    self.contextSignature = contextSignature
    self.previousContextSignature = previousContextSignature
    self.appendOnly = appendOnly
    self.reusedMessageCount = reusedMessageCount
    self.appendedMessageCount = appendedMessageCount
    self.mismatchReason = mismatchReason
    self.firstMismatchIndex = firstMismatchIndex
    self.systemPromptChanged = systemPromptChanged
    self.toolCallFormat = toolCallFormat
    self.toolValidationStatus = toolValidationStatus
    self.toolValidationError = toolValidationError
    self.toolOriginalName = toolOriginalName
    self.toolArgumentKeys = toolArgumentKeys
    self.toolArguments = toolArguments
    self.imageCount = imageCount
    self.imageTypes = imageTypes
    self.imageByteCount = imageByteCount
    self.generatedTokenCount = generatedTokenCount
    self.generatedTokenCountIsEstimate = generatedTokenCountIsEstimate
    self.applicationActivation = applicationActivation
    self.applicationVisibility = applicationVisibility
    self.applicationOcclusion = applicationOcclusion
    self.mainWindowVisibility = mainWindowVisibility
    self.generationActivityRequest = generationActivityRequest
    self.runtimeStreamOutcome = runtimeStreamOutcome
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
