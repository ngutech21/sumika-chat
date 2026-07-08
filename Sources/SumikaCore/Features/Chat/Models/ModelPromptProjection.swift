import Foundation

/// Derived, per-generation model context. It is rebuilt from `ChatSession.turns`
/// for every request and never persisted — `ChatSession` encoding is pinned to
/// omit it — so these types intentionally carry no Codable conformance.
public struct ModelPromptProjection: Equatable, Sendable {
  public var entries: [ModelContextEntry]

  public init(entries: [ModelContextEntry] = []) {
    self.entries = entries
  }

  public func projectedEntries(
    mode: ModelContextProjectionMode = .fullHistory
  ) -> [ProjectedModelContextEntry] {
    let currentPromptIndex = entries.lastIndex { entry in
      entry.body.isPromptInput
    }
    return entries.indices.map { index in
      entries[index].projectedEntry(
        mode: mode,
        keepFullContent: index == currentPromptIndex
      )
    }
  }

  /// The raw prompt text of the original user prompt in the given turn.
  public func originalUserPromptText(forTurn turnID: ChatTurn.ID) -> String? {
    for entry in entries {
      guard entry.turnID == turnID, case .userPrompt(let context) = entry.body else {
        continue
      }
      return context.prompt
    }
    return nil
  }
}

public enum ModelContextProjectionMode: String, Equatable, Sendable {
  case fullHistory = "full_history"
  case compactedHistoryForLaterTurns = "compacted_history_for_later_turns"

  public var signatureComponent: String {
    rawValue
  }
}

public struct ProjectedModelContextEntry: Equatable, Sendable {
  public let role: ModelContextRole
  public let content: String
  /// Identities of the images that were consumed with this entry's prompt.
  /// Never sent to the model; lets the runtime cache distinguish prefixes
  /// whose rendered text is identical but whose prefilled images differ.
  public let imageSignatures: [String]

  public init(
    role: ModelContextRole,
    content: String,
    imageSignatures: [String] = []
  ) {
    self.role = role
    self.content = content
    self.imageSignatures = imageSignatures
  }
}

public struct ModelContextEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let turnID: ChatTurn.ID?
  public let sourceMessageID: UUID?
  public let body: ModelContextEntryBody
  public let frozenContent: FrozenModelContent

  public init(
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    sourceMessageID: UUID? = nil,
    body: ModelContextEntryBody,
    frozenContent: FrozenModelContent
  ) throws {
    guard frozenContent.role == body.modelRole else {
      throw ModelContextEntryError.roleMismatch(
        expected: body.modelRole,
        actual: frozenContent.role
      )
    }
    self.id = id
    self.turnID = turnID
    self.sourceMessageID = sourceMessageID
    self.body = body
    self.frozenContent = frozenContent
  }
}

public enum ModelContextEntryError: LocalizedError, Equatable, Sendable {
  case roleMismatch(expected: ModelContextRole, actual: ModelContextRole)

  public var errorDescription: String? {
    switch self {
    case .roleMismatch(let expected, let actual):
      "Model context entry role mismatch. Expected \(expected.rawValue), got \(actual.rawValue)."
    }
  }
}

public enum ModelContextEntryBody: Equatable, Sendable {
  case userPrompt(UserPromptContext)
  case assistantOutput(AssistantOutputContext)
  case toolObservation(ToolObservationContext)

  public var modelRole: ModelContextRole {
    switch self {
    case .userPrompt:
      return .user
    case .assistantOutput:
      return .assistant
    case .toolObservation:
      return .tool
    }
  }

  public var isPromptInput: Bool {
    switch self {
    case .userPrompt, .toolObservation:
      return true
    case .assistantOutput:
      return false
    }
  }
}

public struct UserPromptContext: Equatable, Sendable {
  public let prompt: String
  public let attachmentNames: [String]
  /// Content signatures of the image attachments consumed with this prompt.
  /// Carried through the projection so later history renderings reproduce the
  /// exact identity of what was prefilled into the runtime KV cache.
  public let imageSignatures: [String]
  public let systemContext: [String]
  public let currentPromptContext: CurrentPromptContext?

  public init(
    prompt: String,
    attachmentNames: [String] = [],
    imageSignatures: [String] = [],
    systemContext: [String] = [],
    currentPromptContext: CurrentPromptContext? = nil
  ) {
    self.prompt = prompt
    self.attachmentNames = attachmentNames
    self.imageSignatures = imageSignatures
    self.systemContext = systemContext
    self.currentPromptContext = currentPromptContext
  }
}

