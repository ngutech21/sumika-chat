import Foundation
import Testing
import WebKit

@testable import local_coder

struct HTMLPreviewJavaScriptErrorFormatterTests {
  @Test
  func prefersWebKitJavaScriptExceptionMetadata() {
    let error = NSError(
      domain: WKErrorDomain,
      code: WKError.javaScriptExceptionOccurred.rawValue,
      userInfo: [
        "WKJavaScriptExceptionMessage": "Cannot read properties of undefined",
        "WKJavaScriptExceptionSourceURL": "file:///workspace/index.html",
        "WKJavaScriptExceptionLineNumber": 27,
        "WKJavaScriptExceptionColumnNumber": 14,
      ]
    )

    let description = HTMLPreviewJavaScriptErrorFormatter.describe(error)

    #expect(description == """
      JavaScript exception: Cannot read properties of undefined
      Source: file:///workspace/index.html
      Location: line 27, column 14
      """)
  }

  @Test
  func fallsBackToLocalizedDescriptionWhenMetadataIsMissing() {
    let error = NSError(
      domain: "TestErrorDomain",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "A JavaScript exception occurred"]
    )

    let description = HTMLPreviewJavaScriptErrorFormatter.describe(error)

    #expect(description == "A JavaScript exception occurred")
  }
}
