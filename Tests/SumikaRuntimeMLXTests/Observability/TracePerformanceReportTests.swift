import Foundation
import SumikaTestSupport
import Testing

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-mtp-performance-report-tests"))
struct TracePerformanceReportTests {
  @Test
  func reportSummarizesMTPRequestModeAndZeroDecodeCounters() throws {
    let temporaryDirectory = try scopedTemporaryDirectory()
    let traceURL = temporaryDirectory.appending(
      path: "mtp-trace.jsonl", directoryHint: .notDirectory)
    let outputDirectory = temporaryDirectory.appending(
      path: "report", directoryHint: .isDirectory)
    let requestRow =
      #"{"kind":"mlx_request","id":"12345678-1234-1234-1234-123456789abc","#
      + #""mtpDrafterLoaded":true,"speculativeDecodingMode":"mtp"}"#
    let decodeRow =
      #"{"kind":"turn_trace","generationID":"12345678-1234-1234-1234-123456789abc","#
      + #""phase":"runtime_decode","durationMs":250,"mtpProposedDraftTokens":0,"#
      + #""mtpAcceptedDraftTokens":0,"mtpAcceptanceRate":0,"mtpRoundCount":0,"#
      + #""mtpTargetModelCallCount":0,"mtpDraftModelCallCount":0,"#
      + #""mtpTargetVerifiedTokenCount":0,"mtpEmittedTokenCount":0,"#
      + #""mtpPassthroughReason":"main model did not emit drafter state"}"#
    let trace = [requestRow, decodeRow].joined(separator: "\n")
    try trace.write(to: traceURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = [
      "swift",
      Self.repositoryRoot
        .appending(path: "script/trace_performance_report.swift", directoryHint: .notDirectory)
        .path(percentEncoded: false),
      traceURL.path(percentEncoded: false),
      "--output-dir",
      outputDirectory.path(percentEncoded: false),
      "--limit",
      "all",
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()
    _ = stdout.fileHandleForReading.readDataToEndOfFile()
    let error = try #require(
      String(bytes: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    )

    #expect(process.terminationStatus == 0, Comment(rawValue: error))
    let markdown = try String(
      contentsOf: outputDirectory.appending(path: "latest.md", directoryHint: .notDirectory),
      encoding: .utf8
    )
    #expect(markdown.contains("## MTP Decoding"))
    let expectedSummary =
      "| 12345678 | yes | mtp | 0/0 | 0.0% | 0 | 0 | 0 | 0 | 0 "
      + "| main model did not emit drafter state |"
    #expect(markdown.contains(expectedSummary))

    let reportData = try Data(
      contentsOf: outputDirectory.appending(path: "latest.json", directoryHint: .notDirectory)
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: reportData) as? [String: Any]
    )
    let generations = try #require(report["generations"] as? [[String: Any]])
    let generation = try #require(generations.first)
    #expect(generation["mtpDrafterLoaded"] as? Bool == true)
    #expect(generation["speculativeDecodingMode"] as? String == "mtp")
    #expect(generation["mtpProposedDraftTokens"] as? Int == 0)
    #expect(generation["mtpAcceptedDraftTokens"] as? Int == 0)
    #expect(generation["mtpAcceptanceRate"] as? Double == 0)
    #expect(generation["mtpRoundCount"] as? Int == 0)
    #expect(generation["mtpTargetModelCallCount"] as? Int == 0)
    #expect(generation["mtpDraftModelCallCount"] as? Int == 0)
    #expect(generation["mtpTargetVerifiedTokenCount"] as? Int == 0)
    #expect(generation["mtpEmittedTokenCount"] as? Int == 0)
    #expect(
      generation["mtpPassthroughReason"] as? String
        == "main model did not emit drafter state"
    )
  }

  private static let repositoryRoot = URL(filePath: #filePath, directoryHint: .notDirectory)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
