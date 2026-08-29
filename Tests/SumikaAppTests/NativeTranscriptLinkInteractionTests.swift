import AppKit
import Testing

@testable import SumikaApp
@testable import SumikaCore

@MainActor
struct NativeTranscriptLinkInteractionTests {
  @Test
  func clickingWebLinkRequestsOpeningItsURL() throws {
    let expectedURL = try #require(URL(string: "http://localhost:8000"))
    var openedURLs: [URL] = []
    let textView = NativeTranscriptTextView { openedURLs.append($0) }
    textView.setAttributedText(
      NSAttributedString(
        string: expectedURL.absoluteString,
        attributes: [.link: expectedURL]
      ))

    textView.clicked(onLink: expectedURL, at: 0)

    #expect(openedURLs == [expectedURL])
  }

  @Test
  func clickingHTTPSStringRequestsOpeningItsURL() throws {
    let expectedURL = try #require(URL(string: "https://example.com/docs"))
    var openedURLs: [URL] = []
    let textView = NativeTranscriptTextView { openedURLs.append($0) }

    textView.clicked(onLink: expectedURL.absoluteString, at: 0)

    #expect(openedURLs == [expectedURL])
  }

  @Test(arguments: ["file:///tmp/readme", "javascript:alert(1)", "sumika://settings"])
  func clickingNonWebLinkDoesNotRequestOpeningIt(link: String) {
    var openedURLs: [URL] = []
    let textView = NativeTranscriptTextView { openedURLs.append($0) }

    textView.clicked(onLink: link, at: 0)

    #expect(openedURLs.isEmpty)
  }

  @Test
  func clickingValidatedSkillLinkRequestsItsPersistedSnapshotPreview() {
    let content = "---\nname: review\ndescription: Review changes.\n---\nPersisted instructions"
    let request = SkillPreviewRequest(
      skill: ActivatedSkill(
        id: SkillID(scope: .project, name: "review"),
        portablePath: ".agents/skills/review/SKILL.md",
        contentHash: ChatAttachmentStore.contentSHA256(for: Data(content.utf8)),
        content: content
      ),
      displayName: "Review"
    )
    var openedRequests: [SkillPreviewRequest] = []
    let textView = NativeTranscriptTextView(
      openLink: nil,
      openSkillPreview: { openedRequests.append($0) }
    )
    let skillLink = NativeSkillPreviewLink(request: request)
    textView.setAttributedText(
      NSAttributedString(
        string: "Review",
        attributes: [
          .link: skillLink.url,
          .skillPreviewLink: skillLink,
        ]
      ))

    textView.clicked(onLink: skillLink.url, at: 0)

    #expect(openedRequests == [request])
    #expect(openedRequests.first?.skill.content == content)
  }
}
