import Foundation

/// A provider-neutral, normalized message payload. Source-entry provenance is
/// retained for prompt accounting but is intentionally excluded from equality:
/// internal entry IDs must not change provider-prefix identity.
public struct ProviderPromptMessage: Sendable {
  public let role: String
  public let content: String
  public let toolCalls: [ProviderToolCall]
  public let toolCallID: String?
  public let imageSignatures: [String]
  public let sourceEntryIDs: [UUID]
  public let sourceContentByteRanges: [ProviderPromptSourceContentByteRange]

  public init(
    role: String,
    content: String,
    toolCalls: [ProviderToolCall] = [],
    toolCallID: String? = nil,
    imageSignatures: [String] = [],
    sourceEntryIDs: [UUID] = [],
    sourceContentByteRanges: [ProviderPromptSourceContentByteRange] = []
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
    self.imageSignatures = imageSignatures
    self.sourceEntryIDs = sourceEntryIDs
    self.sourceContentByteRanges = sourceContentByteRanges
  }

  public var hasToolMetadata: Bool {
    !toolCalls.isEmpty || toolCallID != nil
  }

  /// Exact size of the normalized provider payload represented by this
  /// message. Image signatures and source provenance are runtime metadata, not
  /// textual provider fields, and therefore do not contribute bytes.
  public var projectedPayloadByteCount: Int {
    role.utf8.count
      + content.utf8.count
      + (toolCallID?.utf8.count ?? 0)
      + toolCalls.reduce(0) { $0 + $1.canonicalPayloadJSON.utf8.count }
  }
}

public struct ProviderPromptSourceContentByteRange: Equatable, Sendable {
  public let sourceEntryID: UUID
  public let contentByteRange: Range<Int>

  public init(sourceEntryID: UUID, contentByteRange: Range<Int>) {
    self.sourceEntryID = sourceEntryID
    self.contentByteRange = contentByteRange
  }
}

extension ProviderPromptMessage: Equatable {
  public static func == (lhs: ProviderPromptMessage, rhs: ProviderPromptMessage) -> Bool {
    lhs.role == rhs.role
      && lhs.content == rhs.content
      && lhs.toolCalls == rhs.toolCalls
      && lhs.toolCallID == rhs.toolCallID
      && lhs.imageSignatures == rhs.imageSignatures
  }
}

public struct ProviderToolCall: Equatable, Sendable {
  public let id: String?
  public let name: String
  public let arguments: ToolCallArguments

  public init(id: String?, name: String, arguments: ToolCallArguments) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }

  /// Canonical representation used only for provider byte accounting. The
  /// sorted-key encoding prevents dictionary iteration order from changing the
  /// result.
  public var canonicalPayloadJSON: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      let data = try encoder.encode(
        CanonicalProviderToolCallPayload(id: id, name: name, arguments: arguments)
      )
      guard let json = String(data: data, encoding: .utf8) else {
        preconditionFailure("JSONEncoder must emit UTF-8 data.")
      }
      return json
    } catch {
      preconditionFailure("Provider tool-call arguments must be valid JSON: \(error)")
    }
  }
}

private struct CanonicalProviderToolCallPayload: Encodable {
  let id: String?
  let name: String
  let arguments: ToolCallArguments

  private enum CodingKeys: String, CodingKey {
    case arguments
    case id
    case name
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(arguments, forKey: .arguments)
    if let id {
      try container.encode(id, forKey: .id)
    } else {
      try container.encodeNil(forKey: .id)
    }
    try container.encode(name, forKey: .name)
  }
}

public struct ProviderPromptByteLedgerEntry: Equatable, Sendable {
  public let messageIndex: Int
  public let sourceEntryIDs: [UUID]
  public let payloadByteRange: Range<Int>

  public init(
    messageIndex: Int,
    sourceEntryIDs: [UUID],
    payloadByteRange: Range<Int>
  ) {
    self.messageIndex = messageIndex
    self.sourceEntryIDs = sourceEntryIDs
    self.payloadByteRange = payloadByteRange
  }
}

