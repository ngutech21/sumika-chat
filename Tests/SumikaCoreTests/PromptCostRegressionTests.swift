import Foundation
import Testing

@testable import SumikaCore

struct PromptCostRegressionTests {
  @Test
  func canonicalAgentRunsMatchPromptCostBaseline() throws {
    let scenarios = PromptCostScenario.canonicalAgentRuns
    let measured = try scenarios.map(PromptCostMeasurement.measure(_:))
    let expectedByName = Dictionary(
      uniqueKeysWithValues: PromptCostBaseline.current.map { ($0.name, $0) }
    )

    if ProcessInfo.processInfo.environment["SUMIKA_PRINT_PROMPT_COST"] == "1" {
      print(PromptCostMeasurement.report(measured, baselineByName: expectedByName))
    }

    #expect(measured.count == 4)
    for measurement in measured {
      let expected = expectedByName[measurement.name]
      #expect(expected != nil)
      #expect(measurement == expected)
    }
  }
}

private struct PromptCostScenario {
  let name: String
  let userPrompt: String
  let steps: [PromptCostToolStep]

  static let canonicalAgentRuns: [PromptCostScenario] = [
    listThenRead,
    readEditTest,
    failedCommandDiagnostics,
    longToolLoop,
  ]

  private static let listThenRead = PromptCostScenario(
    name: "list_files_read_file",
    userPrompt: "List the project files and inspect Sources/App.swift.",
    steps: [
      .listFiles(ordinal: 1),
      .readAppFile(ordinal: 2),
    ]
  )

  private static let readEditTest = PromptCostScenario(
    name: "read_file_edit_file_test",
    userPrompt: "Change the greeting in Sources/App.swift to Hello, Sumika and run its test.",
    steps: [
      .readAppFile(ordinal: 10),
      .editGreeting(ordinal: 11),
      .successfulTest(ordinal: 12),
    ]
  )

  private static let failedCommandDiagnostics = PromptCostScenario(
    name: "failed_command_diagnostics",
    userPrompt: "Run the tests and diagnose the compile failure.",
    steps: [
      .failedTest(ordinal: 20),
      .diagnostics(ordinal: 21),
    ]
  )

  private static let longToolLoop = PromptCostScenario(
    name: "long_tool_loop",
    userPrompt:
      "Find the greeting implementation, update it and its test, then verify the complete change.",
    steps: [
      .listFiles(ordinal: 30),
      .searchGreeting(ordinal: 31),
      .readAppFile(ordinal: 32),
      .editGreeting(ordinal: 33),
      .failedTest(ordinal: 34),
      .diagnostics(ordinal: 35),
      .readGreetingTest(ordinal: 36),
      .editGreetingTest(ordinal: 37),
      .successfulTest(ordinal: 38),
    ]
  )
}

private struct PromptCostToolStep {
  let request: ToolCallRequest
  let result: ToolResultPayload
  let failed: Bool
  let followUpNotice: String

