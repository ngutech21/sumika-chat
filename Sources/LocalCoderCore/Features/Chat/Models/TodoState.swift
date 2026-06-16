import Foundation

public struct TodoState: Codable, Equatable, Sendable {
  public var items: [TodoItem]
  public var updatedAt: Date

  public init(items: [TodoItem], updatedAt: Date = Date()) {
    self.items = items
    self.updatedAt = updatedAt
  }
}

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var content: String
  public var status: TodoStatus

  public init(id: String, content: String, status: TodoStatus) {
    self.id = id
    self.content = content
    self.status = status
  }
}

public enum TodoStatus: String, Codable, CaseIterable, Equatable, Sendable {
  case pending
  case inProgress
  case completed
  case blocked

  public var displayName: String {
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

public enum TodoStateValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalidItemCount(Int)
  case emptyContent(id: String)
  case contentTooLong(id: String, maxCharacters: Int)
  case multipleInProgress
  case unsupportedTodoWriteStatus(id: String, status: TodoStatus)

  public var errorDescription: String? {
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

public struct TodoStateValidator: Sendable {
  public var minimumItemCount: Int
  public var maximumItemCount: Int
  public var maximumContentCharacters: Int

  public init(
    minimumItemCount: Int = 2,
    maximumItemCount: Int = 6,
    maximumContentCharacters: Int = 120
  ) {
    self.minimumItemCount = minimumItemCount
    self.maximumItemCount = maximumItemCount
    self.maximumContentCharacters = maximumContentCharacters
  }

  public func validate(_ items: [TodoItem]) throws {
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

public enum TodoPromptRenderer {
  public static func compactPlanBlock(for state: TodoState?) -> String? {
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