public struct ProviderPromptSourcePayloadByteRange: Equatable, Sendable {
  public let sourceEntryID: UUID
  public let payloadByteRange: Range<Int>

  public init(sourceEntryID: UUID, payloadByteRange: Range<Int>) {
    self.sourceEntryID = sourceEntryID
    self.payloadByteRange = payloadByteRange
  }
}

public struct ProviderPromptByteLedger: Equatable, Sendable {
  public let entries: [ProviderPromptByteLedgerEntry]
  public let sourcePayloadByteRanges: [ProviderPromptSourcePayloadByteRange]
  public let totalByteCount: Int

  public init(messages: [ProviderPromptMessage]) {
    var offset = 0
    var sourceRanges: [ProviderPromptSourcePayloadByteRange] = []
    entries = messages.enumerated().map { index, message in
      let start = offset
      offset += message.projectedPayloadByteCount
      let messageRange = start..<offset
      let contentStart = start + message.role.utf8.count
      let contentByteCount = message.content.utf8.count
      let coveredSourceIDs = Set(message.sourceContentByteRanges.map(\.sourceEntryID))

      for sourceRange in message.sourceContentByteRanges {
        let lowerBound =
          sourceRange.contentByteRange.lowerBound == 0
          ? messageRange.lowerBound
          : contentStart + sourceRange.contentByteRange.lowerBound
        let upperBound =
          sourceRange.contentByteRange.upperBound == contentByteCount
            && message.toolCallID == nil
            && message.toolCalls.isEmpty
          ? messageRange.upperBound
          : contentStart + sourceRange.contentByteRange.upperBound
        sourceRanges.append(
          ProviderPromptSourcePayloadByteRange(
            sourceEntryID: sourceRange.sourceEntryID,
            payloadByteRange: lowerBound..<upperBound
          ))
      }
      for sourceEntryID in message.sourceEntryIDs where !coveredSourceIDs.contains(sourceEntryID) {
        sourceRanges.append(
          ProviderPromptSourcePayloadByteRange(
            sourceEntryID: sourceEntryID,
            payloadByteRange: messageRange
          ))
      }
      return ProviderPromptByteLedgerEntry(
        messageIndex: index,
        sourceEntryIDs: message.sourceEntryIDs,
        payloadByteRange: start..<offset
      )
    }
    sourcePayloadByteRanges = sourceRanges
    totalByteCount = offset
  }

  /// Counts provider bytes between the source payload spans. Content ranges
  /// preserve bytes that sit inside a role-merged message, including the exact
  /// `\n\n` separators, while role and tool metadata remain counted once.
  public func interveningByteCount(
    afterSourceEntryID anchorID: UUID,
    beforeSourceEntryID candidateID: UUID
  ) -> Int? {
    let candidateRanges = sourcePayloadByteRanges.filter { $0.sourceEntryID == candidateID }
    let anchorRanges = sourcePayloadByteRanges.filter { $0.sourceEntryID == anchorID }
    for candidateRange in candidateRanges {
      if let anchorRange = anchorRanges.last(where: {
        $0.payloadByteRange.upperBound <= candidateRange.payloadByteRange.lowerBound
      }) {
        return candidateRange.payloadByteRange.lowerBound
          - anchorRange.payloadByteRange.upperBound
      }
    }
    return nil
  }
}

public struct ProviderPromptProjection: Equatable, Sendable {
  public let messages: [ProviderPromptMessage]
  public let byteLedger: ProviderPromptByteLedger

  public init(messages: [ProviderPromptMessage]) {
    self.messages = messages
    self.byteLedger = ProviderPromptByteLedger(messages: messages)
  }

  public static func normalized(
    from transcript: ModelPromptProjection,
    entryRange: Range<Int>? = nil,
    dropsTrailingUser: Bool = false
  ) -> ProviderPromptProjection {
    let range = entryRange ?? transcript.entries.startIndex..<transcript.entries.endIndex
    return ProviderPromptProjector.normalized(
      from: transcript.entries[range],
      allEntries: transcript.entries,
      dropsTrailingUser: dropsTrailingUser
    )
  }

