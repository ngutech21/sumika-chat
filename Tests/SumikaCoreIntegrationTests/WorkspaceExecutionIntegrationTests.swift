import Foundation
import SumikaCore
import SumikaTestSupport
import Testing

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-workspace-execution-tests"))
@MainActor
struct WorkspaceExecutionIntegrationTests {
  @Test
  func injectedExecutionSurvivesConfigurationAndUsesProductionToolLifecycle() async throws {
    let root = try scopedTemporaryDirectory()
    let hostFile = root.appending(path: "repair.py")
    try "HOST FILE MUST STAY UNCHANGED".write(to: hostFile, atomically: true, encoding: .utf8)
    try "HOST INSTRUCTIONS MUST NOT ENTER THE PROMPT".write(
      to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
    let backend = InMemoryWorkspaceBackend()
    let runtime = WorkspaceExecutionRuntime()
    let sumika = try await makeSumika(root: root, backend: backend, runtime: runtime)

    sumika.agent.updateConfiguration(todoWriteEnabled: true)
    sumika.agent.setSelectedMCPServerIDs([UUID()])
    #expect(try await sumika.conversation.refreshSkillCatalog() == .empty)
    try await sumika.conversation.sendMessage(
      MessageSubmission(text: "Repair repair.py and test it."))
    try await waitUntil {
      sumika.conversation.state.active?.activity == .idle
        && sumika.conversation.snapshot()?.turns.last?.status == .completed
    }

    let session = try #require(sumika.conversation.snapshot())
    #expect(
      session.toolCalls.map(\.request.toolName) == [.readFile, .editFile, .runCommand, .finishTask])
    #expect(session.toolCalls.allSatisfy { $0.status == .completed })
    let mutations = session.toolCalls.filter {
      [.editFile, .runCommand].contains($0.request.toolName)
    }
    #expect(mutations.allSatisfy { $0.approvalSource == .automatic })
    #expect(await backend.contents(of: "repair.py") == "return 2\n")
    #expect(try String(contentsOf: hostFile, encoding: .utf8) == "HOST FILE MUST STAY UNCHANGED")
    let commands = await backend.commands
    #expect(commands.count == 1)
    #expect(commands.first?.arguments == ["-c", "python3 -m unittest"])
    #expect(commands.first?.environment["SUMIKA_HARBOR_TOKEN"] == nil)
    let schemas = await runtime.toolSchemas
    let expected: Set<ToolName> = [
      .readFile, .editFile, .writeFile, .runCommand, .askUser, .finishTask,
    ]
    #expect(schemas.count == 4)
    #expect(schemas.allSatisfy { $0 == expected })
    let prompts = await runtime.prompts.joined(separator: "\n")
    #expect(prompts.contains("REMOTE WORKSPACE INSTRUCTIONS"))
    #expect(!prompts.contains("HOST INSTRUCTIONS"))
    await sumika.conversation.cancelGenerationAndDrain()
    sumika.conversation.deactivate()
    await sumika.conversation.drainAttachments()
    await sumika.agent.prepareForTermination()
  }