  static func listFiles(ordinal: Int) -> PromptCostToolStep {
    make(
      ordinal: ordinal,
      payload: .listFiles(ListFilesInput(path: ".")),
      arguments: ["path": .string(".")],
      result: .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(rawValue: "Package.swift"),
              kind: .file
            ),
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(rawValue: "Sources"),
              kind: .directory
            ),
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
              kind: .file
            ),
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(rawValue: "Tests"),
              kind: .directory
            ),
          ]
        ))
    )
  }

  static func searchGreeting(ordinal: Int) -> PromptCostToolStep {
    make(
      ordinal: ordinal,
      payload: .searchFiles(
        SearchFilesInput(pattern: "greeting", path: "Sources", include: "*.swift")
      ),
      arguments: [
        "pattern": .string("greeting"),
        "path": .string("Sources"),
        "include": .string("*.swift"),
      ],
      result: .searchFiles(
        SearchFilesResult(
          root: WorkspaceRelativePath(rawValue: "Sources"),
          pattern: "greeting",
          matches: [
            SearchFileMatch(
              path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
              line: 4,
              snippet: "let greeting = \"Hello\""
            )
          ]
        ))
    )
  }

  static func readAppFile(ordinal: Int) -> PromptCostToolStep {
    let path = "Sources/App.swift"
    return make(
      ordinal: ordinal,
      payload: .readFile(ReadFileInput(path: path)),
      arguments: ["path": .string(path)],
      result: .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: path),
          content: ToolTextOutput(
            text: """
              import Foundation

              struct App {
                let greeting = "Hello"
              }
              """
          )
        ))
    )
  }

  static func readGreetingTest(ordinal: Int) -> PromptCostToolStep {
    let path = "Tests/GreetingTests.swift"
    return make(
      ordinal: ordinal,
      payload: .readFile(ReadFileInput(path: path)),
      arguments: ["path": .string(path)],
      result: .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: path),
          content: ToolTextOutput(
            text: """
              import Testing
              @testable import App

              @Test func greeting() {
                #expect(App().greeting == "Hello")
              }
              """
          )
        ))
    )
  }

  static func editGreeting(ordinal: Int) -> PromptCostToolStep {
    let path = "Sources/App.swift"
    let oldText = "let greeting = \"Hello\""
    let newText = "let greeting = \"Hello, Sumika\""
    return make(
      ordinal: ordinal,
      payload: .editFile(EditFileInput(path: path, oldText: oldText, newText: newText)),
      arguments: [
        "path": .string(path),
        "old_text": .string(oldText),
        "new_text": .string(newText),
      ],
      result: .editFile(
        .success(
          path: WorkspaceRelativePath(rawValue: path),
          diff: """
            -  let greeting = "Hello"
            +  let greeting = "Hello, Sumika"
            """,
          matchStrategy: .exact
        ))
    )
  }

  static func editGreetingTest(ordinal: Int) -> PromptCostToolStep {
    let path = "Tests/GreetingTests.swift"
    let oldText = "#expect(App().greeting == \"Hello\")"
    let newText = "#expect(App().greeting == \"Hello, Sumika\")"
    return make(
      ordinal: ordinal,
      payload: .editFile(EditFileInput(path: path, oldText: oldText, newText: newText)),
      arguments: [
        "path": .string(path),
        "old_text": .string(oldText),
        "new_text": .string(newText),
      ],
      result: .editFile(
        .success(
          path: WorkspaceRelativePath(rawValue: path),
          diff: """
            -  #expect(App().greeting == "Hello")
            +  #expect(App().greeting == "Hello, Sumika")
            """,
          matchStrategy: .exact
        ))
    )
  }

  static func failedTest(ordinal: Int) -> PromptCostToolStep {
    let command = "xcrun swift test"
    let outputRef = "cmd_failure1"
    return make(
      ordinal: ordinal,
      payload: .runCommand(
        RunCommandInput(command: command, timeoutSeconds: 120, reason: "Verify the change.")
      ),
      arguments: [
        "command": .string(command),
        "timeoutSeconds": .number(120),
        "reason": .string("Verify the change."),
      ],
      result: .runCommand(
        RunCommandResult(
          command: command,
          timeoutSeconds: 120,
          exitCode: 1,
          durationMs: 842,
          stdout: ToolTextOutput(text: "Building for debugging..."),
          stderr: ToolTextOutput(
            text:
              "Sources/App.swift:4:18: error: cannot find 'message' in scope"
          ),
          outputRef: outputRef
        )),
      failed: true
    )
  }

  static func diagnostics(ordinal: Int) -> PromptCostToolStep {
    let outputRef = "cmd_failure1"
    return make(
      ordinal: ordinal,
      payload: .workspaceDiagnostics(WorkspaceDiagnosticsInput(outputRef: outputRef)),
      arguments: ["outputRef": .string(outputRef)],
      result: .workspaceDiagnostics(
        WorkspaceDiagnosticsResult(
          outputRef: outputRef,
          diagnostics: [
            WorkspaceDiagnostic(
              path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
              line: 4,
              column: 18,
              severity: .error,
              message: "cannot find 'message' in scope"
            )
          ]
        ))
    )
  }

  static func successfulTest(ordinal: Int) -> PromptCostToolStep {
    let command = "xcrun swift test --filter GreetingTests"
    return make(
      ordinal: ordinal,
      payload: .runCommand(
        RunCommandInput(command: command, timeoutSeconds: 120, reason: "Verify the change.")
      ),
      arguments: [
        "command": .string(command),
        "timeoutSeconds": .number(120),
        "reason": .string("Verify the change."),
      ],
      result: .runCommand(
        RunCommandResult(
          command: command,
          timeoutSeconds: 120,
          exitCode: 0,
          durationMs: 716,
          stdout: ToolTextOutput(
            text: "Test Suite 'GreetingTests' passed.\nExecuted 1 test, with 0 failures."
          ),
          stderr: ToolTextOutput(text: "")
        ))
    )
  }

  private static func make(
    ordinal: Int,
    payload: ToolCallPayload,
    arguments: ToolCallArguments,
    result: ToolResultPayload,
    failed: Bool = false
  ) -> PromptCostToolStep {
    let id = fixtureUUID(
      String(format: "00000000-0000-0000-0000-%012d", ordinal)
    )
    let request = ToolCallRequest.validated(
      raw: RawToolCallRequest(
        id: id,
        workspaceID: fixtureUUID("10000000-0000-0000-0000-000000000001"),
        sessionID: fixtureUUID("20000000-0000-0000-0000-000000000002"),
        toolName: payload.toolName,
        arguments: arguments,
        createdAt: Date(timeIntervalSince1970: 0)
      ),
      payload: payload
    )
    return PromptCostToolStep(
      request: request,
      result: result,
      failed: failed,
      followUpNotice:
        "Use this tool result. Call another necessary tool, or finish_task if done."
    )
  }

  private static func fixtureUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
      preconditionFailure("Invalid prompt-cost fixture UUID: \(value)")
    }
    return uuid
  }
}

