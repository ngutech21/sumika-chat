import Foundation

public struct ChatSession: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var selectedModelID: ManagedModel.ID
  public var modelContextSnapshot: ModelContextSnapshot
  public var toolCalls: [ToolCallRecord]
  public var turns: [ChatTurn]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode
  public var pendingAttachments: [ChatAttachment]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String = "New Session",
    selectedModelID: ManagedModel.ID = ManagedModelCatalog.defaultModelID,
    modelContextSnapshot: ModelContextSnapshot = ModelContextSnapshot(),
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurn] = [],
    pendingAttachments: [ChatAttachment] = [],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String = ChatPromptDefaults.codingSystemPrompt,
    generationSettings: ChatGenerationSettings = .codingDefault,
    interactionMode: WorkspaceInteractionMode = .chat,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.selectedModelID = selectedModelID
    self.modelContextSnapshot = modelContextSnapshot
    self.toolCalls = toolCalls
    self.turns = turns
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
    self.pendingAttachments = pendingAttachments
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let codingDefault = ChatSession()

  public static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
    lhs.id == rhs.id
      && lhs.title == rhs.title
      && lhs.selectedModelID == rhs.selectedModelID
      && lhs.modelContextSnapshot == rhs.modelContextSnapshot
      && lhs.toolCalls == rhs.toolCalls
      && lhs.turns == rhs.turns
      && lhs.focusedFileState == rhs.focusedFileState
      && lhs.systemPrompt == rhs.systemPrompt
      && lhs.generationSettings == rhs.generationSettings
      && lhs.interactionMode == rhs.interactionMode
      && lhs.createdAt == rhs.createdAt
      && lhs.updatedAt == rhs.updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case selectedModelID
    case modelContextSnapshot
    case toolCalls
    case turns
    case focusedFileState
    case systemPrompt
    case generationSettings
    case interactionMode
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    selectedModelID = try container.decode(ManagedModel.ID.self, forKey: .selectedModelID)
    modelContextSnapshot = try container.decode(
      ModelContextSnapshot.self,
      forKey: .modelContextSnapshot
    )
    toolCalls = try container.decode([ToolCallRecord].self, forKey: .toolCalls)
    turns = try container.decode([ChatTurn].self, forKey: .turns)
    focusedFileState = try container.decode(FocusedFileState.self, forKey: .focusedFileState)
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    generationSettings = try container.decode(
      ChatGenerationSettings.self,
      forKey: .generationSettings
    )
    interactionMode = try container.decode(
      WorkspaceInteractionMode.self,
      forKey: .interactionMode
    )
    pendingAttachments = []
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(selectedModelID, forKey: .selectedModelID)
    try container.encode(modelContextSnapshot, forKey: .modelContextSnapshot)
    try container.encode(toolCalls, forKey: .toolCalls)
    try container.encode(turns, forKey: .turns)
    try container.encode(focusedFileState, forKey: .focusedFileState)
    try container.encode(systemPrompt, forKey: .systemPrompt)
    try container.encode(generationSettings, forKey: .generationSettings)
    try container.encode(interactionMode, forKey: .interactionMode)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  public func turnID(containingToolCall toolCallID: ToolCallRecord.ID) -> ChatTurn.ID? {
    turns.first { turn in
      turn.items.contains { item in
        switch item {
        case .toolCall(let id), .toolResult(let id):
          id == toolCallID
        case .userMessage, .assistantMessage:
          false
        }
      }
    }?.id
  }
}