  public static func normalized(
    from entries: ArraySlice<ProjectedModelContextEntry>,
    dropsTrailingUser: Bool = false
  ) -> ProviderPromptProjection {
    ProviderPromptProjector.normalized(
      from: entries,
      dropsTrailingUser: dropsTrailingUser
    )
  }

  public static func generationSegments(
    from transcript: ModelPromptProjection
  ) -> ProviderPromptGenerationSegments? {
    ProviderPromptProjector.generationSegments(from: transcript)
  }
}

public struct ProviderPromptGenerationSegments: Equatable, Sendable {
  public let history: ProviderPromptProjection
  public let prompt: ProviderPromptProjection

  public init(history: ProviderPromptProjection, prompt: ProviderPromptProjection) {
    self.history = history
    self.prompt = prompt
  }
}

private enum ProviderPromptProjector {
  static func generationSegments(
    from transcript: ModelPromptProjection
  ) -> ProviderPromptGenerationSegments? {
    let entries = transcript.entries
    guard let lastPromptInputIndex = entries.lastIndex(where: { $0.body.isPromptInput }) else {
      return nil
    }

    let promptStart = promptStartIndex(
      in: entries,
      lastPromptInputIndex: lastPromptInputIndex
    )
    let history = normalized(
      from: entries[..<promptStart],
      allEntries: entries,
      dropsTrailingUser: true
    )
    let prompt = normalized(
      from: entries[promptStart...lastPromptInputIndex],
      allEntries: entries,
      dropsTrailingUser: false
    )
    return ProviderPromptGenerationSegments(history: history, prompt: prompt)
  }

  static func normalized(
    from entries: ArraySlice<ProjectedModelContextEntry>,
    dropsTrailingUser: Bool
  ) -> ProviderPromptProjection {
    var messages: [ProviderPromptMessage] = []
    for entry in entries where !entry.content.isEmpty {
      appendNormalized(
        ProviderPromptMessage(
          role: entry.role.rawValue,
          content: entry.content,
          imageSignatures: entry.imageSignatures
        ),
        to: &messages
      )
    }
    dropTrailingUsersIfNeeded(from: &messages, dropsTrailingUser: dropsTrailingUser)
    return ProviderPromptProjection(messages: messages)
  }

  static func normalized(
    from entries: ArraySlice<ModelContextEntry>,
    allEntries: [ModelContextEntry],
    dropsTrailingUser: Bool
  ) -> ProviderPromptProjection {
    var messages: [ProviderPromptMessage] = []
    var index = entries.startIndex

    while index < entries.endIndex {
      let entry = entries[index]
      switch entry.body {
      case .userPrompt:
        appendNormalized(message(forUserEntry: entry), to: &messages)
        index += 1
      case .assistantOutput(let context):
        let calls = structuredToolCalls(afterAssistantBoundaryAt: index, in: allEntries)
        appendNormalized(
          ProviderPromptMessage(
            role: ModelContextRole.assistant.rawValue,
            content: calls.map {
              assistantToolBoundaryContent(context.content, toolCalls: $0.map(\.toolCall))
            } ?? context.content,
            toolCalls: calls?.map { toolCallMessage(from: $0.toolCall) } ?? [],
            sourceEntryIDs: [entry.id] + (calls?.map(\.sourceEntryID) ?? [])
          ),
          to: &messages
        )
        index += 1
      case .toolObservation:
        index = appendStructuredToolResultGroup(
          from: index,
          until: entries.endIndex,
          in: allEntries,
          to: &messages
        )
      }
    }

    dropTrailingUsersIfNeeded(from: &messages, dropsTrailingUser: dropsTrailingUser)
    return ProviderPromptProjection(messages: messages)
  }

  private static func dropTrailingUsersIfNeeded(
    from messages: inout [ProviderPromptMessage],
    dropsTrailingUser: Bool
  ) {
    guard dropsTrailingUser else {
      return
    }
    while messages.last?.role == ModelContextRole.user.rawValue {
      messages.removeLast()
    }
  }

