import Foundation

public struct ChatSession: Codable, Identifiable, Equatable, Sendable {
  public static let defaultTitle = "New Session"

  public let id: UUID
  public var title: String
  public var selectedModelID: ManagedModel.ID
  public var toolCalls: [ToolCallRecord] {
    turns.flatMap(\.items).compactMap { item in
      guard case .tool(let record) = item else {
        return nil
      }
      return record
    }
  }
  public internal(set) var turns: [ChatTurn]
  public var focusedFileState: FocusedFileState
  public var modeSettings: ChatModeSettingsSet
  public var activeModeSettings: ChatModeSettings {
    get { modeSettings[interactionMode] }
    set { modeSettings[interactionMode] = newValue }
  }
  public var systemPrompt: String {
    get { activeModeSettings.systemPrompt }
    set { activeModeSettings.systemPrompt = newValue }
  }
  public var generationSettings: ChatGenerationSettings {
    get { activeModeSettings.generationSettings }
    set { activeModeSettings.generationSettings = newValue }
  }
  public var interactionMode: WorkspaceInteractionMode
  public private(set) var selectedMCPServerIDs: [UUID]
  public var todoState: TodoState?
  public var pendingAttachments: [ChatAttachment]
  public var activeAttachmentContext: ActiveAttachmentContext
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String = ChatSession.defaultTitle,
    selectedModelID: ManagedModel.ID = ManagedModelCatalog.defaultModelID,
    turns: [ChatTurn] = [],
    pendingAttachments: [ChatAttachment] = [],
    focusedFileState: FocusedFileState = .empty,
    modeSettings: ChatModeSettingsSet = .defaultSettings,
    interactionMode: WorkspaceInteractionMode = .chat,
    selectedMCPServerIDs: [UUID] = [],
    todoState: TodoState? = nil,
    activeAttachmentContext: ActiveAttachmentContext = .empty,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.selectedModelID = selectedModelID
    self.turns = turns
    self.focusedFileState = focusedFileState
    self.interactionMode = interactionMode
    self.selectedMCPServerIDs = Self.uniqueIDsPreservingOrder(selectedMCPServerIDs)
    self.modeSettings = modeSettings
    self.todoState = todoState
    self.pendingAttachments = pendingAttachments
    self.activeAttachmentContext = activeAttachmentContext
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let defaultSession = ChatSession()

  public static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
    lhs.id == rhs.id
      && lhs.title == rhs.title
      && lhs.selectedModelID == rhs.selectedModelID
      && lhs.turns == rhs.turns
      && lhs.focusedFileState == rhs.focusedFileState
      && lhs.modeSettings == rhs.modeSettings
      && lhs.interactionMode == rhs.interactionMode
      && lhs.selectedMCPServerIDs == rhs.selectedMCPServerIDs
      && lhs.todoState == rhs.todoState
      && lhs.activeAttachmentContext == rhs.activeAttachmentContext
      && lhs.createdAt == rhs.createdAt
      && lhs.updatedAt == rhs.updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case selectedModelID
    case turns
    case focusedFileState
    case modeSettings
    case interactionMode
    case selectedMCPServerIDs
    case todoState
    case activeAttachmentContext
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id, default: UUID())
    title = try container.decodeIfPresent(String.self, forKey: .title, default: Self.defaultTitle)
    selectedModelID = try container.decodeIfPresent(
      ManagedModel.ID.self,
      forKey: .selectedModelID,
      default: ManagedModelCatalog.defaultModelID
    )
    turns = Self.resolvingInterruptedStreams(
      in: try container.decodeLossyArray([ChatTurn].self, forKey: .turns)
    )
    focusedFileState = try container.decodeIfPresent(
      FocusedFileState.self,
      forKey: .focusedFileState,
      default: .empty
    )
    interactionMode = try container.decodeIfPresent(
      WorkspaceInteractionMode.self,
      forKey: .interactionMode,
      default: .chat
    )
    selectedMCPServerIDs = Self.uniqueIDsPreservingOrder(
      try container.decode([UUID].self, forKey: .selectedMCPServerIDs)
    )
    modeSettings = try container.decodeIfPresent(
      ChatModeSettingsSet.self,
      forKey: .modeSettings,
      default: .defaultSettings
    )
    todoState = try container.decodeIfPresent(TodoState.self, forKey: .todoState)
    pendingAttachments = []
    activeAttachmentContext = try container.decodeIfPresent(
      ActiveAttachmentContext.self,
      forKey: .activeAttachmentContext,
      default: .empty
    )
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt, default: Date())
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt, default: createdAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(selectedModelID, forKey: .selectedModelID)
    try container.encode(turns, forKey: .turns)
    try container.encode(focusedFileState, forKey: .focusedFileState)
    try container.encode(modeSettings, forKey: .modeSettings)
    try container.encode(interactionMode, forKey: .interactionMode)
    try container.encode(selectedMCPServerIDs, forKey: .selectedMCPServerIDs)
    try container.encode(todoState, forKey: .todoState)
    try container.encode(activeAttachmentContext, forKey: .activeAttachmentContext)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  /// A persisted `.streaming` delivery status means generation was interrupted
  /// by a crash or hard quit — there is no live stream after a reload, so a
  /// loaded turn must never resurface as "Generating…". Preserve append-only
  /// item ordering and mark interrupted assistant messages as cancelled.
  private static func resolvingInterruptedStreams(in turns: [ChatTurn]) -> [ChatTurn] {
    turns.map { turn in
      var turn = turn
      turn.markStreamingAssistantMessagesCancelled(at: turn.updatedAt)
      return turn
    }
  }

  public func turnID(containingToolCall toolCallID: ToolCallRecord.ID) -> ChatTurn.ID? {
    turns.first { turn in
      turn.containsToolCall(id: toolCallID)
    }?.id
  }

  public func toolCallRecord(id: ToolCallRecord.ID) -> ToolCallRecord? {
    turns.lazy.compactMap { $0.toolCallRecord(id: id) }.first
  }

  public mutating func setSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    selectedMCPServerIDs = Self.uniqueIDsPreservingOrder(serverIDs)
  }

  private static func uniqueIDsPreservingOrder(_ serverIDs: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    return serverIDs.filter { seen.insert($0).inserted }
  }
}
