import Foundation

public struct ChatTurn: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public private(set) var status: ChatTurnStatus
  public private(set) var modelContextPolicy: ChatTurnModelContextPolicy
  public private(set) var items: [ChatTurnItem]
  public var createdAt: Date
  public private(set) var updatedAt: Date

  public init(
    id: UUID = UUID(),
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy = .included,
    items: [ChatTurnItem] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.status = status
    self.modelContextPolicy = modelContextPolicy
    self.items = items
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case status
    case modelContextPolicy
    case items
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    status = try container.decodeIfPresent(
      ChatTurnStatus.self, forKey: .status, default: .completed)
    modelContextPolicy = try container.decodeIfPresent(
      ChatTurnModelContextPolicy.self,
      forKey: .modelContextPolicy,
      default: .included
    )
    items = try container.decodeLossyArray([ChatTurnItem].self, forKey: .items)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt, default: Date())
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt, default: createdAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(status, forKey: .status)
    try container.encode(modelContextPolicy, forKey: .modelContextPolicy)
    try container.encode(items, forKey: .items)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  mutating func appendItem(_ item: ChatTurnItem, at timestamp: Date = Date()) {
    items.append(item)
    updatedAt = timestamp
  }

  mutating func appendAssistantChunk(
    _ chunk: String,
    to messageID: UUID,
    at timestamp: Date = Date()
  ) {
    updateAssistantMessage(messageID, at: timestamp) { message in
      message.content += chunk
    }
  }

  mutating func appendAssistantThinkingChunk(
    _ chunk: String,
    to messageID: UUID,
    at timestamp: Date = Date()
  ) {
    updateAssistantThinkingMessage(messageID, at: timestamp) { message in
      if message.startedAt == nil {
        message.startedAt = timestamp
      }
      message.content += chunk
    }
  }

  mutating func updateAssistantDeliveryStatus(
    _ status: AssistantTurnMessage.DeliveryStatus,
    for messageID: UUID,
    at timestamp: Date = Date()
  ) {
    updateAssistantMessage(messageID, at: timestamp) { message in
      message.deliveryStatus = status
    }
  }

  mutating func updateAssistantThinkingDeliveryStatus(
    _ status: AssistantThinkingMessage.DeliveryStatus,
    for messageID: UUID,
    at timestamp: Date = Date()
  ) {
    updateAssistantThinkingMessage(messageID, at: timestamp) { message in
      if status != .streaming, message.completedAt == nil {
        message.completedAt = timestamp
      }
      message.deliveryStatus = status
    }
  }

  mutating func updateAssistantGenerationMetrics(
    _ metrics: ChatGenerationMetrics?,
    for messageID: UUID,
    at timestamp: Date = Date()
  ) {
    updateAssistantMessage(messageID, at: timestamp) { message in
      message.generationMetrics = metrics
    }
  }

  mutating func markStreamingAssistantMessagesCancelled(at timestamp: Date = Date()) {
    var didUpdate = false
    items = items.map { item in
      switch item {
      case .assistantMessage(var message) where message.deliveryStatus == .streaming:
        message.deliveryStatus = .cancelled
        didUpdate = true
        return .assistantMessage(message)
      case .assistantThinking(var message) where message.deliveryStatus == .streaming:
        message.deliveryStatus = .cancelled
        if message.completedAt == nil {
          message.completedAt = timestamp
        }
        didUpdate = true
        return .assistantThinking(message)
      default:
        return item
      }
    }
    if didUpdate {
      updatedAt = timestamp
    }
  }

  mutating func cancelEmptyStreamingAssistantPlaceholders(at timestamp: Date = Date()) {
    var didUpdate = false
    items = items.map { item in
      guard case .assistantMessage(var message) = item,
        message.deliveryStatus == .streaming,
        message.content.isEmpty
      else {
        return item
      }
      message.deliveryStatus = .cancelled
      didUpdate = true
      return .assistantMessage(message)
    }
    if didUpdate {
      updatedAt = timestamp
    }
  }

  mutating func recordToolCall(_ record: ToolCallRecord, at timestamp: Date = Date()) {
    guard let index = toolItemIndex(id: record.id) else {
      appendItem(.tool(record), at: timestamp)
      return
    }
    items[index] = .tool(record)
    updatedAt = timestamp
  }

  mutating func updateToolCallRecord(_ record: ToolCallRecord, at timestamp: Date = Date()) {
    guard let index = toolItemIndex(id: record.id) else {
      return
    }
    items[index] = .tool(record)
    updatedAt = timestamp
  }

  mutating func appendOrUpdateToolResult(
    _ toolResult: ToolResultModelMessage,
    fallbackRecord: @autoclosure () -> ToolCallRecord,
    at timestamp: Date = Date()
  ) {
    if let index = toolItemIndex(id: toolResult.callID),
      case .tool(var record) = items[index]
    {
      record.state = toolResult.completedState
      items[index] = .tool(record)
      updatedAt = timestamp
      return
    }

    appendItem(.tool(fallbackRecord()), at: timestamp)
  }

  mutating func annotateAssistantMessageAsToolCall(
    messageID: UUID,
    record: ToolCallRecord,
    at timestamp: Date = Date()
  ) {
    if let index = assistantMessageIndex(id: messageID),
      case .assistantMessage(var message) = items[index],
      message.content.isEmpty,
      message.deliveryStatus == .streaming
    {
      message.deliveryStatus = .cancelled
      items[index] = .assistantMessage(message)
      updatedAt = timestamp
    }
    recordToolCall(record, at: timestamp)
  }

  mutating func updateStatus(
    _ status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy? = nil,
    at timestamp: Date = Date()
  ) {
    self.status = status
    if let modelContextPolicy {
      self.modelContextPolicy = modelContextPolicy
    }
    updatedAt = timestamp
  }

  func containsMessage(id messageID: UUID) -> Bool {
    items.contains { $0.messageID == messageID }
  }

  func containsToolCall(id toolCallID: ToolCallRecord.ID) -> Bool {
    toolItemIndex(id: toolCallID) != nil
  }

  func toolCallRecord(id toolCallID: ToolCallRecord.ID) -> ToolCallRecord? {
    guard let index = toolItemIndex(id: toolCallID),
      case .tool(let record) = items[index]
    else {
      return nil
    }
    return record
  }

  private func assistantMessageIndex(id messageID: UUID) -> Int? {
    items.firstIndex { item in
      guard case .assistantMessage(let message) = item else {
        return false
      }
      return message.id == messageID
    }
  }

  private func assistantThinkingMessageIndex(id messageID: UUID) -> Int? {
    items.firstIndex { item in
      guard case .assistantThinking(let message) = item else {
        return false
      }
      return message.id == messageID
    }
  }

  private mutating func updateAssistantMessage(
    _ messageID: UUID,
    at timestamp: Date,
    update: (inout AssistantTurnMessage) -> Void
  ) {
    guard let index = assistantMessageIndex(id: messageID),
      case .assistantMessage(var message) = items[index]
    else {
      return
    }
    update(&message)
    items[index] = .assistantMessage(message)
    updatedAt = timestamp
  }

  private mutating func updateAssistantThinkingMessage(
    _ messageID: UUID,
    at timestamp: Date,
    update: (inout AssistantThinkingMessage) -> Void
  ) {
    guard let index = assistantThinkingMessageIndex(id: messageID),
      case .assistantThinking(var message) = items[index]
    else {
      return
    }
    update(&message)
    items[index] = .assistantThinking(message)
    updatedAt = timestamp
  }

  private func toolItemIndex(id toolCallID: ToolCallRecord.ID) -> Int? {
    items.firstIndex { item in
      guard case .tool(let record) = item else {
        return false
      }
      return record.id == toolCallID
    }
  }
}