  @discardableResult
  private static func appendStructuredToolResultGroup(
    from startIndex: Int,
    until endIndex: Int,
    in allEntries: [ModelContextEntry],
    to messages: inout [ProviderPromptMessage]
  ) -> Int {
    guard hasStructuredAssistantBoundary(before: startIndex, in: allEntries) else {
      appendUnstructuredToolResultEntry(allEntries[startIndex], to: &messages)
      return startIndex + 1
    }

    var index = startIndex
    var didAppendResult = false
    while index < endIndex {
      guard let result = structuredToolResultMessage(for: allEntries[index]) else {
        break
      }
      appendNormalized(result, to: &messages)
      didAppendResult = true
      index += 1
    }

    guard didAppendResult else {
      appendUnstructuredToolResultEntry(allEntries[startIndex], to: &messages)
      return startIndex + 1
    }
    return index
  }

  private static func appendUnstructuredToolResultEntry(
    _ entry: ModelContextEntry,
    to messages: inout [ProviderPromptMessage]
  ) {
    guard case .toolObservation = entry.body else {
      return
    }
    appendNormalized(
      ProviderPromptMessage(
        role: ModelContextRole.user.rawValue,
        content: entry.frozenContent.content,
        sourceEntryIDs: [entry.id]
      ),
      to: &messages
    )
  }

  private static func appendNormalized(
    _ message: ProviderPromptMessage,
    to messages: inout [ProviderPromptMessage]
  ) {
    guard !message.content.isEmpty || message.hasToolMetadata else {
      return
    }

    if let last = messages.last,
      last.role == ModelContextRole.assistant.rawValue,
      message.role == ModelContextRole.assistant.rawValue,
      !last.hasToolMetadata,
      message.hasToolMetadata
    {
      let content = [last.content, message.content]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
      messages[messages.count - 1] = ProviderPromptMessage(
        role: ModelContextRole.assistant.rawValue,
        content: content,
        toolCalls: message.toolCalls,
        toolCallID: message.toolCallID,
        imageSignatures: last.imageSignatures + message.imageSignatures,
        sourceEntryIDs: uniqueIDs(last.sourceEntryIDs + message.sourceEntryIDs)
      )
      return
    }

    if let last = messages.last,
      last.role == message.role,
      !last.hasToolMetadata,
      !message.hasToolMetadata,
      message.role != ModelContextRole.tool.rawValue
    {
      let messageContentByteOffset = last.content.utf8.count + "\n\n".utf8.count
      messages[messages.count - 1] = ProviderPromptMessage(
        role: last.role,
        content: [last.content, message.content].joined(separator: "\n\n"),
        imageSignatures: last.imageSignatures + message.imageSignatures,
        sourceEntryIDs: uniqueIDs(last.sourceEntryIDs + message.sourceEntryIDs),
        sourceContentByteRanges: last.sourceContentByteRanges
          + message.sourceContentByteRanges.map { sourceRange in
            let lowerBound = sourceRange.contentByteRange.lowerBound + messageContentByteOffset
            let upperBound = sourceRange.contentByteRange.upperBound + messageContentByteOffset
            return ProviderPromptSourceContentByteRange(
              sourceEntryID: sourceRange.sourceEntryID,
              contentByteRange: lowerBound..<upperBound
            )
          }
      )
      return
    }

    messages.append(message)
  }

  private static func uniqueIDs(_ ids: [UUID]) -> [UUID] {
    var seen: Set<UUID> = []
    return ids.filter { seen.insert($0).inserted }
  }

  private static func message(forUserEntry entry: ModelContextEntry) -> ProviderPromptMessage {
    let imageSignatures: [String]
    if case .userPrompt(let context) = entry.body {
      imageSignatures = context.imageSignatures
    } else {
      imageSignatures = []
    }
    return ProviderPromptMessage(
      role: ModelContextRole.user.rawValue,
      content: entry.frozenContent.content,
      imageSignatures: imageSignatures,
      sourceEntryIDs: [entry.id],
      sourceContentByteRanges: [
        ProviderPromptSourceContentByteRange(
          sourceEntryID: entry.id,
          contentByteRange: 0..<entry.frozenContent.content.utf8.count
        )
      ]
    )
  }

