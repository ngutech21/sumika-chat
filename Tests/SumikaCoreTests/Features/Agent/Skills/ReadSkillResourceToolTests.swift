import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

private struct CollidingSkillResourceExecutor: DynamicToolExecutor {
  var codec: ToolCodec<ReadSkillResourceInput> {
    ReadSkillResourceToolExecutor.codec
  }

  func evaluatePermission(
    _ input: ReadSkillResourceInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .denied,
      reason: "A dynamic collision must not receive the reserved skill authority.",
      riskLevel: .high
    )
  }

  func run(_ input: ReadSkillResourceInput, context: ToolContext) async -> ToolResultPayload {
    _ = context
    return .readSkillResource(
      .failed(
        skillID: input.skillID,
        path: input.path,
        message: "Dynamic collision executed.",
        status: .failed
      )
    )
  }
}

@Suite(TemporaryDirectoryTrait(named: "sumika-read-skill-resource-tests"))
struct ReadSkillResourceToolTests {
  @Test
  func readsOnlyActivatedSkillResourcesWithLinePaging() async throws {
    let root = try makeDirectory(named: "resources")
    let projectSkillRoot = root.appending(path: "project-review", directoryHint: .isDirectory)
    let personalSkillRoot = root.appending(path: "personal-review", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectSkillRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: personalSkillRoot, withIntermediateDirectories: true)
    try "one\ntwo\nthree".write(
      to: projectSkillRoot.appending(path: "notes.md"),
      atomically: true,
      encoding: .utf8
    )
    try "private".write(
      to: personalSkillRoot.appending(path: "notes.md"),
      atomically: true,
      encoding: .utf8
    )
    let projectID = SkillID(scope: .project, name: "review")
    let personalID = SkillID(scope: .personal, name: "review")
    let executor = ReadSkillResourceToolExecutor(resourceRoots: [
      SkillResourceRoot(id: projectID, rootURL: projectSkillRoot)
    ])
    let context = ToolContext(workspace: Workspace(name: "Project", rootURL: root))

    let result = await executor.run(
      ReadSkillResourceInput(
        skillID: projectID,
        path: "notes.md",
        offset: 2,
        limit: 1
      ),
      context: context
    )
    let inactiveResult = await executor.run(
      ReadSkillResourceInput(skillID: personalID, path: "notes.md"),
      context: context
    )

    guard case .readSkillResource(.page(let page)) = result else {
      Issue.record("Expected a skill resource page, got \(result)")
      return
    }
    #expect(page.skillID == projectID)
    #expect(page.path == "notes.md")
    #expect(page.startLine == 2)
    #expect(page.endLine == 2)
    #expect(page.content == "two")
    #expect(page.continuation == .next(offset: 3, reason: .lineLimit))
    #expect(inactiveResult.status == .denied)
  }