  @Test
  func cancellationDrainsTheInjectedCommand() async throws {
    let root = try scopedTemporaryDirectory()
    let backend = InMemoryWorkspaceBackend(suspendCommands: true)
    let runtime = WorkspaceExecutionRuntime(commandOnly: true)
    let sumika = try await makeSumika(root: root, backend: backend, runtime: runtime)
    try await sumika.conversation.sendMessage(MessageSubmission(text: "Run the tests."))
    let started = ContinuousClock.now
    while await backend.commands.isEmpty {
      guard started.duration(to: .now) < .seconds(5) else {
        throw WorkspaceExecutionTestError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    await sumika.conversation.cancelGenerationAndDrain()
    #expect(await backend.commandCancelled)
    #expect(sumika.conversation.snapshot()?.turns.last?.status == .cancelled)
    sumika.conversation.deactivate()
    await sumika.conversation.drainAttachments()
    await sumika.agent.prepareForTermination()
  }

  private func makeSumika(
    root: URL, backend: InMemoryWorkspaceBackend, runtime: WorkspaceExecutionRuntime
  ) async throws -> Sumika {
    let model = ManagedModelCatalog.defaultModel
    let session = ChatSession(
      selectedModelID: model.id, modeSettings: model.defaultModeSettings,
      interactionMode: .agent, toolApprovalPolicy: .automatic)
    let sumika = Sumika(
      configuration: Sumika.Configuration(initialModel: model, modelPath: root.path),
      dependencies: Sumika.Dependencies(
        runtime: runtime,
        workspaceExecution: WorkspaceExecution(fileIO: backend, commandRunner: backend),
        modelSettingsStore: ModelSettingsStore(settingsURL: root.appending(path: "settings.json")),
        modelAvailability: { _ in true },
        chatAttachmentLoader: ChatAttachmentLoader(
          attachmentStore: ChatAttachmentStore(baseURL: root.appending(path: "attachments"))),
        skillCatalog: SkillCatalog(homeDirectoryURL: root.appending(path: "skills-home"))))
    try sumika.conversation.activate(
      sessionID: session.id,
      in: Workspace(name: "Virtual workspace", rootURL: root, sessions: [session]))
    sumika.models.loadSelectedModel()
    try await waitUntil { sumika.models.state.modelState == .ready }
    return sumika
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let started = ContinuousClock.now
    while !condition() {
      guard started.duration(to: .now) < .seconds(5) else {
        throw WorkspaceExecutionTestError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private enum WorkspaceExecutionTestError: Error {
  case timedOut
}

private actor InMemoryWorkspaceBackend: WorkspaceFileIO, CommandProcessRunning {
  private var files = [
    "AGENTS.md": Data("REMOTE WORKSPACE INSTRUCTIONS".utf8),
    "repair.py": Data("return 1\n".utf8),
  ]
  private let suspendCommands: Bool
  private(set) var commands: [CommandProcessRequest] = []
  private(set) var commandCancelled = false

  init(suspendCommands: Bool = false) {
    self.suspendCommands = suspendCommands
  }

  func resolve(path: String, in workspace: Workspace) async throws -> WorkspaceFileLocation {
    let root = workspace.rootURL.path(percentEncoded: false)
    let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    return WorkspaceFileLocation(
      absolutePath: relative == "." ? root : root + "/" + relative,
      relativePath: WorkspaceRelativePath(rawValue: relative),
      isRegularFile: files[relative] != nil)
  }

  func read(path: String, in workspace: Workspace, offset: Int, maxBytes: Int?) async throws -> Data
  {
    let location = try await resolve(path: path, in: workspace)
    guard let data = files[location.relativePath.rawValue] else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let bytes = data.dropFirst(offset)
    return Data(bytes.prefix(maxBytes ?? bytes.count))
  }

  func write(path: String, in workspace: Workspace, data: Data, expectedContents: Data?)
    async throws
  {
    let location = try await resolve(path: path, in: workspace)
    if let expectedContents, files[location.relativePath.rawValue] != expectedContents {
      throw WorkspaceFileIOError.contentChanged
    }
    files[location.relativePath.rawValue] = data
  }

  func listDirectory(path _: String, in _: Workspace) async throws -> [String] {
    Array(files.keys)
  }

  func contents(of path: String) -> String? {
    files[path].flatMap { String(data: $0, encoding: .utf8) }
  }

  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    commands.append(request)
    if suspendCommands {
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        commandCancelled = true
        throw error
      }
    }
    return CommandProcessResult(exitCode: 0, durationMs: 1, stdout: "Tests passed", stderr: "")
  }
}

private actor WorkspaceExecutionRuntime: ChatModelRuntime {
  private let commandOnly: Bool
  private(set) var toolSchemas: [Set<ToolName>] = []
  private(set) var prompts: [String] = []

  init(commandOnly: Bool = false) {
    self.commandOnly = commandOnly
  }

  func load(configuration _: ChatModelConfiguration) async throws {}
  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection, attachments _: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan, settings _: ChatGenerationSettings,
    interactionMode _: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    let index = toolSchemas.count
    toolSchemas.append(Set(promptPlan.toolContext?.registry.tools.map(\.name) ?? []))
    prompts.append(transcript.projectedEntries().map(\.content).joined(separator: "\n"))
    let call: ChatRuntimeToolCall
    switch commandOnly ? 2 : index {
    case 0:
      call = ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("repair.py")])
    case 1:
      call = ChatRuntimeToolCall(
        name: "edit_file",
        arguments: [
          "path": .string("repair.py"), "old_text": .string("return 1"),
          "new_text": .string("return 2"),
        ])
    case 2:
      call = ChatRuntimeToolCall(
        name: "run_command",
        arguments: [
          "command": .string("python3 -m unittest"), "timeoutSeconds": .number(120),
        ])
    default:
      call = ChatRuntimeToolCall(
        name: "finish_task",
        arguments: [
          "status": .string("done"), "summary": .string("Repaired and tested."),
        ])
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(.toolCall(call))
      continuation.yield(.completed(nil))
      continuation.finish()
    }
  }
}
