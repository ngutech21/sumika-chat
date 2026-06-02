import Foundation
import Testing

struct ToolRuntimeDocumentationTests {
  @Test
  func toolRuntimeDocumentationCoversFlowHowToAndSecurityRules() throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let documentationURL = repositoryRoot.appending(
      path: "docs/tool-runtime.md",
      directoryHint: .notDirectory
    )

    let documentation = try String(contentsOf: documentationURL, encoding: .utf8)

    #expect(documentation.contains("flowchart TD"))
    #expect(documentation.contains("## Adding A Tool"))
    #expect(documentation.contains("TypedToolExecutor"))
    #expect(documentation.contains("AnyToolExecutor"))
    #expect(documentation.contains("Permission is evaluated after typed decoding"))
  }
}
