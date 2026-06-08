import Foundation
import Testing

@testable import LocalCoderCore

struct TodoStateTests {
  @Test
  func todoStateCodableRoundTrips() throws {
    let state = TodoState(
      items: [
        TodoItem(id: "inspect", content: "Inspect files", status: .completed),
        TodoItem(id: "verify", content: "Run tests", status: .pending),
      ],
      updatedAt: Date(timeIntervalSinceReferenceDate: 42)
    )

    let decoded = try JSONDecoder().decode(TodoState.self, from: JSONEncoder().encode(state))

    #expect(decoded == state)
  }

  @Test
  func todoStateValidatorEnforcesItemCountContentAndProgress() {
    let validator = TodoStateValidator(maximumContentCharacters: 12)
    let validItems = [
      TodoItem(id: "one", content: "Inspect", status: .completed),
      TodoItem(id: "two", content: "Verify", status: .inProgress),
    ]

    do {
      try validator.validate(validItems)
    } catch {
      Issue.record("Expected valid todo items.")
    }
    #expect(throws: TodoStateValidationError.invalidItemCount(1)) {
      try validator.validate([validItems[0]])
    }
    #expect(throws: TodoStateValidationError.invalidItemCount(0)) {
      try validator.validate([])
    }
    #expect(throws: TodoStateValidationError.invalidItemCount(7)) {
      try validator.validate(
        (0..<7).map { index in
          TodoItem(id: "\(index)", content: "Item \(index)", status: .pending)
        })
    }
    #expect(throws: TodoStateValidationError.emptyContent(id: "empty")) {
      try validator.validate([
        TodoItem(id: "empty", content: " ", status: .pending),
        validItems[1],
      ])
    }
    #expect(throws: TodoStateValidationError.contentTooLong(id: "long", maxCharacters: 12)) {
      try validator.validate([
        TodoItem(id: "long", content: "This is too long", status: .pending),
        validItems[1],
      ])
    }
    #expect(throws: TodoStateValidationError.multipleInProgress) {
      try validator.validate([
        TodoItem(id: "one", content: "Inspect", status: .inProgress),
        TodoItem(id: "two", content: "Verify", status: .inProgress),
      ])
    }
  }

  @Test
  func compactPlanBlockRendersShortStatusList() {
    let state = TodoState(items: [
      TodoItem(id: "inspect", content: "Inspect files", status: .completed),
      TodoItem(id: "verify", content: "Run tests", status: .inProgress),
    ])

    let block = TodoPromptRenderer.compactPlanBlock(for: state)

    #expect(
      block
        == """
        Current plan:
        - [completed] Inspect files
        - [inProgress] Run tests
        """)
    #expect(TodoPromptRenderer.compactPlanBlock(for: nil) == nil)
  }
}
