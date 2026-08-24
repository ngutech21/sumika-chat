import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-skill-submission-tests"))
@MainActor
struct SkillConversationSubmissionTests {
  @Test
  func budgetFailureCreatesNoTurnAndLeavesSessionTitleUntouched() async throws {
    let root = try makeDirectory(named: "budget")
    let session = ChatSession(title: ChatSession.defaultTitle, interactionMode: .agent)
    let workspace = Workspace(name: "Project", rootURL: root, sessions: [session])
    try writeSkill(
      name: "huge",
      description: "Too large.",
      body: String(repeating: "x", count: SkillCatalog.maximumActivatedContentCharacters),
      to: root.appending(path: ".agents/skills/huge", directoryHint: .isDirectory)
    )
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(chunks: ["unused"]),
      modelPath: "/tmp/model",
      chatSession: session,
      skillCatalog: SkillCatalog(homeDirectoryURL: missingHomeDirectory(under: root))
    )
    try engine.loadSession(from: workspace, sessionID: session.id)
    engine.modelRuntime.modelState = .ready
    let attachmentURL = root.appending(path: "context.txt", directoryHint: .notDirectory)
    try "Keep this attachment.".write(to: attachmentURL, atomically: true, encoding: .utf8)
    engine.addAttachments(from: [attachmentURL])
    try await waitUntil { !engine.composerSessionState.pendingAttachments.isEmpty }

