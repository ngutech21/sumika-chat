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
    #expect(!options.networkPolicy.webEnabled)
    #expect(options.reasoningLevel == nil)
    #expect(!options.worker)
  }

  @Test
  func workerIsAnExplicitBooleanFlag() throws {
    let options = try EvaluationOptions(
      arguments: arguments + ["--worker"], environment: environment)
    #expect(options.worker)
    for flags in [["--worker", "true"], ["--worker", "--worker"]] {
      #expect(throws: EvaluationError.self) {
        try EvaluationOptions(arguments: arguments + flags, environment: environment)
      }
    }
  }

  @MainActor
  @Test
  func standaloneDeadlineAndHarborCancellation() async throws {
    for (value, seconds) in [(nil, 600.0), ("42", 42.0), ("86400", 86_400.0), ("harbor", nil)] {
      let flags = Array(arguments.dropLast(2)) + (value.map { ["--timeout-seconds", $0] } ?? [])
      let options = try EvaluationOptions(arguments: flags, environment: environment)
      #expect(options.timeoutSeconds == seconds)
      let cancellation = EvaluationCancellation()
      let runner = EvaluationRunner(options: options, cancellation: cancellation)
      let start = ContinuousClock.now
      let expired = start.advanced(by: .seconds(-90_000))
      #expect(runner.stopOutcome(since: start) == nil)
      #expect(runner.stopOutcome(since: expired) == (seconds == nil ? nil : .timedOut))

      let task = Task { runner.stopOutcome(since: start) }
      task.cancel()
      #expect(await task.value == .cancelled)
      cancellation.requested = true
      #expect(runner.stopOutcome(since: expired) == .cancelled)
    }
  }

  @Test(arguments: ["0", "-1", "nan", "inf", "-inf", "86401", "none"])
  func rejectsInvalidTimeout(_ value: String) {
    var invalid = arguments
    invalid[11] = value
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(arguments: invalid, environment: environment)
    }
  }

  @MainActor
  @Test(arguments: [nil, "low", "medium", "xhigh"] as [String?])
  func reasoningLevelOverridesOnlyWorkSettingsAndSurvivesReload(_ level: String?) async throws {
    let model = try #require(ManagedModelCatalog.model(id: "Swift-1.5-4bit-MLX"))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsURL = directory.appending(path: "model-settings.json")
    let store = ModelSettingsStore(settingsURL: settingsURL)
    var expected = await store.settings(for: model)
    let options = try EvaluationOptions(
      arguments: arguments + (level.map { ["--reasoning-level", $0] } ?? []),
      environment: environment)
    if let level {
      let effort = try #require(ReasoningEffort(rawValue: level))
      #expect(options.reasoningLevel == effort)
      expected.modeSettings.agent.generationSettings.reasoningSelection = .effort(effort)
    } else {
      #expect(expected.modeSettings.agent.generationSettings.reasoningSelection == .effort(.medium))
    }
    let runner = EvaluationRunner(options: options, cancellation: EvaluationCancellation())
    let settings = try await runner.modelSettings(for: model, store: store)
    #expect(settings == expected)
    let reloaded = await ModelSettingsStore(settingsURL: settingsURL).settings(for: model)
    #expect(reloaded == expected)
  }

  @MainActor
  @Test
  func rejectsReasoningLevelForModelWithoutEffortSupport() async throws {
    let model = try #require(ManagedModelCatalog.model(id: "qwen3.6-27B-8bit"))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ModelSettingsStore(settingsURL: directory.appending(path: "model-settings.json"))
    let options = try EvaluationOptions(
      arguments: arguments + ["--reasoning-level", "low"], environment: environment)
    let runner = EvaluationRunner(options: options, cancellation: EvaluationCancellation())
    await #expect(throws: EvaluationError.self) {
      try await runner.modelSettings(for: model, store: store)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test(arguments: [
    ["--reasoning-level", "high"], ["--reasoning-level", ""],
    ["--reasoning-level", "off"], ["--reasoning-level"],
    ["--reasoning-level", "low", "--reasoning-level", "medium"],
  ])
  func rejectsInvalidReasoningLevels(_ flags: [String]) {
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(arguments: arguments + flags, environment: environment)
    }
  }

  @Test
  func webAvailabilityFollowsEffectiveNetworkPolicy() throws {
    for (policy, enabled) in [
      (#"{"network_mode":"public","allowed_hosts":[]}"#, true),
      (#"{"network_mode":"no-network","allowed_hosts":["example.com"]}"#, false),
      (#"{"network_mode":"allowlist","allowed_hosts":["example.com"]}"#, true),
      (#"{"network_mode":"allowlist","allowed_hosts":[]}"#, false),
      (#"{"network_mode":"allowlist"}"#, false),
    ] {
      let options = try EvaluationOptions(
        arguments: arguments + ["--network-policy", policy], environment: environment)
      #expect(options.networkPolicy.webEnabled == enabled)
      let roundTrip = try JSONDecoder().decode(
        EvaluationNetworkPolicy.self, from: JSONEncoder().encode(options.networkPolicy))
      #expect(roundTrip.networkMode == options.networkPolicy.networkMode)
      #expect(roundTrip.allowedHosts == options.networkPolicy.allowedHosts)
    }
    for policy in ["{}", #"{"network_mode":"unknown"}"#, "invalid"] {
      #expect(throws: (any Error).self) {
        try EvaluationOptions(
          arguments: arguments + ["--network-policy", policy], environment: environment)
      }
    }
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
  func rejectsMissingTokenAndDuplicateFlags() {
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(arguments: arguments, environment: [:])
    }
    #expect(throws: EvaluationError.self) {
      try EvaluationOptions(
        arguments: arguments + ["--model-id", "other"], environment: environment)
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