private struct PromptCostSnapshot: Equatable {
  let name: String
  let toolCount: Int
  let systemPromptBytes: Int
  let toolSchemaBytes: Int
  let conversationBytes: Int
  let toolCallBytes: Int
  let toolResultBytes: Int
  let totalBytes: Int
  let estimatedTokens: Int
  let checkpointEstimatedTokens: [Int]
}

private enum PromptCostMeasurement {
  private struct EncodedToolCall: Encodable {
    let id: String
    let name: String
    let arguments: ToolCallArguments
  }

  static func measure(_ scenario: PromptCostScenario) throws -> PromptCostSnapshot {
    let registry = ToolExecutorRegistry.codingAgent.toolRegistry
    let systemPrompt = ToolPromptPolicy().systemPrompt(
      basePrompt: ChatPromptDefaults.agentSystemPrompt,
      mode: .enabled(true),
      toolRegistry: registry
    )
    let systemPromptBytes = systemPrompt.utf8.count
    let toolSchemaBytes = try encodedBytes(registry.tools.map(\.functionSchema))
    let fixedBytes = systemPromptBytes + toolSchemaBytes
    var checkpointEstimatedTokens: [Int] = []
    var finalProjection = ModelPromptProjection()
    var finalToolCallBytes = 0

    for stepCount in 1...scenario.steps.count {
      let steps = Array(scenario.steps.prefix(stepCount))
      let projection = projection(for: scenario, steps: steps)
      let conversationBytes = projection.entries.reduce(0) {
        $0 + $1.frozenContent.content.utf8.count
      }
      let toolCallBytes = try steps.reduce(0) { total, step in
        total + (try encodedToolCallBytes(step.request))
      }
      checkpointEstimatedTokens.append(
        estimatedTokens(forBytes: fixedBytes + conversationBytes + toolCallBytes)
      )
      finalProjection = projection
      finalToolCallBytes = toolCallBytes
    }

    let conversationBytes = finalProjection.entries.reduce(0) {
      $0 + $1.frozenContent.content.utf8.count
    }
    let toolResultBytes = finalProjection.entries.reduce(0) { total, entry in
      guard case .toolObservation = entry.body else {
        return total
      }
      return total + entry.frozenContent.content.utf8.count
    }
    let totalBytes = fixedBytes + conversationBytes + finalToolCallBytes

    return PromptCostSnapshot(
      name: scenario.name,
      toolCount: scenario.steps.count,
      systemPromptBytes: systemPromptBytes,
      toolSchemaBytes: toolSchemaBytes,
      conversationBytes: conversationBytes,
      toolCallBytes: finalToolCallBytes,
      toolResultBytes: toolResultBytes,
      totalBytes: totalBytes,
      estimatedTokens: estimatedTokens(forBytes: totalBytes),
      checkpointEstimatedTokens: checkpointEstimatedTokens
    )
  }

