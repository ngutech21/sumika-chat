import Foundation
import Testing

@testable import SumikaCore

struct ChatTurnTests {
  @Test
  func completedDurationUsesPersistedWallClockTimestamps() {
    let createdAt = Date(timeIntervalSinceReferenceDate: 100)
    let turn = ChatTurn(
      status: .completed,
      createdAt: createdAt,
      updatedAt: createdAt.addingTimeInterval(220)
    )

    #expect(turn.completedDuration == 220)
  }

  @Test
  func completedDurationIsUnavailableBeforeSuccessfulCompletion() {
    let createdAt = Date(timeIntervalSinceReferenceDate: 100)
    let incompleteStatuses: [ChatTurnStatus] = [
      .running, .awaitingApproval, .awaitingUserAnswer, .cancelled, .failed,
    ]

    for status in incompleteStatuses {
      let turn = ChatTurn(
        status: status,
        createdAt: createdAt,
        updatedAt: createdAt.addingTimeInterval(220)
      )
      #expect(turn.completedDuration == nil)
    }
  }

  @Test
  func completedDurationClampsClockRollbackToZero() {
    let createdAt = Date(timeIntervalSinceReferenceDate: 220)
    let turn = ChatTurn(
      status: .completed,
      createdAt: createdAt,
      updatedAt: createdAt.addingTimeInterval(-20)
    )

    #expect(turn.completedDuration == 0)
  }
}
