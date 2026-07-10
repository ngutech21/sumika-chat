import Foundation
import MLXLMCommon
import SumikaCore

nonisolated struct MLXGenerationInput {
  let history: [Chat.Message]
  let historySnapshot: [MLXMessageSnapshot]
  let promptMessages: [Chat.Message]
  let promptSnapshot: [MLXMessageSnapshot]
}

nonisolated enum MLXHistoryRenderer {
  /// Full history keeps the rendered transcript append-only so the cached
  /// KV prefix stays a byte-stable prefix of every later generation. Receipt
  /// compaction rewrites past observations and would invalidate the cache
  /// after every tool turn.
  nonisolated static let runtimeProjectionMode = ModelContextProjectionMode.fullHistory

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  nonisolated static func chatMessage(
    from entry: ProjectedModelContextEntry,
    images: [UserInput.Image] = []
  ) -> Chat.Message {
    switch entry.role {
    case .user:
      return .user(entry.content, images: images)
    case .assistant:
      return .assistant(entry.content)
    case .tool:
      return .tool(entry.content)
    }
  }

  nonisolated static func imageInputs(
    from attachments: [ChatAttachment],
    attachmentStore: ChatAttachmentStore = ChatAttachmentStore()
  ) throws -> [UserInput.Image] {
    try attachments.map { attachment in
      .url(try attachmentStore.validateStoredFile(for: attachment))
    }
  }

  nonisolated static func imageTypes(from attachments: [ChatAttachment]) -> [String]? {
    let types = attachments.compactMap(\.mimeType)
    return types.isEmpty ? nil : types
  }

  nonisolated static func imageByteCount(from attachments: [ChatAttachment]) -> Int? {
    let byteCount = attachments.reduce(0) { total, attachment in
      total + attachment.byteSize
    }
    return byteCount == 0 ? nil : byteCount
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  nonisolated static func templateMessages(
    from transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) throws -> [Chat.Message] {
    _ = attachments
    let history = try validatedChatMessages(
      from: normalizedSnapshots(
        from: transcript.entries[...],
        transcript: transcript,
        dropsTrailingUser: false
      )
    )
    return try validatedTemplateMessages(
      runtimeHistoryMessages(systemPrompt: systemPrompt, history: history),
      allowsSystemPrompt: true
    )
  }

  nonisolated static func runtimeHistoryMessages(
    systemPrompt: String,
    history: [Chat.Message]
  ) throws -> [Chat.Message] {
    let normalizedSystemPrompt = normalizedRuntimeSystemPrompt(systemPrompt)
    let messages =
      if let normalizedSystemPrompt {
        [Chat.Message.system(normalizedSystemPrompt)] + history
      } else {
        history
      }
    return try validatedTemplateMessages(messages, allowsSystemPrompt: true)
  }

  nonisolated static func normalizedRuntimeSystemPrompt(_ systemPrompt: String) -> String? {
    ModelFacingPromptRenderer.normalizedSystemPrompt(systemPrompt)
  }

  nonisolated static func generationInput(
    from transcript: ModelPromptProjection,
    images: [UserInput.Image] = []
  ) throws -> MLXGenerationInput {
    let entries = transcript.entries
    guard let lastPromptInputIndex = entries.lastIndex(where: { $0.body.isPromptInput }) else {
      throw MLXChatRuntimeError.missingUserMessage
    }

    let promptStartIndex = promptStartIndex(
      in: entries,
      lastPromptInputIndex: lastPromptInputIndex
    )
    let historySnapshot = normalizedSnapshots(
      from: entries[..<promptStartIndex],
      transcript: transcript,
      dropsTrailingUser: true
    )
    let promptSnapshot = normalizedSnapshots(
      from: entries[promptStartIndex...lastPromptInputIndex],
      transcript: transcript,
      dropsTrailingUser: false
    )

    let history = try validatedChatMessages(from: historySnapshot)
    var promptMessages = chatMessages(from: promptSnapshot)
    if !images.isEmpty,
      let userIndex = promptMessages.lastIndex(where: { $0.role == .user })
    {
      promptMessages[userIndex].images = images
    }

    return MLXGenerationInput(
      history: history,
      historySnapshot: historySnapshot,
      promptMessages: promptMessages,
      promptSnapshot: promptSnapshot
    )
  }

  nonisolated static func validatedTemplateMessages(
    _ messages: [Chat.Message],
    allowsSystemPrompt: Bool = false
  ) throws -> [Chat.Message] {
    let bodyMessages: ArraySlice<Chat.Message>
    if messages.first?.role == .system {
      guard allowsSystemPrompt else {
        throw MLXChatRuntimeError.invalidChatTemplateMessageSequence
      }
      bodyMessages = messages.dropFirst()
    } else {
      bodyMessages = messages[...]
    }

    guard bodyMessages.allSatisfy({ $0.role == .user || $0.role == .assistant || $0.role == .tool })
    else {
      throw MLXChatRuntimeError.invalidChatTemplateMessageSequence
    }

    for index in bodyMessages.indices.dropFirst() {
      let previousIndex = bodyMessages.index(before: index)
      let previousRole = bodyMessages[previousIndex].role
      let currentRole = bodyMessages[index].role
      if previousRole == currentRole, currentRole != .tool {
        throw MLXChatRuntimeError.invalidChatTemplateMessageSequence
      }
    }

    return messages
  }

  /// Skips empty entries, merges consecutive same-role entries with a blank
  /// line, and carries image signatures. `dropsTrailingUser` removes trailing
  /// user turns for the generation history (the current prompt is rendered
  /// separately); the token-counting path keeps them. Single source for the
  /// template history, the generation history, and the cache prefix snapshot so
  /// the three can never drift.
  nonisolated private static func normalizedSnapshots(
    from entries: ArraySlice<ProjectedModelContextEntry>,
    dropsTrailingUser: Bool
  ) -> [MLXMessageSnapshot] {
    var items: [MLXMessageSnapshot] = []
    for entry in entries {
      guard !entry.content.isEmpty else {
        continue
      }
      let role: Chat.Message.Role =
        switch entry.role {
        case .user:
          .user
        case .assistant:
          .assistant
        case .tool:
          .tool
        }
      if let last = items.last, last.role == role.rawValue {
        appendNormalized(
          MLXMessageSnapshot(
            role: role.rawValue,
            content: entry.content,
            imageSignatures: entry.imageSignatures
          ),
          to: &items
        )
      } else {
        appendNormalized(
          MLXMessageSnapshot(
            role: role.rawValue,
            content: entry.content,
            imageSignatures: entry.imageSignatures
          ),
          to: &items
        )
      }
    }

    if dropsTrailingUser {
      while items.last?.role == Chat.Message.Role.user.rawValue {
        items.removeLast()
      }
    }

    return items
  }

  nonisolated private static func normalizedSnapshots(
    from entries: ArraySlice<ModelContextEntry>,
    transcript: ModelPromptProjection,
    dropsTrailingUser: Bool
  ) -> [MLXMessageSnapshot] {
    var items: [MLXMessageSnapshot] = []
    let allEntries = transcript.entries
    var index = entries.startIndex

    while index < entries.endIndex {
      let entry = entries[index]
      switch entry.body {
      case .userPrompt:
        appendNormalized(snapshot(forUserEntry: entry), to: &items)
        index += 1
      case .assistantOutput(let context):
        if let toolCalls = structuredToolCalls(afterAssistantBoundaryAt: index, in: allEntries) {
          appendNormalized(
            MLXMessageSnapshot(
              role: Chat.Message.Role.assistant.rawValue,
              content: assistantToolBoundaryContent(context.content, toolCalls: toolCalls),
              toolCalls: toolCalls.map(toolCallSnapshot(from:))
            ),
            to: &items
          )
        } else {
          appendNormalized(
            MLXMessageSnapshot(
              role: Chat.Message.Role.assistant.rawValue,
              content: context.content
            ),
            to: &items
          )
        }
        index += 1
      case .toolObservation:
        index = appendStructuredToolResultGroup(
          from: index,
          until: entries.endIndex,
          in: allEntries,
          to: &items
        )
      }
    }

    if dropsTrailingUser {
      while items.last?.role == Chat.Message.Role.user.rawValue {
        items.removeLast()
      }
    }

    return items
  }

  @discardableResult
  nonisolated private static func appendStructuredToolResultGroup(
    from startIndex: Int,
    until endIndex: Int,
    in allEntries: [ModelContextEntry],
    to items: inout [MLXMessageSnapshot]
  ) -> Int {
    guard hasStructuredAssistantBoundary(before: startIndex, in: allEntries) else {
      appendUnstructuredToolResultEntry(allEntries[startIndex], to: &items)
      return startIndex + 1
    }

    var index = startIndex
    var didAppendResult = false

    while index < endIndex {
      guard let result = structuredToolResultSnapshot(for: allEntries[index]) else {
        break
      }

      appendNormalized(result, to: &items)
      didAppendResult = true
      index += 1
    }

    guard didAppendResult else {
      appendUnstructuredToolResultEntry(allEntries[startIndex], to: &items)
      return startIndex + 1
    }

    return index
  }

  nonisolated private static func appendUnstructuredToolResultEntry(
    _ entry: ModelContextEntry,
    to items: inout [MLXMessageSnapshot]
  ) {
    switch entry.body {
    case .toolObservation(let context):
      // Terminal write results replay as assistant output in the legacy
      // unstructured fallback; ordinary observations replay as user input.
      appendNormalized(
        MLXMessageSnapshot(
          role: context.isTerminal
            ? Chat.Message.Role.assistant.rawValue
            : Chat.Message.Role.user.rawValue,
          content: entry.frozenContent.content
        ),
        to: &items
      )
    case .userPrompt, .assistantOutput:
      break
    }
  }

  nonisolated private static func appendNormalized(
    _ snapshot: MLXMessageSnapshot,
    to items: inout [MLXMessageSnapshot]
  ) {
    guard !snapshot.content.isEmpty || snapshot.hasToolMetadata else {
      return
    }

    if let last = items.last,
      last.role == Chat.Message.Role.assistant.rawValue,
      snapshot.role == Chat.Message.Role.assistant.rawValue,
      !last.hasToolMetadata,
      snapshot.hasToolMetadata
    {
      let content = [last.content, snapshot.content]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
      items[items.count - 1] = MLXMessageSnapshot(
        role: Chat.Message.Role.assistant.rawValue,
        content: content,
        toolCalls: snapshot.toolCalls,
        toolCallID: snapshot.toolCallID,
        imageSignatures: last.imageSignatures + snapshot.imageSignatures
      )
      return
    }

    if let last = items.last,
      last.role == snapshot.role,
      !last.hasToolMetadata,
      !snapshot.hasToolMetadata,
      snapshot.role != Chat.Message.Role.tool.rawValue
    {
      items[items.count - 1] = MLXMessageSnapshot(
        role: last.role,
        content: [last.content, snapshot.content].joined(separator: "\n\n"),
        imageSignatures: last.imageSignatures + snapshot.imageSignatures
      )
      return
    }

    items.append(snapshot)
  }

  nonisolated private static func snapshot(forUserEntry entry: ModelContextEntry)
    -> MLXMessageSnapshot
  {
    let imageSignatures: [String]
    if case .userPrompt(let context) = entry.body {
      imageSignatures = context.imageSignatures
    } else {
      imageSignatures = []
    }

    return MLXMessageSnapshot(
      role: Chat.Message.Role.user.rawValue,
      content: entry.frozenContent.content,
      imageSignatures: imageSignatures
    )
  }

  nonisolated private static func toolResultSnapshot(
    for context: ToolObservationContext
  ) -> MLXMessageSnapshot {
    MLXMessageSnapshot(
      role: Chat.Message.Role.tool.rawValue,
      content: context.content,
      toolCallID: RuntimeToolCallID.string(for: context.callID)
    )
  }

  nonisolated private static func structuredToolCalls(
    afterAssistantBoundaryAt boundaryIndex: Int,
    in entries: [ModelContextEntry]
  ) -> [ToolCallModelMessage]? {
    guard boundaryIndex < entries.count,
      case .assistantOutput = entries[boundaryIndex].body
    else {
      return nil
    }

    var toolCalls: [ToolCallModelMessage] = []
    var index = boundaryIndex + 1
    while index < entries.count {
      guard let toolCall = structuredToolCall(from: entries[index]) else {
        break
      }
      toolCalls.append(toolCall)
      index += 1
    }

    return toolCalls.isEmpty ? nil : toolCalls
  }

  nonisolated private static func assistantToolBoundaryContent(
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

  nonisolated private static func hasStructuredAssistantBoundary(
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

  nonisolated private static func isStructuredToolResultEntry(_ entry: ModelContextEntry) -> Bool {
    switch entry.body {
    case .toolObservation(let context):
      return canRenderStructuredToolResult(context)
    case .userPrompt, .assistantOutput:
      return false
    }
  }

  nonisolated private static func canRenderStructuredToolResult(
    _ context: ToolObservationContext
  ) -> Bool {
    context.toolName != .invalid && context.toolCall != nil
  }

  nonisolated private static func structuredToolCall(
    from entry: ModelContextEntry
  ) -> ToolCallModelMessage? {
    switch entry.body {
    case .toolObservation(let context):
      guard canRenderStructuredToolResult(context) else {
        return nil
      }
      return context.toolCall
    case .userPrompt, .assistantOutput:
      return nil
    }
  }

  nonisolated private static func structuredToolResultSnapshot(
    for entry: ModelContextEntry
  ) -> MLXMessageSnapshot? {
    switch entry.body {
    case .toolObservation(let context):
      guard canRenderStructuredToolResult(context) else {
        return nil
      }
      return toolResultSnapshot(for: context)
    case .userPrompt, .assistantOutput:
      return nil
    }
  }

  nonisolated private static func toolCallSnapshot(
    from toolCall: ToolCallModelMessage
  ) -> MLXToolCallSnapshot {
    MLXToolCallSnapshot(
      id: RuntimeToolCallID.string(for: toolCall.callID),
      name: toolCall.toolName.rawValue,
      arguments: toolCall.rawArguments
    )
  }

  nonisolated private static func promptStartIndex(
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

  /// Maps normalized snapshots back to `Chat.Message`.
  nonisolated static func chatMessages(
    from snapshots: [MLXMessageSnapshot]
  ) -> [Chat.Message] {
    snapshots.map { snapshot in
      switch snapshot.role {
      case Chat.Message.Role.assistant.rawValue:
        return .assistant(
          snapshot.content,
          toolCalls: snapshot.toolCalls.isEmpty
            ? nil
            : snapshot.toolCalls.map(mlxToolCall(from:))
        )
      case Chat.Message.Role.tool.rawValue:
        return .tool(snapshot.content, id: snapshot.toolCallID)
      case Chat.Message.Role.system.rawValue:
        return .system(snapshot.content)
      default:
        return .user(snapshot.content)
      }
    }
  }

  nonisolated private static func mlxToolCall(
    from snapshot: MLXToolCallSnapshot
  ) -> MLXLMCommon.ToolCall {
    MLXLMCommon.ToolCall(
      function: MLXLMCommon.ToolCall.Function(
        name: snapshot.name,
        arguments: snapshot.arguments.mapValues(jsonValue(from:))
      ),
      id: snapshot.id
    )
  }

  nonisolated private static func jsonValue(from value: ToolArgumentValue) -> JSONValue {
    switch value {
    case .string(let string):
      return .string(string)
    case .number(let number):
      if number.rounded() == number,
        number >= Double(Int.min),
        number <= Double(Int.max)
      {
        return .int(Int(number))
      }
      return .double(number)
    case .bool(let bool):
      return .bool(bool)
    case .array(let array):
      return .array(array.map(jsonValue(from:)))
    case .object(let object):
      return .object(object.mapValues(jsonValue(from:)))
    case .null:
      return .null
    }
  }

  nonisolated static func validatedChatMessages(
    from snapshots: [MLXMessageSnapshot]
  ) throws -> [Chat.Message] {
    try validatedTemplateMessages(chatMessages(from: snapshots))
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  nonisolated static func generationHistoryMessages(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) throws -> [Chat.Message] {
    try validatedChatMessages(from: generationHistorySnapshot(from: entries))
  }

  nonisolated static func generationHistorySnapshot(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) -> [MLXMessageSnapshot] {
    normalizedSnapshots(from: entries, dropsTrailingUser: true)
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  nonisolated static func generationHistoryMessages(
    from transcript: ModelPromptProjection
  ) throws -> [Chat.Message] {
    try generationInput(from: transcript).history
  }
}
