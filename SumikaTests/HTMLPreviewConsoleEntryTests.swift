import Foundation
import Testing

@testable import Sumika

struct HTMLPreviewConsoleEntryTests {
  @Test
  func formatsConsoleSourceLocation() {
    let entry = HTMLPreviewConsoleEntry(
      level: .error,
      message: "ReferenceError: foo is not defined",
      source: "file:///workspace/index.html",
      line: 27,
      column: 14
    )

    #expect(entry.detailText == "file:///workspace/index.html, line 27, column 14")
  }

  @Test
  func omitsEmptySourceLocation() {
    let entry = HTMLPreviewConsoleEntry(
      level: .log,
      message: "Hello from the page",
      source: nil,
      line: nil,
      column: nil
    )

    #expect(entry.detailText == nil)
  }
}
