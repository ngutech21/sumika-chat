import Foundation
import Testing

struct ToolRuntimeDocumentationTests {
  @Test
  func toolRuntimeDocumentationCoversFlowHowToAndSecurityRules() throws {
    let documentationURL = repositoryRoot().appending(
      path: "docs/tool-runtime.md",
      directoryHint: .notDirectory
    )

    let documentation = try String(contentsOf: documentationURL, encoding: .utf8)

    #expect(documentation.contains("flowchart TD"))
    #expect(documentation.contains("## Adding A Tool"))
    #expect(documentation.contains("TypedToolExecutor"))
    #expect(documentation.contains("AnyToolExecutor"))
    #expect(documentation.contains("validated into typed payloads"))
  }

  @Test
  func chatRuntimeDocumentationCoversTurnLifecycleCancellationAndContextFiltering() throws {
    let documentationURL = repositoryRoot().appending(
      path: "docs/chat-runtime.md",
      directoryHint: .notDirectory
    )

    let documentation = try String(contentsOf: documentationURL, encoding: .utf8)

    #expect(documentation.contains("flowchart TD"))
    #expect(documentation.contains("ChatTurnCoordinator"))
    #expect(documentation.contains("ChatModelContextBuilder"))
    #expect(documentation.contains("## Cancellation Rules"))
    #expect(documentation.contains("Future independent prompts exclude those messages"))
  }

  private func repositoryRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
