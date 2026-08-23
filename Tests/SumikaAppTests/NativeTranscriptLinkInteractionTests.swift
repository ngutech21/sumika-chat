import AppKit
import Testing

@testable import SumikaApp

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
}