public enum ChatTurnItem: Codable, Equatable, Sendable {
  case userMessage(UserTurnMessage)
  case assistantThinking(AssistantThinkingMessage)
  case assistantMessage(AssistantTurnMessage)
  case tool(ToolCallRecord)

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

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .userMessage:
      self = .userMessage(try container.decode(UserTurnMessage.self, forKey: .payload))
    case .assistantThinking:
      self = .assistantThinking(
        try container.decode(AssistantThinkingMessage.self, forKey: .payload)
      )
    case .assistantMessage:
      self = .assistantMessage(try container.decode(AssistantTurnMessage.self, forKey: .payload))
    case .tool:
      self = .tool(try container.decode(ToolCallRecord.self, forKey: .payload))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .userMessage(let message):
      try container.encode(Kind.userMessage, forKey: .kind)
      try container.encode(message, forKey: .payload)
    case .assistantThinking(let message):
      try container.encode(Kind.assistantThinking, forKey: .kind)
      try container.encode(message, forKey: .payload)
    case .assistantMessage(let message):
      try container.encode(Kind.assistantMessage, forKey: .kind)
      try container.encode(message, forKey: .payload)
    case .tool(let record):
      try container.encode(Kind.tool, forKey: .kind)
      try container.encode(record, forKey: .payload)
    }
  }
}

public struct UserTurnMessage: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var attachments: [ChatAttachment]
  public var promptContext: CurrentPromptContext

  public init(
    id: UUID = UUID(),
    content: String,
    attachments: [ChatAttachment] = [],
    promptContext: CurrentPromptContext = .empty(.focusedFileDefault)
  ) {
    self.id = id
    self.content = content
    self.attachments = attachments
    self.promptContext = promptContext
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case content
    case attachments
    case promptContext
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
    attachments = try container.decodeLossyArray([ChatAttachment].self, forKey: .attachments)
    promptContext = try container.decodeIfPresent(
      CurrentPromptContext.self,
      forKey: .promptContext,
      default: .empty(.focusedFileDefault)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(content, forKey: .content)
    try container.encode(attachments, forKey: .attachments)
    try container.encode(promptContext, forKey: .promptContext)
  }
}

public enum AssistantModelProjectionPolicy: Codable, Equatable, Sendable {
  case visibleContent
  case override(String)
  case excluded