public struct AssistantOutputContext: Equatable, Sendable {
  public let content: String

  public init(content: String) {
    self.content = content
  }
}

public struct ToolObservationContext: Equatable, Sendable {
  public let callID: UUID
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let content: String
  public let toolReceipt: ToolReceipt?
  public let toolCall: ToolCallModelMessage?
  /// True for a successful write/edit result (`TerminalToolResultPolicy`): the
  /// turn ends with a tools-stripped final generation after this observation,
  /// and the legacy unstructured history fallback replays it in the assistant
  /// role instead of the user role.
  public let isTerminal: Bool

  public init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    content: String,
    toolReceipt: ToolReceipt? = nil,
    toolCall: ToolCallModelMessage? = nil,
    isTerminal: Bool = false
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.content = content
    self.toolReceipt = toolReceipt
    self.toolCall = toolCall
    self.isTerminal = isTerminal
  }
}

public struct ToolReceipt: Equatable, Sendable {
  public let callID: UUID
  public let toolName: ToolName
  public let status: ToolResultStatus
  public let affectedPaths: [WorkspaceRelativePath]
  public let summary: ToolReceiptSummary
  public let outputTruncated: Bool
  public let outputRedacted: Bool

  private init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    affectedPaths: [WorkspaceRelativePath],
    summary: ToolReceiptSummary,
    outputTruncated: Bool,
    outputRedacted: Bool
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.affectedPaths = affectedPaths
    self.summary = summary
    self.outputTruncated = outputTruncated
    self.outputRedacted = outputRedacted
  }

  static func make(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    affectedPaths: [WorkspaceRelativePath],
    summary: ToolReceiptSummary,
    outputTruncated: Bool,
    outputRedacted: Bool
  ) -> ToolReceipt {
    ToolReceipt(
      callID: callID,
      toolName: toolName,
      status: status,
      affectedPaths: affectedPaths,
      summary: summary,
      outputTruncated: outputTruncated,
      outputRedacted: outputRedacted
    )
  }
}

public struct ToolReceiptSummary: Equatable, Sendable {
  public let text: String
  public let truncated: Bool

  fileprivate init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }

  public static func checked(text: String, maxCharacters: Int = 600) -> ToolReceiptSummary? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, maxCharacters > 0 else {
      return nil
    }

    guard trimmed.count > maxCharacters else {
      return ToolReceiptSummary(text: trimmed, truncated: false)
    }

    return ToolReceiptSummary(
      text: String(trimmed.prefix(maxCharacters)),
      truncated: true
    )
  }
}

public struct FrozenModelContent: Equatable, Sendable {
  public let role: ModelContextRole
  public let content: String
  public let signature: String

  public init(
    role: ModelContextRole,
    content: String
  ) {
    self.role = role
    self.content = content
    self.signature = Self.signature(role: role, content: content)
  }

  public static func signature(role: ModelContextRole, content: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func update(_ byte: UInt8) {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }

    for byte in role.rawValue.utf8 {
      update(byte)
    }
    update(0)
    for byte in content.utf8 {
      update(byte)
    }

    return String(format: "%016llx", hash)
  }
}

public enum ModelContextRole: String, Equatable, Sendable {
  case user
  case assistant
  case tool
}

extension ModelContextEntry {
  fileprivate var imageSignatures: [String] {
    guard case .userPrompt(let context) = body else {
      return []
    }
    return context.imageSignatures
  }

  fileprivate func projectedEntry(
    mode: ModelContextProjectionMode,
    keepFullContent: Bool
  ) -> ProjectedModelContextEntry {
    guard mode == .compactedHistoryForLaterTurns, !keepFullContent else {
      return ProjectedModelContextEntry(
        role: frozenContent.role,
        content: frozenContent.content,
        imageSignatures: imageSignatures
      )
    }

    switch body {
    case .toolObservation(let context):
      guard let toolReceipt = context.toolReceipt else {
        return ProjectedModelContextEntry(
          role: frozenContent.role,
          content: frozenContent.content
        )
      }
      return ProjectedModelContextEntry(
        role: .tool,
        content: ToolReceiptRenderer.render(toolReceipt)
      )
    case .userPrompt, .assistantOutput:
      return ProjectedModelContextEntry(
        role: frozenContent.role,
        content: frozenContent.content,
        imageSignatures: imageSignatures
      )
    }
  }
}