    await #expect(throws: SkillActivationError.self) {
      try await engine.sendMessage(MessageSubmission(text: "Use $huge"))
    }

    #expect(engine.chatSession.turns.isEmpty)
    #expect(engine.chatSession.title == ChatSession.defaultTitle)
    #expect(engine.composerSessionState.pendingAttachments.map(\.displayName) == ["context.txt"])
    #expect(engine.activity == .idle)
  }

  @Test
  func activatedSkillIsPersistedOnTheUserMessageAndProjectedVerbatim() async throws {
    let root = try makeDirectory(named: "success")
    let session = ChatSession(interactionMode: .agent)
    let workspace = Workspace(name: "Project", rootURL: root, sessions: [session])
    let content = try writeSkill(
      name: "review",
      description: "Review changes.",
      body: "Review every changed line.",
      to: root.appending(path: ".agents/skills/review", directoryHint: .isDirectory)
    )
    let agentsURL = root.appending(
      path: ".agents/skills/review/agents",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: agentsURL, withIntermediateDirectories: true)
    try "interface:\n  display_name: Review\n  short_description: Review the diff".write(
      to: agentsURL.appending(path: "openai.yaml", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["Reviewed."])
    let tracer = SkillRecordingTurnTracer()
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      turnTracer: tracer,
      chatSession: session,
      skillCatalog: SkillCatalog(homeDirectoryURL: missingHomeDirectory(under: root))
    )
    try engine.loadSession(from: workspace, sessionID: session.id)
    engine.modelRuntime.modelState = .ready

    try await engine.sendMessage(MessageSubmission(text: "Use $review"))
    try await waitUntil { engine.activity == .idle }

    let userMessage = try #require(
      engine.chatSession.turns.first?.items.compactMap { item -> UserTurnMessage? in
        guard case .userMessage(let message) = item else { return nil }
        return message
      }.first
    )
    let activated = try #require(userMessage.promptContext.activatedSkills.first)
    #expect(activated.id.rawValue == "project:review")
    #expect(activated.content == content)
    #expect(activated.interfaceMetadata?.displayName == "Review")
    #expect(
      userMessage.activatedSkillMentions
        == [
          ActivatedSkillMention(
            id: activated.id,
            range: (userMessage.content as NSString).range(of: "$review")
          )
        ]
    )
    let captured = await runtime.capturedMessages.flatMap { $0 }.map(\.content)
      .joined(separator: "\n")
    #expect(captured.contains(content))
    let toolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(toolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .readSkillResource) != nil)
    let trace = try #require(await tracer.contextBuildEvent())
    #expect(trace.activatedSkillIDs == ["project:review"])
    #expect(trace.activatedSkillContentHashes == [activated.contentHash])
    #expect(trace.activatedSkillCharacterCount == content.count)
  }

  @Test
  func persistedApprovalReloadRestoresMatchingSkillResourceAuthority() async throws {
    let root = try makeDirectory(named: "approval-reload")
    let session = ChatSession(interactionMode: .agent)
    var workspace = Workspace(name: "Project", rootURL: root, sessions: [session])
    let skillRoot = root.appending(
      path: ".agents/skills/review",
      directoryHint: .isDirectory
    )
    try writeSkill(
      name: "review",
      description: "Review changes.",
      body: "Read supporting resources when needed.",
      to: skillRoot
    )
    try "Resource guidance.".write(
      to: skillRoot.appending(path: "notes.md"),
      atomically: true,
      encoding: .utf8
    )
    let homeDirectoryURL = missingHomeDirectory(under: root)
    let initialRuntime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: ToolName.writeFile.rawValue,
            arguments: [
              "path": .string("marker.txt"),
              "content": .string("approved"),
            ]
          ))
      ]
    ])
    let initialEngine = ConversationEngine(
      runtime: initialRuntime,
      modelPath: "/tmp/model",
      chatSession: session,
      skillCatalog: SkillCatalog(homeDirectoryURL: homeDirectoryURL)
    )
    try initialEngine.loadSession(from: workspace, sessionID: session.id)
    initialEngine.modelRuntime.modelState = .ready

    try await initialEngine.sendMessage(MessageSubmission(text: "Use $review"))
    try await waitUntil { initialEngine.hasPendingApproval && !initialEngine.isGenerating }

    let persistedSession = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(initialEngine.chatSession)
    )
    workspace.sessions = [persistedSession]
    let resumedRuntime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: ToolName.readSkillResource.rawValue,
            arguments: [
              "skill_id": .string("project:review"),
              "path": .string("notes.md"),
            ]
          ))
      ],
      [.chunk("Used the resource.")],
    ])
    let resumedEngine = ConversationEngine(
      runtime: resumedRuntime,
      modelPath: "/tmp/model",
      skillCatalog: SkillCatalog(homeDirectoryURL: homeDirectoryURL)
    )
    try resumedEngine.loadSession(from: workspace, sessionID: persistedSession.id)
    resumedEngine.modelRuntime.modelState = .ready
    let pendingRecord = try #require(
      resumedEngine.chatSession.toolCalls.first(where: { $0.status == .awaitingApproval })
    )

    resumedEngine.approveToolCall(id: pendingRecord.id, in: workspace)
    try await waitUntil { resumedEngine.activity == .idle }

    #expect(resumedEngine.chatSession.turns.first?.status == .completed)
    #expect(
      resumedEngine.chatSession.toolCalls.map(\.request.toolName) == [
        .writeFile,
        .readSkillResource,
      ]
    )
    let resourceRecord = try #require(
      resumedEngine.chatSession.toolCalls.first(where: {
        $0.request.toolName == .readSkillResource
      })
    )
    guard case .readSkillResource(.page(let page)) = resourceRecord.resultPayload else {
      Issue.record("Expected the reloaded turn to read the activated skill resource.")
      return
    }
    #expect(page.content == "Resource guidance.")
    let toolContexts = await resumedRuntime.capturedToolContexts
    let firstToolContext = try #require(toolContexts.first ?? nil)
    #expect(firstToolContext.registry.definition(for: .readSkillResource) != nil)
  }

  private func makeDirectory(named name: String) throws -> URL {
    let url = try scopedTemporaryDirectory().appending(
      path: "\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func missingHomeDirectory(under root: URL) -> URL {
    root.appending(path: "missing-personal", directoryHint: .isDirectory)
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        Issue.record("Timed out waiting for conversation state.")
        return
      }
      await Task.yield()
    }
  }

  @discardableResult
  private func writeSkill(
    name: String,
    description: String,
    body: String,
    to directory: URL
  ) throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let content = """
      ---
      name: \(name)
      description: \(description)
      ---
      \(body)
      """
    try content.write(
      to: directory.appending(path: "SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
    return content
  }
}

private actor SkillRecordingTurnTracer: TurnTracing {
  private var events: [TurnTraceEvent] = []

  func recordTurnTraceEvent(_ event: TurnTraceEvent) {
    events.append(event)
  }

  func contextBuildEvent() -> TurnTraceEvent? {
    events.first { $0.phase == .contextBuild }
  }
}