  private enum CodingKeys: String, CodingKey {
    case kind
    case content
  }

  private enum Kind: String, Codable {
    case visibleContent
    case override
    case excluded
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .visibleContent:
      self = .visibleContent
    case .override:
      self = .override(try container.decode(String.self, forKey: .content))
    case .excluded:
      self = .excluded
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .visibleContent:
      try container.encode(Kind.visibleContent, forKey: .kind)
    case .override(let content):
      try container.encode(Kind.override, forKey: .kind)
      try container.encode(content, forKey: .content)
    case .excluded:
      try container.encode(Kind.excluded, forKey: .kind)
    }
  }
}

public struct AssistantTurnMessage: Codable, Identifiable, Equatable, Sendable {
  public enum DeliveryStatus: String, Codable, Equatable, Sendable {
    case complete
    case streaming
    case cancelled
  }

  public let id: UUID
  public var content: String
  public var modelProjectionPolicy: AssistantModelProjectionPolicy
  public var attachments: [ChatAttachment]
  public var generationMetrics: ChatGenerationMetrics?
  public var deliveryStatus: DeliveryStatus

  public init(
    id: UUID = UUID(),
    content: String,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    deliveryStatus: DeliveryStatus = .complete,
    modelProjectionPolicy: AssistantModelProjectionPolicy = .visibleContent
  ) {
    self.id = id
    self.content = content
    self.modelProjectionPolicy = modelProjectionPolicy
    self.attachments = attachments
    self.generationMetrics = generationMetrics
    self.deliveryStatus = deliveryStatus
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case content
    case modelProjectionPolicy
    case attachments
    case generationMetrics
    case deliveryStatus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
    modelProjectionPolicy = try container.decodeIfPresent(
      AssistantModelProjectionPolicy.self,
      forKey: .modelProjectionPolicy,
      default: .visibleContent
    )
    attachments = try container.decodeLossyArray([ChatAttachment].self, forKey: .attachments)
    generationMetrics = try container.decodeIfPresent(
      ChatGenerationMetrics.self,
      forKey: .generationMetrics
    )
    deliveryStatus = try container.decodeIfPresent(
      DeliveryStatus.self,
      forKey: .deliveryStatus,
      default: .complete
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(content, forKey: .content)
    try container.encode(modelProjectionPolicy, forKey: .modelProjectionPolicy)
    try container.encode(attachments, forKey: .attachments)
    try container.encodeIfPresent(generationMetrics, forKey: .generationMetrics)
    try container.encode(deliveryStatus, forKey: .deliveryStatus)
  }
}

nonisolated extension AssistantTurnMessage {
  public var modelProjectedContent: String? {
    switch modelProjectionPolicy {
    case .visibleContent:
      return content
    case .override(let content):
      return content
    case .excluded:
      return nil
    }
  }
}

public struct AssistantThinkingMessage: Codable, Identifiable, Equatable, Sendable {
  public enum DeliveryStatus: String, Codable, Equatable, Sendable {
    case complete
    case streaming
    case cancelled
  }

  public let id: UUID
  public var content: String
  public var deliveryStatus: DeliveryStatus
  public var startedAt: Date?
  public var completedAt: Date?

  public init(
    id: UUID = UUID(),
    content: String,
    deliveryStatus: DeliveryStatus = .complete,
    startedAt: Date? = nil,
    completedAt: Date? = nil
  ) {
    self.id = id
    self.content = content
    self.deliveryStatus = deliveryStatus
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  public var reasoningDuration: TimeInterval? {
    guard let startedAt, let completedAt else {
      return nil
    }
    return max(0, completedAt.timeIntervalSince(startedAt))
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case content
    case deliveryStatus
    case startedAt
    case completedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
    deliveryStatus = try container.decodeIfPresent(
      DeliveryStatus.self,
      forKey: .deliveryStatus,
      default: .complete
    )
    startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
    completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(content, forKey: .content)
    try container.encode(deliveryStatus, forKey: .deliveryStatus)
    try container.encodeIfPresent(startedAt, forKey: .startedAt)
    try container.encodeIfPresent(completedAt, forKey: .completedAt)
  }
}

public enum ChatTurnStatus: String, Codable, Equatable, Sendable {
  case running
  case awaitingApproval
  case awaitingUserAnswer
  case completed
  case cancelled
  case failed
}

public enum ChatTurnModelContextPolicy: String, Codable, Equatable, Sendable {
  case included
  case excluded
}

nonisolated extension ChatTurnItem {
  public var messageID: UUID? {
    switch self {
    case .userMessage(let message):
      message.id
    case .assistantThinking(let message):
      message.id
    case .assistantMessage(let message):
      message.id
    case .tool(let record):
      record.id
    }
  }

  public var userContent: String? {
    guard case .userMessage(let message) = self else {
      return nil
    }
    return message.content
  }
}

nonisolated extension ToolResultModelMessage {
  var completedState: ToolCallState {
    switch payload.preview.status {
    case .success:
      .completed(payload)
    case .denied:
      .denied(payload)
    case .failed:
      .failed(payload)
    }
  }
}
