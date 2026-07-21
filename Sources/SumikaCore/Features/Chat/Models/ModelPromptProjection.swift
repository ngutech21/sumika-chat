import Foundation

/// Derived, per-generation model context. It is rebuilt from `ChatSession.turns`
/// for every request and never persisted — `ChatSession` encoding is pinned to
/// omit it — so these types intentionally carry no Codable conformance.
package struct ModelPromptProjection: Equatable, Sendable {
  package var entries: [ModelContextEntry]

  package init(entries: [ModelContextEntry] = []) {
    self.entries = entries
  }

  package func projectedEntries(
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
  package func originalUserPromptText(forTurn turnID: ChatTurn.ID) -> String? {
    for entry in entries {
      guard entry.turnID == turnID, case .userPrompt(let context) = entry.body else {
        continue
      }
      return context.prompt
    }
    return nil
  }
}

package enum ModelContextProjectionMode: String, Equatable, Sendable {
  case fullHistory = "full_history"
  case compactedHistoryForLaterTurns = "compacted_history_for_later_turns"

  package var signatureComponent: String {
    rawValue
  }
}

package struct ProjectedModelContextEntry: Equatable, Sendable {
  package let role: ModelContextRole
  package let content: String
  /// Identities of the images that were consumed with this entry's prompt.
  /// Never sent to the model; lets the runtime cache distinguish prefixes
  /// whose rendered text is identical but whose prefilled images differ.
  package let imageSignatures: [String]

  package init(
    role: ModelContextRole,
    content: String,
    imageSignatures: [String] = []
  ) {
    self.role = role
    self.content = content
    self.imageSignatures = imageSignatures
  }
}

package struct ModelContextEntry: Identifiable, Equatable, Sendable {
  package let id: UUID
  package let turnID: ChatTurn.ID?
  package let sourceMessageID: UUID?
  package let body: ModelContextEntryBody
  package let frozenContent: FrozenModelContent

  package init(
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

package enum ModelContextEntryError: LocalizedError, Equatable, Sendable {
  case roleMismatch(expected: ModelContextRole, actual: ModelContextRole)

  package var errorDescription: String? {
    switch self {
    case .roleMismatch(let expected, let actual):
      "Model context entry role mismatch. Expected \(expected.rawValue), got \(actual.rawValue)."
    }
  }
}

package enum ModelContextEntryBody: Equatable, Sendable {
  case userPrompt(UserPromptContext)
  case assistantOutput(AssistantOutputContext)
  case toolObservation(ToolObservationContext)

  package var modelRole: ModelContextRole {
    switch self {
    case .userPrompt:
      return .user
    case .assistantOutput:
      return .assistant
    case .toolObservation:
      return .tool
    }
  }

  package var isPromptInput: Bool {
    switch self {
    case .userPrompt, .toolObservation:
      return true
    case .assistantOutput:
      return false
    }
  }
}

package struct UserPromptContext: Equatable, Sendable {
  package let prompt: String
  package let attachmentNames: [String]
  /// Content signatures of the image attachments consumed with this prompt.
  /// Carried through the projection so later history renderings reproduce the
  /// exact identity of what was prefilled into the runtime KV cache.
  package let imageSignatures: [String]
  package let workspaceInstructions: [String]
  package let systemContext: [String]
  package let currentPromptContext: CurrentPromptContext?

  package init(
    prompt: String,
    attachmentNames: [String] = [],
    imageSignatures: [String] = [],
    workspaceInstructions: [String] = [],
    systemContext: [String] = [],
    currentPromptContext: CurrentPromptContext? = nil
  ) {
    self.prompt = prompt
    self.attachmentNames = attachmentNames
    self.imageSignatures = imageSignatures
    self.workspaceInstructions = workspaceInstructions
    self.systemContext = systemContext
    self.currentPromptContext = currentPromptContext
  }
}

package struct AssistantOutputContext: Equatable, Sendable {
  package let content: String

  package init(content: String) {
    self.content = content
  }
}

package struct ToolObservationContext: Equatable, Sendable {
  package let callID: UUID
  package let toolName: ToolName
  package let status: ToolResultStatus
  package let content: String
  package let toolReceipt: ToolReceipt?
  package let toolCall: ToolCallModelMessage?

  package init(
    callID: UUID,
    toolName: ToolName,
    status: ToolResultStatus,
    content: String,
    toolReceipt: ToolReceipt? = nil,
    toolCall: ToolCallModelMessage? = nil
  ) {
    self.callID = callID
    self.toolName = toolName
    self.status = status
    self.content = content
    self.toolReceipt = toolReceipt
    self.toolCall = toolCall
  }
}

package struct ToolReceipt: Equatable, Sendable {
  package let callID: UUID
  package let toolName: ToolName
  package let status: ToolResultStatus
  package let affectedPaths: [WorkspaceRelativePath]
  package let summary: ToolReceiptSummary
  package let outputTruncated: Bool
  package let outputRedacted: Bool

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

package struct ToolReceiptSummary: Equatable, Sendable {
  package let text: String
  package let truncated: Bool

  fileprivate init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }

  package static func checked(text: String, maxCharacters: Int = 600) -> ToolReceiptSummary? {
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

package struct FrozenModelContent: Equatable, Sendable {
  package let role: ModelContextRole
  package let content: String
  package let signature: String

  package init(
    role: ModelContextRole,
    content: String
  ) {
    self.role = role
    self.content = content
    self.signature = Self.signature(role: role, content: content)
  }

  package static func signature(role: ModelContextRole, content: String) -> String {
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

package enum ModelContextRole: String, Equatable, Sendable {
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
