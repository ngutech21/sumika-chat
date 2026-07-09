import Foundation
import Testing

@testable import SumikaCore

private struct CollidingDynamicFinishTaskExecutor: DynamicToolExecutor {
  var codec: ToolCodec<FinishTaskInput> {
    FinishTaskToolExecutor.codec
  }

  func evaluatePermission(
    _ input: FinishTaskInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .denied,
      reason: "The colliding dynamic executor must never replace the built-in.",
      riskLevel: .high
    )
  }

  func run(_ input: FinishTaskInput, context: ToolContext) async -> ToolResultPayload {
    _ = input
    _ = context
    return .finishTask(
      .failed(reason: .executionError("The colliding dynamic executor ran.")))
  }
}

struct FinishTaskToolTests {
  private let validator = ToolCallRequestValidator()

  @Test
  func definitionExposesClosedStatusAndSummarySchema() {
    let definition = ToolDefinition.finishTask
    let schema = definition.functionSchema

    #expect(definition.name == .finishTask)
    #expect(definition.riskLevel == .low)
    #expect(definition.capabilities.isEmpty)
    #expect(schema.parameters.type == "object")
    #expect(schema.parameters.required == ["status", "summary"])
    #expect(schema.parameters.additionalProperties == false)
    #expect(schema.parameters.properties.keys.sorted() == ["status", "summary"])
    #expect(schema.parameters.properties["status"]?.type == .string)
    #expect(
      schema.parameters.properties["status"]?.enumValues
        == ["done", "blocked", "needs_user"])
    #expect(schema.parameters.properties["summary"]?.type == .string)
  }

  @Test
  func validatorAcceptsEveryStatusAndTrimsSummary() {
    let registry = ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false).toolRegistry

    for status in FinishTaskStatus.allCases {
      let request = validator.validate(
        rawRequest(
          arguments: [
            "status": .string(status.rawValue),
            "summary": .string("  Final summary for \(status.rawValue).\n"),
          ]),
        registry: registry
      )

      #expect(
        request.payload
          == .finishTask(
            FinishTaskInput(
              status: status,
              summary: "Final summary for \(status.rawValue)."
            )))
    }
  }

  @Test
  func validatorRejectsMissingUnknownWrongAndEmptyArguments() {
    let registry = ToolExecutorRegistry.codingAgent.toolRegistry
    let missingStatus = validator.validate(
      rawRequest(arguments: ["summary": .string("Done.")]),
      registry: registry
    )
    let missingSummary = validator.validate(
      rawRequest(arguments: ["status": .string("done")]),
      registry: registry
    )
    let invalidStatus = validator.validate(
      rawRequest(
        arguments: ["status": .string("complete"), "summary": .string("Done.")]),
      registry: registry
    )
    let wrongStatusType = validator.validate(
      rawRequest(arguments: ["status": .bool(true), "summary": .string("Done.")]),
      registry: registry
    )
    let wrongSummaryType = validator.validate(
      rawRequest(arguments: ["status": .string("done"), "summary": .number(1)]),
      registry: registry
    )
    let emptySummary = validator.validate(
      rawRequest(arguments: ["status": .string("done"), "summary": .string(" \n ")]),
      registry: registry
    )
    let unknownArgument = validator.validate(
      rawRequest(
        arguments: [
          "status": .string("done"),
          "summary": .string("Done."),
          "verification": .string("Tests pass."),
        ]),
      registry: registry
    )

    #expect(invalidReason(missingStatus) == .missingRequiredArgument("status"))
    #expect(invalidReason(missingSummary) == .missingRequiredArgument("summary"))
    #expect(
      invalidReason(invalidStatus)
        == .invalidArgumentType(
          name: "status",
          expected: "done, blocked, or needs_user"
        ))
    #expect(invalidReason(wrongStatusType) == invalidReason(invalidStatus))
    #expect(
      invalidReason(wrongSummaryType)
        == .invalidArgumentType(name: "summary", expected: "a non-empty string"))
    #expect(invalidReason(emptySummary) == invalidReason(wrongSummaryType))
    #expect(invalidReason(unknownArgument) == .unknownArguments(["verification"]))
  }

  @Test
  func callAndResultPayloadsRoundTripThroughCodable() throws {
    let callPayloads = FinishTaskStatus.allCases.map { status in
      ToolCallPayload.finishTask(
        FinishTaskInput(status: status, summary: "Summary for \(status.rawValue)."))
    }
    let resultPayloads: [ToolResultPayload] = [
      .finishTask(.success),
      .finishTask(.failed(reason: .executionError("Could not finish."))),
    ]

    let decodedCalls = try JSONDecoder().decode(
      [ToolCallPayload].self,
      from: JSONEncoder().encode(callPayloads)
    )
    let decodedResults = try JSONDecoder().decode(
      [ToolResultPayload].self,
      from: JSONEncoder().encode(resultPayloads)
    )

    #expect(decodedCalls == callPayloads)
    #expect(decodedResults == resultPayloads)
    #expect(decodedCalls.allSatisfy { $0.toolName == .finishTask })
    #expect(resultPayloads[0].preview.status == .success)
    #expect(resultPayloads[0].preview.text == "Task completion accepted.")
    #expect(resultPayloads[1].preview.status == .failed)
  }

  @Test
  func executorCompletesEveryStatusWithoutApprovalAndDefensivelyRejectsEmptySummary() async {
    let workspace = makeWorkspace()
    let executor = FinishTaskToolExecutor()
    let context = ToolContext(workspace: workspace)
    let input = FinishTaskInput(status: .done, summary: "Done.")

    let evaluation = executor.evaluatePermission(input, context: context)
    let failure = await executor.run(
      FinishTaskInput(status: .blocked, summary: " "),
      context: context
    )

    #expect(evaluation.decision == .allowed)
    #expect(evaluation.riskLevel == .low)
    for status in FinishTaskStatus.allCases {
      let result = await executor.run(
        FinishTaskInput(status: status, summary: "Finished with \(status.rawValue)."),
        context: context
      )
      #expect(result == .finishTask(.success))
    }
    guard case .finishTask(.failed(let reason)) = failure else {
      Issue.record("Expected defensive finish_task validation failure.")
      return
    }
    #expect(reason.previewStatus == .failed)
    #expect(reason.message.contains("summary"))
  }

  @Test
  func registriesExposeFinishTaskOnlyForAgentRegardlessOfTodoSetting() {
    let enabled = ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: true)
    let disabled = ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false)

    #expect(enabled.definitions.filter { $0.name == .finishTask } == [.finishTask])
    #expect(disabled.definitions.filter { $0.name == .finishTask } == [.finishTask])
    #expect(ToolExecutorRegistry.chatWeb.executor(for: .finishTask) == nil)
    #expect(ToolExecutorRegistry.readOnly.executor(for: .finishTask) == nil)
    #expect(ToolCodecCatalog.builtInCodec(for: .finishTask)?.definition == .finishTask)
  }

  @Test
  func dynamicRegistryCollisionCannotReplaceBuiltInFinishTask() async {
    let base = ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false)
    let merged = base.merging([
      AnyToolExecutor(dynamic: CollidingDynamicFinishTaskExecutor())
    ])
    let workspace = makeWorkspace()
    let record = await ToolOrchestrator(executorRegistry: merged).execute(
      request: rawRequest(
        workspace: workspace,
        arguments: ["status": .string("done"), "summary": .string("Done.")]
      ),
      workspace: workspace
    )

    #expect(merged.definitions.count == base.definitions.count)
    #expect(merged.definitions.filter { $0.name == .finishTask }.count == 1)
    #expect(merged.dynamicCodecs[.finishTask] == nil)
    #expect(record.status == .completed)
    #expect(record.evaluation.decision == .allowed)
    #expect(record.resultPayload == .finishTask(.success))
  }

  private func rawRequest(
    workspace: Workspace? = nil,
    arguments: ToolCallArguments
  ) -> RawToolCallRequest {
    RawToolCallRequest(
      workspaceID: workspace?.id ?? UUID(),
      sessionID: UUID(),
      toolName: .finishTask,
      arguments: arguments
    )
  }

  private func invalidReason(_ request: ToolCallRequest) -> InvalidToolCallReason? {
    guard case .invalid(let input) = request.payload else {
      return nil
    }
    return input.reason
  }

  private func makeWorkspace() -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "sumika-finish-task-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL))
    )
  }
}
