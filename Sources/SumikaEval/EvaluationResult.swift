import Foundation
import SumikaCore

enum EvaluationOutcome: String, Codable, Sendable {
  case completed
  case needsUser = "needs_user"
  case failed
  case cancelled
  case timedOut = "timed_out"

  var exitCode: Int32 {
    switch self {
    case .completed: 0
    case .needsUser: 2
    case .failed: 1
    case .cancelled: 130
    case .timedOut: 124
    }
  }

  static func terminalOutcome(for turn: ChatTurn) -> Self? {
    switch turn.status {
    case .awaitingUserAnswer: .needsUser
    case .completed: .completed
    case .cancelled: .cancelled
    case .failed: .failed
    case .running, .awaitingApproval: nil
    }
  }
}

struct EvaluationResult: Codable, Sendable {
  let modelID: String
  var outcome: EvaluationOutcome
  var errorMessage: String?
  var turnID: UUID?
  var finishTaskStatus: FinishTaskStatus?
  var maxToolLoopIterations: Int?
  var contextTokenLimit: Int?

  var exitCode: Int32 { outcome.exitCode }

  var canResumeWorker: Bool {
    outcome == .completed && (finishTaskStatus == nil || finishTaskStatus == .done)
  }
}