  static func report(
    _ measurements: [PromptCostSnapshot],
    baselineByName: [String: PromptCostSnapshot]
  ) -> String {
    var lines = [
      "Prompt cost regression report",
      "Tokens are the stable ceil(UTF-8 bytes / 4) estimate; no model is loaded.",
    ]
    for measurement in measurements {
      let baseline = baselineByName[measurement.name]
      let delta = measurement.estimatedTokens - (baseline?.estimatedTokens ?? 0)
      let signedDelta = delta >= 0 ? "+\(delta)" : String(delta)
      lines.append(
        "\(measurement.name): tools=\(measurement.toolCount) "
          + "system=\(measurement.systemPromptBytes)B "
          + "schemas=\(measurement.toolSchemaBytes)B "
          + "conversation=\(measurement.conversationBytes)B "
          + "tool_calls=\(measurement.toolCallBytes)B "
          + "tool_results=\(measurement.toolResultBytes)B "
          + "total=\(measurement.totalBytes)B "
          + "estimated_tokens=\(measurement.estimatedTokens) "
          + "delta=\(signedDelta) "
          + "checkpoints=\(measurement.checkpointEstimatedTokens)"
      )
    }
    return lines.joined(separator: "\n")
  }

  private static func projection(
    for scenario: PromptCostScenario,
    steps: [PromptCostToolStep]
  ) -> ModelPromptProjection {
    var items: [ChatTurnItem] = [
      .userMessage(
        UserTurnMessage(
          content: scenario.userPrompt,
          promptContext: .empty(.focusedFileDefault)
        ))
    ]
    for step in steps {
      items.append(
        .assistantMessage(
          AssistantTurnMessage(content: "", deliveryStatus: .cancelled)
        ))
      items.append(
        .tool(
          ToolCallRecord(
            request: step.request,
            evaluation: ToolPermissionEvaluation(
              decision: .allowed,
              reason: "Allowed by canonical prompt-cost fixture.",
              riskLevel: .low
            ),
            state: step.failed ? .failed(step.result) : .completed(step.result),
            modelFollowUpNotice: step.followUpNotice
          )
        ))
    }
    let turn = ChatTurn(
      status: .completed,
      items: items,
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    return ChatModelContextBuilder().transcript(from: ChatSession(turns: [turn]))
  }

  private static func encodedToolCallBytes(_ request: ToolCallRequest) throws -> Int {
    try encodedBytes(
      EncodedToolCall(
        id: RuntimeToolCallID.string(for: request.id),
        name: request.toolName.rawValue,
        arguments: request.rawArguments
      ))
  }

  private static func encodedBytes<T: Encodable>(_ value: T) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value).count
  }

  private static func estimatedTokens(forBytes bytes: Int) -> Int {
    Int(ceil(Double(bytes) / 4.0))
  }
}

private enum PromptCostBaseline {
  static let current: [PromptCostSnapshot] = [
    PromptCostSnapshot(
      name: "list_files_read_file",
      toolCount: 2,
      systemPromptBytes: 3_825,
      toolSchemaBytes: 10_107,
      conversationBytes: 798,
      toolCallBytes: 197,
      toolResultBytes: 745,
      totalBytes: 14_927,
      estimatedTokens: 3_732,
      checkpointEstimatedTokens: [3_615, 3_732]
    ),
    PromptCostSnapshot(
      name: "read_file_edit_file_test",
      toolCount: 3,
      systemPromptBytes: 3_825,
      toolSchemaBytes: 10_107,
      conversationBytes: 1_292,
      toolCallBytes: 480,
      toolResultBytes: 1_217,
      totalBytes: 15_704,
      estimatedTokens: 3_926,
      checkpointEstimatedTokens: [3_620, 3_766, 3_926]
    ),
    PromptCostSnapshot(
      name: "failed_command_diagnostics",
      toolCount: 2,
      systemPromptBytes: 3_825,
      toolSchemaBytes: 10_107,
      conversationBytes: 1_484,
      toolCallBytes: 279,
      toolResultBytes: 1_437,
      totalBytes: 15_695,
      estimatedTokens: 3_924,
      checkpointEstimatedTokens: [3_798, 3_924]
    ),
    PromptCostSnapshot(
      name: "long_tool_loop",
      toolCount: 9,
      systemPromptBytes: 3_825,
      toolSchemaBytes: 10_107,
      conversationBytes: 4_434,
      toolCallBytes: 1_326,
      toolResultBytes: 4_344,
      totalBytes: 19_692,
      estimatedTokens: 4_923,
      checkpointEstimatedTokens: [3_624, 3_768, 3_885, 4_032, 4_334, 4_461, 4_597, 4_763, 4_923]
    ),
  ]
}