  @Test
  func rejectsTraversalInvalidUTF8AndExternalSymlinks() async throws {
    let root = try makeDirectory(named: "confinement")
    let skillRoot = root.appending(path: "skill", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside.txt")
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    try Data([0xFF]).write(to: skillRoot.appending(path: "binary.dat"))
    try FileManager.default.createSymbolicLink(
      at: skillRoot.appending(path: "escape.txt"),
      withDestinationURL: outside
    )
    let skillID = SkillID(scope: .project, name: "testing")
    let executor = ReadSkillResourceToolExecutor(resourceRoots: [
      SkillResourceRoot(id: skillID, rootURL: skillRoot)
    ])
    let context = ToolContext(workspace: Workspace(name: "Project", rootURL: root))

    let traversal = await executor.run(
      ReadSkillResourceInput(skillID: skillID, path: "../outside.txt"),
      context: context
    )
    let absolute = await executor.run(
      ReadSkillResourceInput(skillID: skillID, path: outside.path(percentEncoded: false)),
      context: context
    )
    let binary = await executor.run(
      ReadSkillResourceInput(skillID: skillID, path: "binary.dat"),
      context: context
    )
    let symlink = await executor.run(
      ReadSkillResourceInput(skillID: skillID, path: "escape.txt"),
      context: context
    )

    #expect(traversal.status == .denied)
    #expect(absolute.status == .denied)
    #expect(binary.status == .failed)
    #expect(symlink.status == .denied)
  }

  @Test
  func normalizesLineEndingsAndDoesNotInventATrailingLine() async throws {
    let root = try makeDirectory(named: "line-endings")
    let skillRoot = root.appending(path: "skill", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    try Data("one\r\ntwo\r\n".utf8).write(to: skillRoot.appending(path: "notes.md"))
    let skillID = SkillID(scope: .project, name: "testing")
    let executor = ReadSkillResourceToolExecutor(resourceRoots: [
      SkillResourceRoot(id: skillID, rootURL: skillRoot)
    ])
    let context = ToolContext(workspace: Workspace(name: "Project", rootURL: root))

    let result = await executor.run(
      ReadSkillResourceInput(skillID: skillID, path: "notes.md"),
      context: context
    )
    let pastEnd = await executor.run(
      ReadSkillResourceInput(skillID: skillID, path: "notes.md", offset: 3),
      context: context
    )

    guard case .readSkillResource(.page(let page)) = result else {
      Issue.record("Expected a skill resource page, got \(result)")
      return
    }
    #expect(page.content == "one\ntwo")
    #expect(page.endLine == 2)
    #expect(page.continuation == .endOfFile)
    #expect(pastEnd.status == .failed)
  }

  @Test
  func reportsAnOversizedFollowingLineAsABlockedContinuation() async throws {
    let root = try makeDirectory(named: "blocked-line")
    let skillRoot = root.appending(path: "skill", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    let oversizedLine = String(repeating: "x", count: 17 * 1024)
    try "one\n\(oversizedLine)\nthree".write(
      to: skillRoot.appending(path: "notes.md"),
      atomically: true,
      encoding: .utf8
    )
    let skillID = SkillID(scope: .project, name: "testing")
    let executor = ReadSkillResourceToolExecutor(resourceRoots: [
      SkillResourceRoot(id: skillID, rootURL: skillRoot)
    ])
    let context = ToolContext(workspace: Workspace(name: "Project", rootURL: root))

    let result = await executor.run(
      ReadSkillResourceInput(skillID: skillID, path: "notes.md"),
      context: context
    )

    guard case .readSkillResource(.page(let page)) = result else {
      Issue.record("Expected a skill resource page, got \(result)")
      return
    }
    #expect(page.content == "one")
    #expect(page.endLine == 1)
    #expect(
      page.continuation == .blocked(line: 2, byteCount: oversizedLine.utf8.count)
    )
  }

  @Test
  func runCommandStillRequiresApprovalForScriptsInsideAnActivatedSkill() throws {
    let root = try makeDirectory(named: "script-approval")
    let context = ToolContext(workspace: Workspace(name: "Project", rootURL: root))

    let permission = RunCommandToolExecutor().evaluatePermission(
      RunCommandInput(
        command: "./.agents/skills/testing/scripts/check.sh",
        timeoutSeconds: 30,
        reason: "Run an activated skill script."
      ),
      context: context
    )

    #expect(permission.decision == .requiresApproval)
    #expect(permission.riskLevel == .high)
  }

  @Test
  func turnLocalToolNameIsReservedFromMCPAndReplacementUsesTheBuiltInExecutor() throws {
    let serverID = UUID()
    let collision = AnyToolExecutor(dynamic: CollidingSkillResourceExecutor())
    let configured = AgentToolConfiguration(
      todoWriteEnabled: false,
      mcpExecutorGroups: [
        MCPAgentToolExecutorGroup(serverID: serverID, executors: [collision])
      ]
    ).executorRegistry(selectedMCPServerIDs: [serverID])

    #expect(configured.executor(for: .readSkillResource) == nil)

    let root = try makeDirectory(named: "reserved-name")
    let skillID = SkillID(scope: .project, name: "testing")
    let replaced = ToolExecutorRegistry([collision]).replacing(
      AnyToolExecutor(
        ReadSkillResourceToolExecutor(resourceRoots: [
          SkillResourceRoot(id: skillID, rootURL: root)
        ])
      )
    )

    #expect(replaced.definitions.filter { $0.name == .readSkillResource } == [.readSkillResource])
    #expect(replaced.dynamicCodecs[.readSkillResource] == nil)
  }

  private func makeDirectory(named name: String) throws -> URL {
    let url = try scopedTemporaryDirectory().appending(
      path: "\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
