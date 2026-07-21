import Foundation

package struct TodoState: Codable, Equatable, Sendable {
  package var items: [TodoItem]
  package var updatedAt: Date

  package init(items: [TodoItem], updatedAt: Date = Date()) {
    self.items = items
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case items
    case updatedAt
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    items = try container.decodeLossyArray([TodoItem].self, forKey: .items)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt, default: Date())
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
    try container.encode(updatedAt, forKey: .updatedAt)
  }
}

package struct TodoItem: Codable, Identifiable, Equatable, Sendable {
  package var id: String
  package var content: String
  package var status: TodoStatus

  package init(id: String, content: String, status: TodoStatus) {
    self.id = id
    self.content = content
    self.status = status
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case content
    case status
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id, default: UUID().uuidString)
    content = try container.decodeIfPresent(String.self, forKey: .content, default: "")
    status = try container.decodeIfPresent(TodoStatus.self, forKey: .status, default: .pending)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(content, forKey: .content)
    try container.encode(status, forKey: .status)
  }
}

package enum TodoStatus: String, Codable, CaseIterable, Equatable, Sendable {
  case pending
  case inProgress
  case completed
  case blocked

  package var displayName: String {
    switch self {
    case .pending:
      "Pending"
    case .inProgress:
      "In progress"
    case .completed:
      "Completed"
    case .blocked:
      "Blocked"
    }
  }
}

internal enum TodoStateValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalidItemCount(Int)
  case emptyContent(id: String)
  case contentTooLong(id: String, maxCharacters: Int)
  case multipleInProgress
  case unsupportedTodoWriteStatus(id: String, status: TodoStatus)

  package var errorDescription: String? {
    switch self {
    case .invalidItemCount(let count):
      "todo_write requires 2 to 6 items; received \(count)."
    case .emptyContent(let id):
      "todo_write item \(id) content must not be empty."
    case .contentTooLong(let id, let maxCharacters):
      "todo_write item \(id) content must be \(maxCharacters) characters or fewer."
    case .multipleInProgress:
      "todo_write allows at most one inProgress item."
    case .unsupportedTodoWriteStatus(let id, let status):
      "todo_write item \(id) status must be pending or completed; received \(status.rawValue)."
    }
  }
}

internal struct TodoStateValidator: Sendable {
  package var minimumItemCount: Int
  package var maximumItemCount: Int
  package var maximumContentCharacters: Int

  package init(
    minimumItemCount: Int = 2,
    maximumItemCount: Int = 6,
    maximumContentCharacters: Int = 120
  ) {
    self.minimumItemCount = minimumItemCount
    self.maximumItemCount = maximumItemCount
    self.maximumContentCharacters = maximumContentCharacters
  }

  package func validate(_ items: [TodoItem]) throws {
    guard items.count >= minimumItemCount && items.count <= maximumItemCount else {
      throw TodoStateValidationError.invalidItemCount(items.count)
    }

    var inProgressCount = 0
    for item in items {
      let trimmedContent = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedContent.isEmpty else {
        throw TodoStateValidationError.emptyContent(id: item.id)
      }
      guard trimmedContent.count <= maximumContentCharacters else {
        throw TodoStateValidationError.contentTooLong(
          id: item.id,
          maxCharacters: maximumContentCharacters
        )
      }
      if item.status == .inProgress {
        inProgressCount += 1
      }
    }

    guard inProgressCount <= 1 else {
      throw TodoStateValidationError.multipleInProgress
    }
  }
}

internal enum TodoPromptRenderer {
  package static func compactPlanBlock(for state: TodoState?) -> String? {
    guard let state, !state.items.isEmpty else {
      return nil
    }

    let lines = state.items.map { item in
      "- [\(statusMarker(for: item.status))] \(item.content)"
    }

    return """
      Current plan:
      \(lines.joined(separator: "\n"))
      """
  }

  private static func statusMarker(for status: TodoStatus) -> String {
    status.rawValue
  }
}
