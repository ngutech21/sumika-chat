import Foundation
import Testing

@testable import SumikaCore

struct ActivatedSkillsPromptContextTests {
  @Test
  func activatedSkillsRoundTripWithoutTruncationAndRenderBelowWorkspaceInstructions() throws {
    let content = "---\nname: review\ndescription: Review changes.\n---\nReview carefully."
    let skill = ActivatedSkill(
      id: SkillID(scope: .project, name: "review"),
      portablePath: ".agents/skills/review/SKILL.md",
      contentHash: ChatAttachmentStore.contentSHA256(for: Data(content.utf8)),
      content: content
    )
    let workspaceInstructions = try #require(
      WorkspaceInstructionsPromptContext.makeSnapshot(
        path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
        contentHash: "workspace-hash",
        content: "Workspace rule."
      )
    )
    let context = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([skill])
      .appendingWorkspaceInstructions(workspaceInstructions)

    let decoded = try JSONDecoder().decode(
      CurrentPromptContext.self,
      from: JSONEncoder().encode(context)
    )
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "Implement it.",
      workspaceInstructions: CurrentPromptContextRenderer.renderWorkspaceInstructions(decoded),
      systemContext: CurrentPromptContextRenderer.renderSupportingContext(decoded),
      currentPromptContext: decoded
    )

    #expect(decoded == context)
    #expect(decoded.activatedSkills == [skill])
    #expect(entry.frozenContent.content.contains(content))
    let workspaceRange = try #require(entry.frozenContent.content.range(of: "Workspace rule."))
    let skillRange = try #require(entry.frozenContent.content.range(of: content))
    let userRange = try #require(entry.frozenContent.content.range(of: "User request:"))
    #expect(workspaceRange.lowerBound < skillRange.lowerBound)
    #expect(skillRange.lowerBound < userRange.lowerBound)
  }

  @Test
  func activatedSkillDerivesScopeAndDecodesLegacyScopeField() throws {
    let content = "Skill instructions"
    let skill = ActivatedSkill(
      id: SkillID(scope: .project, name: "testing"),
      portablePath: ".agents/skills/testing/SKILL.md",
      contentHash: ChatAttachmentStore.contentSHA256(for: Data(content.utf8)),
      content: content
    )
    let data = try JSONEncoder().encode(skill)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["scope"] == nil)

    object["scope"] = "project"
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ActivatedSkill.self, from: legacyData)

    #expect(decoded == skill)
    #expect(decoded.id.scope == .project)
  }

  @Test
  func activatedSkillDecodeRejectsContentHashMismatch() throws {
    let content = "Skill instructions"
    let skill = ActivatedSkill(
      id: SkillID(scope: .personal, name: "testing"),
      portablePath: "$HOME/.agents/skills/testing/SKILL.md",
      contentHash: ChatAttachmentStore.contentSHA256(for: Data(content.utf8)),
      content: content
    )
    let data = try JSONEncoder().encode(skill)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["content"] = "Changed instructions"
    let invalidData = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ActivatedSkill.self, from: invalidData)
    }
  }

  @Test
  func chatModeSuppressesSkillsPersistedByAgentTurns() {
    let content = "---\nname: review\ndescription: Review changes.\n---\nAgent-only review rules."
    let skill = ActivatedSkill(
      id: SkillID(scope: .project, name: "review"),
      portablePath: ".agents/skills/review/SKILL.md",
      contentHash: ChatAttachmentStore.contentSHA256(for: Data(content.utf8)),
      content: content
    )
    let context = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([skill])
    let turn = ChatTurn(
      status: .completed,
      items: [
        .userMessage(UserTurnMessage(content: "Review it.", promptContext: context)),
        .assistantMessage(AssistantTurnMessage(content: "Done.")),
      ]
    )
    var session = ChatSession(turns: [turn], interactionMode: .agent)
    let agentContent = providerContent(session)

    session.interactionMode = .chat
    let chatContent = providerContent(session)

    #expect(agentContent.contains("Agent-only review rules."))
    #expect(!chatContent.contains("Agent-only review rules."))
    #expect(!chatContent.contains("Activated skill:"))
  }

  private func providerContent(_ session: ChatSession) -> String {
    ProviderPromptProjection.normalized(
      from: ChatModelContextBuilder(focusedFileReusePolicy: .disabled).transcript(from: session)
    ).messages.map(\.content).joined()
  }
}
