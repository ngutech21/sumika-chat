import Foundation
import SumikaCore
import Testing

@Suite(.serialized)
@MainActor
struct AgentCompositionIntegrationTests {
  @Test
  func corePackageBuildsAndRunsAgentWithoutAppOrMLXTargets() async throws {
    let testRoot = FileManager.default.temporaryDirectory.appending(
      path: "sumika-core-agent-composition-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let modelDirectory = testRoot.appending(path: "model", directoryHint: .isDirectory)
    let workspaceDirectory = testRoot.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: modelDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: workspaceDirectory,
      withIntermediateDirectories: true
    )
    try "Core package integration test.\n".write(
      to: workspaceDirectory.appending(path: "README.md", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    defer {
      try? FileManager.default.removeItem(at: testRoot)
    }

    let runtime = AgentCompositionRuntime()
    let selectedModel = ManagedModelCatalog.defaultModel
    let settings = StoredModelSettings(
      modeSettings: selectedModel.defaultModeSettings,
      contextTokenLimit: selectedModel.defaultContextTokenLimit
    )
    let modelSettingsStore = ModelSettingsStore(
      settingsURL: testRoot.appending(path: "model-settings.json", directoryHint: .notDirectory)
    )
    let session = ChatSession(
      selectedModelID: selectedModel.id,
      modeSettings: settings.modeSettings,
      interactionMode: .agent
    )
    let sumika = Sumika(
      configuration: Sumika.Configuration(
        initialSession: session,
        initialModel: selectedModel,
        modelPath: modelDirectory.path(percentEncoded: false),
        initialModelSettings: settings
      ),
      dependencies: Sumika.Dependencies(
        runtime: runtime,
        modelSettingsStore: modelSettingsStore,
        modelDownloader: UnavailableModelDownloader(),
        resourceMonitor: ProcessResourceMonitor(),
        modelAvailability: { _ in true }
      )
    )
    sumika.agent.updateConfiguration(todoWriteEnabled: true)

    sumika.models.loadSelectedModel()
    try await waitUntil {
      sumika.models.state.modelState == .ready
    }

    let workspace = Workspace(
      name: "Integration Workspace",
      rootURL: workspaceDirectory,
      sessions: [session]
    )
    #expect(
      sumika.conversation.sendMessage(
        prompt: "Read README.md and report what it contains.",
        in: workspace,
        sessionID: session.id
      )
    )

    try await waitUntil {
      !sumika.conversation.state.isGenerating
        && sumika.conversation.snapshot().turns.last?.status == .completed
    }

    let snapshot = sumika.conversation.snapshot()
    #expect(snapshot.interactionMode == .agent)
    #expect(
      snapshot.toolCalls.map(\.request.toolName) == [.readFile, .finishTask]
    )
    #expect(snapshot.toolCalls.allSatisfy { $0.status == .completed })

    let assistantContents = snapshot.turns.flatMap(\.items).compactMap { item -> String? in
      guard case .assistantMessage(let message) = item else {
        return nil
      }
      return message.content
    }
    #expect(assistantContents.last == "README.md contains the Core integration note.")

    let loadedConfiguration = await runtime.loadedConfiguration
    #expect(loadedConfiguration?.localModelDirectory == modelDirectory)
    let requestedToolNames = await runtime.requestedToolNames
    #expect(requestedToolNames.count == 2)
    #expect(requestedToolNames.allSatisfy { $0.contains(.readFile) })
    #expect(requestedToolNames.allSatisfy { $0.contains(.finishTask) })
    #expect(requestedToolNames.allSatisfy { $0.contains(.todoWrite) })
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !condition() {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for Core agent composition")
        throw AgentCompositionWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor AgentCompositionRuntime: ChatModelRuntime {
  private(set) var loadedConfiguration: ChatModelConfiguration?
  private(set) var requestedToolNames: [[ToolName]] = []
  private var streamReplyCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    loadedConfiguration = configuration
  }

  func unload() async {}

  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = settings

    requestedToolNames.append(promptPlan.toolContext?.registry.tools.map(\.name) ?? [])
    let callIndex = streamReplyCount
    streamReplyCount += 1

    let events: [ChatModelStreamEvent]
    switch callIndex {
    case 0:
      events = [
        .toolCall(
          ChatRuntimeToolCall(
            name: ToolName.readFile.rawValue,
            arguments: ["path": .string("README.md")]
          ))
      ]
    default:
      events = [
        .toolCall(
          ChatRuntimeToolCall(
            name: ToolName.finishTask.rawValue,
            arguments: [
              "status": .string(FinishTaskStatus.done.rawValue),
              "summary": .string("README.md contains the Core integration note."),
            ]
          ))
      ]
    }

    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.yield(.completed(nil))
      continuation.finish()
    }
  }
}

private struct AgentCompositionWaitTimeoutError: Error {}
