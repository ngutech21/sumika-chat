import Foundation
import Testing

@testable import LocalCoderCore

struct ToolResultPayloadTests {
  @Test
  func toolResultPayloadCodableRoundTripsBuiltInResults() throws {
    let payloads: [ToolResultPayload] = [
      .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "1: hello", truncated: true)
        )),
      .writeFile(
        .success(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"), bytesWritten: 12)),
      .editFile(
        .oldTextNotFound(
          path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
          currentContent: ToolTextOutput(text: "let value = 1"),
          recovery: .readFile(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"))
        )),
      .invalidTool(
        InvalidToolResult(
          originalName: "deploy",
          reason: .unknownToolName("deploy")
        )),
      .failure(
        ToolFailure(
          toolName: .readFile,
          path: WorkspaceRelativePath(rawValue: "missing.swift"),
          reason: .fileNotFound(
            path: WorkspaceRelativePath(rawValue: "missing.swift"),
            suggestions: [
              MissingPathSuggestion(
                path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
                reason: "same extension",
                confidence: 0.8
              )
            ]
          ),
          recovery: .chooseOneOf(paths: [WorkspaceRelativePath(rawValue: "Sources/App.swift")])
        )),
    ]

    let decoded = try JSONDecoder().decode(
      [ToolResultPayload].self,
      from: JSONEncoder().encode(payloads)
    )

    #expect(decoded == payloads)
  }

  @Test
  func previewRendersFromStructuredPayload() {
    let payload = ToolResultPayload.editFile(
      .multipleMatches(
        path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
        matchCount: 2,
        recovery: .retryWithMoreContext(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"))
      ))

    let preview = payload.preview

    #expect(preview.status == .failed)
    #expect(preview.text.contains("matched more than once"))
    #expect(preview.text.contains("Retry with a larger exact old_text block"))
    #expect(preview.affectedPaths == ["Sources/App.swift"])
  }

  @Test
  func toolResultModelMessageDecodesLegacyPreviewOnlyShape() throws {
    struct LegacyToolResultModelMessage: Codable {
      var callID: UUID
      var toolName: ToolName
      var preview: ToolResultPreview
    }

    let legacy = LegacyToolResultModelMessage(
      callID: UUID(),
      toolName: .readFile,
      preview: ToolResultPreview(text: "1: hello")
    )

    let decoded = try JSONDecoder().decode(
      ToolResultModelMessage.self,
      from: JSONEncoder().encode(legacy)
    )

    #expect(decoded.callID == legacy.callID)
    #expect(decoded.toolName == .readFile)
    #expect(decoded.payload == nil)
    #expect(decoded.preview == legacy.preview)
  }

  @Test
  func toolPermissionEvaluationDecodesLegacyShapeWithoutWorkspaceRelativePaths() throws {
    struct LegacyToolPermissionEvaluation: Codable {
      var decision: ToolPermissionDecision
      var reason: String
      var riskLevel: ToolRiskLevel
      var normalizedPaths: [String]
    }

    let legacy = LegacyToolPermissionEvaluation(
      decision: .requiresApproval,
      reason: "Writing files inside the workspace requires approval.",
      riskLevel: .high,
      normalizedPaths: ["/tmp/project/README.md"]
    )

    let decoded = try JSONDecoder().decode(
      ToolPermissionEvaluation.self,
      from: JSONEncoder().encode(legacy)
    )

    #expect(decoded.decision == .requiresApproval)
    #expect(decoded.reason == legacy.reason)
    #expect(decoded.riskLevel == .high)
    #expect(decoded.normalizedPaths == ["/tmp/project/README.md"])
    #expect(decoded.workspaceRelativePaths.isEmpty)
  }
}
