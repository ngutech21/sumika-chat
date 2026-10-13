import Foundation
import SumikaCore
import Testing

@testable import SumikaEval

struct EvaluationOptionsTests {
  private let arguments = [
    "--model-id", "Swift-1.5-4bit-MLX", "--workspace-root", "/app",
    "--bridge-url", "http://127.0.0.1:8765", "--prompt-file", "/tmp/prompt.txt",
    "--output-dir", "/tmp/evaluation", "--timeout-seconds", "42",
  ]
  private let environment = ["SUMIKA_HARBOR_TOKEN": "trial-secret"]

  @Test
  func parsesExplicitTrialConfiguration() throws {
    let options = try EvaluationOptions(arguments: arguments, environment: environment)
    #expect(options.modelID == "Swift-1.5-4bit-MLX")
    #expect(options.workspaceRoot.path == "/app")
    #expect(options.timeoutSeconds == 42)
  }

  @Test(arguments: ["https://127.0.0.1:8765", "http://example.com:8765", "http://127.0.0.1"])
  func rejectsNonLoopbackOrAmbiguousBridge(_ bridge: String) {
    var invalid = arguments
    invalid[5] = bridge
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(arguments: invalid, environment: environment)
    }
  }

  @Test
  func rejectsMissingTokenDuplicateFlagsAndInvalidTimeout() {
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(arguments: arguments, environment: [:])
    }
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(
        arguments: arguments + ["--model-id", "other"], environment: environment)
    }
    var invalid = arguments
    invalid[11] = "nan"
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(arguments: invalid, environment: environment)
    }
  }

  @Test
  func userAnswerIsUnsolvedAndApprovalIsNotTerminal() {
    #expect(
      EvaluationOutcome.terminalOutcome(for: ChatTurn(status: .awaitingUserAnswer)) == .needsUser
    )
    #expect(EvaluationOutcome.terminalOutcome(for: ChatTurn(status: .awaitingApproval)) == nil)
    #expect(EvaluationOutcome.terminalOutcome(for: ChatTurn(status: .running)) == nil)
    #expect(EvaluationOutcome.terminalOutcome(for: ChatTurn(status: .failed)) == .failed)
  }
}
