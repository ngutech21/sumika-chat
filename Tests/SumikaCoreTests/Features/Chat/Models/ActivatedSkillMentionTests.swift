import Foundation
import Testing

@testable import SumikaCore

struct ActivatedSkillMentionTests {
  @Test
  func userMessageMentionsRoundTripWithUTF16RangesAndEmptyArraysAreOmitted() throws {
    let skill = activatedSkill(name: "code-review")
    let content = "🧪 Use $code-review and $code-review"
    let ranges = skillMentionRanges(of: "$code-review", in: content)
    let context = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([skill])
    let message = UserTurnMessage(
      content: content,
      promptContext: context,
      activatedSkillMentions: ranges.map {
        ActivatedSkillMention(id: skill.id, range: $0)
      }
    )

    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(UserTurnMessage.self, from: data)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let legacyData = try JSONEncoder().encode(UserTurnMessage(content: "Legacy"))
    let legacyObject = try #require(
      JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
    )
    let legacyDecoded = try JSONDecoder().decode(UserTurnMessage.self, from: legacyData)

    #expect(decoded == message)
    #expect(decoded.activatedSkillMentions.map(\.range) == ranges)
    #expect(ranges.first?.location == 7)
    #expect(object["activatedSkillMentions"] != nil)
    #expect(legacyObject["activatedSkillMentions"] == nil)
    #expect(legacyDecoded.activatedSkillMentions.isEmpty)
  }

  @Test
  func decodingDropsMalformedOrStaleMentionAnnotationsWithoutLosingTheMessage() throws {
    let skill = activatedSkill(name: "code-review")
    let content = "Use $code-review"
    let validRange = (content as NSString).range(of: "$code-review")
    let context = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([skill])
    let message = UserTurnMessage(content: content, promptContext: context)
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
    )
    object["activatedSkillMentions"] = [
      [
        "id": skill.id.rawValue,
        "location": validRange.location,
        "length": validRange.length,
      ],
      [
        "id": "personal:code-review",
        "location": validRange.location,
        "length": validRange.length,
      ],
      [
        "id": skill.id.rawValue,
        "location": 0,
        "length": 3,
      ],
      [
        "id": skill.id.rawValue,
        "location": 10_000,
        "length": 12,
      ],
      ["id": "not-a-skill-id"],
    ]

    let decoded = try JSONDecoder().decode(
      UserTurnMessage.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.content == content)
    #expect(
      decoded.activatedSkillMentions
        == [ActivatedSkillMention(id: skill.id, range: validRange)]
    )

    object["activatedSkillMentions"] = "invalid"
    let scalarDecoded = try JSONDecoder().decode(
      UserTurnMessage.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(scalarDecoded.content == content)
    #expect(scalarDecoded.activatedSkillMentions.isEmpty)
  }

  @Test
  func validationRequiresTheAnnotationToMatchACompleteSkillToken() {
    let skill = activatedSkill(name: "foo")
    let content = "$foobar"
    let context = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([skill])
    let message = UserTurnMessage(
      content: content,
      promptContext: context,
      activatedSkillMentions: [
        ActivatedSkillMention(
          id: skill.id,
          range: (content as NSString).range(of: "$foo")
        )
      ]
    )

    #expect(message.content == content)
    #expect(message.activatedSkillMentions.isEmpty)
  }

  @Test
  func presentationUsesSnapshottedInterfaceMetadataAndSkillDescriptionFallbacks() throws {
    let metadataSkill = activatedSkill(
      name: "code-review",
      description: "Full review instructions description.",
      interfaceMetadata: SkillInterfaceMetadata(
        displayName: "Code Review",
        shortDescription: "Review a diff on standards and spec"
      )
    )
    let fallbackSkill = activatedSkill(
      name: "testing",
      description: "Run all focused tests."
    )
    let content = "Use $code-review and $testing"
    let context = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([metadataSkill, fallbackSkill])
    let message = UserTurnMessage(
      content: content,
      promptContext: context,
      activatedSkillMentions: [
        ActivatedSkillMention(
          id: metadataSkill.id,
          range: (content as NSString).range(of: "$code-review")
        ),
        ActivatedSkillMention(
          id: fallbackSkill.id,
          range: (content as NSString).range(of: "$testing")
        ),
      ]
    )

    #expect(
      message.activatedSkillMentionPresentations.map(\.displayName)
        == ["Code Review", "$testing"]
    )
    #expect(
      message.activatedSkillMentionPresentations.map(\.tooltip)
        == ["Review a diff on standards and spec", "Run all focused tests."]
    )
  }

  @Test
  func legacyPresentationResolvesEveryUniqueTokenButLeavesAmbiguousNamesUntouched() {
    let projectReview = activatedSkill(name: "review", scope: .project)
    let personalReview = activatedSkill(name: "review", scope: .personal)
    let testing = activatedSkill(name: "testing", scope: .personal)
    let uniqueContent = "$testing then $testing"
    let uniqueMessage = UserTurnMessage(
      content: uniqueContent,
      promptContext: CurrentPromptContext.empty(.focusedFileDefault)
        .appendingActivatedSkills([testing])
    )
    let ambiguousMessage = UserTurnMessage(
      content: "$review",
      promptContext: CurrentPromptContext.empty(.focusedFileDefault)
        .appendingActivatedSkills([projectReview, personalReview])
    )

    #expect(uniqueMessage.activatedSkillMentionPresentations.count == 2)
    #expect(
      uniqueMessage.activatedSkillMentionPresentations.map(\.range)
        == skillMentionRanges(of: "$testing", in: uniqueContent)
    )
    #expect(ambiguousMessage.activatedSkillMentionPresentations.isEmpty)
  }

  @Test
  func interfaceMetadataRoundTripsButDoesNotEnterTheModelPrompt() throws {
    let skill = activatedSkill(
      name: "review",
      interfaceMetadata: SkillInterfaceMetadata(
        displayName: "Private UI Label",
        shortDescription: "Private UI Tooltip"
      )
    )
    let decoded = try JSONDecoder().decode(
      ActivatedSkill.self,
      from: JSONEncoder().encode(skill)
    )
    let context = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([skill])
    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context).joined(
      separator: "\n")

    #expect(decoded == skill)
    #expect(rendered.contains(skill.content))
    #expect(!rendered.contains("Private UI Label"))
    #expect(!rendered.contains("Private UI Tooltip"))
  }

  private func activatedSkill(
    name: String,
    scope: SkillScope = .project,
    description: String = "Review changes.",
    interfaceMetadata: SkillInterfaceMetadata? = nil
  ) -> ActivatedSkill {
    let content = "---\nname: \(name)\ndescription: \(description)\n---\nInstructions"
    return ActivatedSkill(
      id: SkillID(scope: scope, name: name),
      portablePath: scope == .project
        ? ".agents/skills/\(name)/SKILL.md"
        : "$HOME/.agents/skills/\(name)/SKILL.md",
      contentHash: ChatAttachmentStore.contentSHA256(for: Data(content.utf8)),
      content: content,
      interfaceMetadata: interfaceMetadata
    )
  }

}