  private static func toolResultMessage(
    for entry: ModelContextEntry,
    context: ToolObservationContext
  ) -> ProviderPromptMessage {
    ProviderPromptMessage(
      role: ModelContextRole.tool.rawValue,
      content: context.content,
      toolCallID: RuntimeToolCallID.string(for: context.callID),
      sourceEntryIDs: [entry.id]
    )
  }

  private struct StructuredToolCall {
    let sourceEntryID: UUID
    let toolCall: ToolCallModelMessage
  }

  private static func structuredToolCalls(
    afterAssistantBoundaryAt boundaryIndex: Int,
    in entries: [ModelContextEntry]
  ) -> [StructuredToolCall]? {
    guard boundaryIndex < entries.count,
      case .assistantOutput = entries[boundaryIndex].body
    else {
      return nil
    }

    var calls: [StructuredToolCall] = []
    var index = boundaryIndex + 1
    while index < entries.count {
      guard let toolCall = structuredToolCall(from: entries[index]) else {
        break
      }
      calls.append(StructuredToolCall(sourceEntryID: entries[index].id, toolCall: toolCall))
      index += 1
    }
    return calls.isEmpty ? nil : calls
  }

  private static func assistantToolBoundaryContent(
    _ content: String,
    toolCalls: [ToolCallModelMessage]
  ) -> String {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      return ""
    }
    let syntheticToolCallContent =
      toolCalls
      .map(\.modelContextContent)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedContent != syntheticToolCallContent else {
      return ""
    }
    return content
  }

  private static func hasStructuredAssistantBoundary(
    before resultIndex: Int,
    in entries: [ModelContextEntry]
  ) -> Bool {
    guard resultIndex > 0 else {
      return false
    }

    var boundaryIndex = resultIndex - 1
    while boundaryIndex >= 0, isStructuredToolResultEntry(entries[boundaryIndex]) {
      if boundaryIndex == 0 {
        return false
      }
      boundaryIndex -= 1
    }

    guard case .assistantOutput = entries[boundaryIndex].body else {
      return false
    }
    return structuredToolCalls(afterAssistantBoundaryAt: boundaryIndex, in: entries) != nil
  }

  private static func isStructuredToolResultEntry(_ entry: ModelContextEntry) -> Bool {
    guard case .toolObservation(let context) = entry.body else {
      return false
    }
    return canRenderStructuredToolResult(context)
  }

  private static func canRenderStructuredToolResult(_ context: ToolObservationContext) -> Bool {
    context.toolName != .invalid && context.toolCall != nil
  }

  private static func structuredToolCall(
    from entry: ModelContextEntry
  ) -> ToolCallModelMessage? {
    guard case .toolObservation(let context) = entry.body,
      canRenderStructuredToolResult(context)
    else {
      return nil
    }
    return context.toolCall
  }

  private static func structuredToolResultMessage(
    for entry: ModelContextEntry
  ) -> ProviderPromptMessage? {
    guard case .toolObservation(let context) = entry.body,
      canRenderStructuredToolResult(context)
    else {
      return nil
    }
    return toolResultMessage(for: entry, context: context)
  }

  private static func toolCallMessage(from toolCall: ToolCallModelMessage) -> ProviderToolCall {
    ProviderToolCall(
      id: RuntimeToolCallID.string(for: toolCall.callID),
      name: toolCall.toolName.rawValue,
      arguments: toolCall.rawArguments
    )
  }

  private static func promptStartIndex(
    in entries: [ModelContextEntry],
    lastPromptInputIndex: Int
  ) -> Int {
    switch entries[lastPromptInputIndex].body {
    case .toolObservation:
      var index = lastPromptInputIndex
      while index > 0, isStructuredToolResultEntry(entries[index - 1]) {
        index -= 1
      }
      return index
    case .userPrompt:
      var index = lastPromptInputIndex
      while index > 0 {
        guard isStructuredToolResultEntry(entries[index - 1]),
          hasStructuredAssistantBoundary(before: index - 1, in: entries)
        else {
          break
        }
        index -= 1
      }
      return index
    case .assistantOutput:
      return lastPromptInputIndex
    }
  }
}
