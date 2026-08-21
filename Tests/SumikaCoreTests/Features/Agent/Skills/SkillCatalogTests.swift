import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-skill-catalog-tests"))
struct SkillCatalogTests {
  @Test
  func refreshDiscoversProjectAndPersonalSkillsWithoutShadowingDuplicateNames() async throws {
    let root = try makeDirectory(named: "catalog")
    let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
    let personalRoot = root.appending(path: "personal", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try writeSkill(
      name: "review",
      description: "Review project changes.",
      body: "Project instructions",
      to: projectRoot.appending(path: ".agents/skills/review", directoryHint: .isDirectory)
    )
    try writeSkill(
      name: "review",
      description: "Review any changes.",
      body: "Personal instructions",
      to: personalRoot.appending(path: "review", directoryHint: .isDirectory)
    )
    try writeSkill(
      name: "testing",
      description: "Run focused tests.",
      body: "Testing instructions",
      to: personalRoot.appending(path: "testing", directoryHint: .isDirectory)
    )

    let snapshot = await SkillCatalog(personalSkillsURL: personalRoot).refresh(
      for: Workspace(name: "Project", rootURL: projectRoot)
    )

    #expect(
      snapshot.skills.map(\.id.rawValue) == [
        "project:review",
        "personal:review",
        "personal:testing",
      ])
    #expect(
      snapshot.skills.map(\.description) == [
        "Review project changes.",
        "Review any changes.",
        "Run focused tests.",
      ])
    #expect(snapshot.diagnostics.isEmpty)
  }

  @Test
  func activationUsesBoundIdentityAndManualUniqueNamesInMessageOrder() async throws {
    let root = try makeDirectory(named: "activation")
    let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
    let personalRoot = root.appending(path: "personal", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try writeSkill(
      name: "review",
      description: "Project review.",
      body: "Project review instructions",
      to: projectRoot.appending(path: ".agents/skills/review", directoryHint: .isDirectory)
    )
    try writeSkill(
      name: "review",
      description: "Personal review.",
      body: "Personal review instructions",
      to: personalRoot.appending(path: "review", directoryHint: .isDirectory)
    )
    try writeSkill(
      name: "testing",
      description: "Test changes.",
      body: "Testing instructions",
      to: personalRoot.appending(path: "testing", directoryHint: .isDirectory)
    )
    let catalog = SkillCatalog(personalSkillsURL: personalRoot)
    let text = "Use $review and $testing, then $review again. Keep $unknown as text."
    let nsText = text as NSString
    let firstReviewRange = nsText.range(of: "$review")
    let secondReviewRange = nsText.range(
      of: "$review",
      options: [],
      range: NSRange(
        location: firstReviewRange.location + firstReviewRange.length,
        length: nsText.length - firstReviewRange.location - firstReviewRange.length
      )
    )

    let prepared = try await catalog.prepareSubmission(
      MessageSubmission(
        text: text,
        skillMentions: [
          SkillMention(
            id: SkillID(scope: .personal, name: "review"),
            range: firstReviewRange
          ),
          SkillMention(
            id: SkillID(scope: .personal, name: "review"),
            range: secondReviewRange
          ),
        ]
      ),
      mode: .agent,
      workspace: Workspace(name: "Project", rootURL: projectRoot)
    )
    let chatPrepared = try await catalog.prepareSubmission(
      MessageSubmission(text: "Keep $review as ordinary text."),
      mode: .chat,
      workspace: Workspace(name: "Project", rootURL: projectRoot)
    )

    #expect(
      prepared.activatedSkills.map(\.id.rawValue) == [
        "personal:review",
        "personal:testing",
      ])
    #expect(
      prepared.activatedSkills.map(\.content) == [
        "---\nname: review\ndescription: Personal review.\n---\nPersonal review instructions",
        "---\nname: testing\ndescription: Test changes.\n---\nTesting instructions",
      ])
    #expect(
      prepared.totalCharacterCount == prepared.activatedSkills.map(\.content.count).reduce(0, +))
    #expect(
      prepared.resourceRoots.map(\.id.rawValue) == [
        "personal:review",
        "personal:testing",
      ])
    #expect(
      prepared.activatedSkills.map(\.contentHash)
        == prepared.activatedSkills.map {
          ChatAttachmentStore.contentSHA256(for: Data($0.content.utf8))
        }
    )
    #expect(chatPrepared == .empty)
  }

  @Test
  func activationRejectsAnUnboundAmbiguousName() async throws {
    let root = try makeDirectory(named: "ambiguous")
    let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
    let personalRoot = root.appending(path: "personal", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try writeSkill(
      name: "review",
      description: "Project review.",
      body: "Project",
      to: projectRoot.appending(path: ".agents/skills/review", directoryHint: .isDirectory)
    )
    try writeSkill(
      name: "review",
      description: "Personal review.",
      body: "Personal",
      to: personalRoot.appending(path: "review", directoryHint: .isDirectory)
    )
    let catalog = SkillCatalog(personalSkillsURL: personalRoot)

    await #expect(throws: SkillActivationError.ambiguousName("review")) {
      try await catalog.prepareSubmission(
        MessageSubmission(text: "Use $review"),
        mode: .agent,
        workspace: Workspace(name: "Project", rootURL: projectRoot)
      )
    }
  }

  @Test
  func resourceRootRestorationRejectsChangedSkillContent() async throws {
    let root = try makeDirectory(named: "restoration")
    let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
    let skillRoot = projectRoot.appending(
      path: ".agents/skills/review",
      directoryHint: .isDirectory
    )
    try writeSkill(
      name: "review",
      description: "Review changes.",
      body: "Original instructions",
      to: skillRoot
    )
    let catalog = SkillCatalog(
      personalSkillsURL: root.appending(path: "missing-personal", directoryHint: .isDirectory)
    )
    let workspace = Workspace(name: "Project", rootURL: projectRoot)
    let prepared = try await catalog.prepareSubmission(
      MessageSubmission(text: "Use $review"),
      mode: .agent,
      workspace: workspace
    )
    try writeSkill(
      name: "review",
      description: "Review changes.",
      body: "Changed instructions",
      to: skillRoot
    )

    let restoredRoots = await catalog.resourceRoots(
      matching: prepared.activatedSkills,
      workspace: workspace
    )

    #expect(restoredRoots.isEmpty)
  }

  @Test
  func refreshExcludesInvalidMetadataAndExternalSkillSymlinks() async throws {
    let root = try makeDirectory(named: "invalid")
    let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
    let skillsRoot = projectRoot.appending(path: ".agents/skills", directoryHint: .isDirectory)
    let externalSkill = root.appending(path: "external", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    try writeSkill(
      name: "wrong-name",
      description: "Invalid directory match.",
      body: "Instructions",
      to: skillsRoot.appending(path: "mismatch", directoryHint: .isDirectory)
    )
    try writeSkill(
      name: "external",
      description: "Outside the root.",
      body: "Instructions",
      to: externalSkill
    )
    try FileManager.default.createSymbolicLink(
      at: skillsRoot.appending(path: "external", directoryHint: .isDirectory),
      withDestinationURL: externalSkill
    )

    let snapshot = await SkillCatalog(
      personalSkillsURL: root.appending(path: "missing-personal", directoryHint: .isDirectory)
    ).refresh(for: Workspace(name: "Project", rootURL: projectRoot))

    #expect(snapshot.skills.isEmpty)
    #expect(snapshot.diagnostics.map(\.kind) == [.pathOutsideRoot, .invalidMetadata])
    #expect(snapshot.diagnostics.allSatisfy { !$0.portablePath.hasPrefix("/") })
  }

  @Test
  func refreshRejectsAProjectSkillsRootSymlinkOutsideTheWorkspace() async throws {
    let root = try makeDirectory(named: "external-root")
    let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
    let agentsRoot = projectRoot.appending(path: ".agents", directoryHint: .isDirectory)
    let externalSkillsRoot = root.appending(path: "external-skills", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: agentsRoot, withIntermediateDirectories: true)
    try writeSkill(
      name: "external",
      description: "Must remain outside the project.",
      body: "External instructions",
      to: externalSkillsRoot.appending(path: "external", directoryHint: .isDirectory)
    )
    try FileManager.default.createSymbolicLink(
      at: agentsRoot.appending(path: "skills", directoryHint: .isDirectory),
      withDestinationURL: externalSkillsRoot
    )

    let snapshot = await SkillCatalog(
      personalSkillsURL: root.appending(path: "missing-personal", directoryHint: .isDirectory)
    ).refresh(for: Workspace(name: "Project", rootURL: projectRoot))

    #expect(snapshot.skills.isEmpty)
    #expect(snapshot.diagnostics.map(\.kind) == [.pathOutsideRoot])
    #expect(snapshot.diagnostics.map(\.portablePath) == [".agents/skills"])
  }

  @Test
  func parserAcceptsSpecifiedOptionalFieldsAndReportsMissingDelimiters() async throws {
    let root = try makeDirectory(named: "frontmatter")
    let projectRoot = root.appending(path: "project", directoryHint: .isDirectory)
    let skillsRoot = projectRoot.appending(path: ".agents/skills", directoryHint: .isDirectory)
    try writeRawSkill(
      """
      ---
      name: complete
      description: Uses every supported optional field.
      license: Apache-2.0
      compatibility: Requires macOS.
      metadata:
        author: Sumika
      allowed-tools: read_file run_command
      ---
      Complete instructions.
      """,
      to: skillsRoot.appending(path: "complete", directoryHint: .isDirectory)
    )
    try writeRawSkill(
      "name: missing-open\ndescription: Invalid.\n---\nBody",
      to: skillsRoot.appending(path: "missing-open", directoryHint: .isDirectory)
    )
    try writeRawSkill(
      "---\nname: missing-close\ndescription: Invalid.\nBody",
      to: skillsRoot.appending(path: "missing-close", directoryHint: .isDirectory)
    )

    let snapshot = await SkillCatalog(
      personalSkillsURL: root.appending(path: "missing-personal", directoryHint: .isDirectory)
    ).refresh(for: Workspace(name: "Project", rootURL: projectRoot))

    #expect(snapshot.skills.map(\.id.rawValue) == ["project:complete"])
    #expect(snapshot.diagnostics.map(\.kind) == [.invalidFrontmatter, .invalidFrontmatter])
    #expect(snapshot.diagnostics.allSatisfy { $0.message.contains("delimiter") })
  }

  private func makeDirectory(named name: String) throws -> URL {
    let url = try scopedTemporaryDirectory().appending(
      path: "\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeSkill(
    name: String,
    description: String,
    body: String,
    to directory: URL
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    ---
    name: \(name)
    description: \(description)
    ---
    \(body)
    """.write(
      to: directory.appending(path: "SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
  }

  private func writeRawSkill(_ content: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try content.write(
      to: directory.appending(path: "SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
  }
}
