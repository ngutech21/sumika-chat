import Foundation
import Testing

@Suite
struct TracePerformanceReportTests {
  @Test
  func separatesCompletionInfoAndLegacyDecodeTotals() throws {
    let repositoryURL = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-trace-report-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: temporaryURL)
    }

    let fixtureURL = temporaryURL.appending(path: "fixture.jsonl", directoryHint: .notDirectory)
    let outputURL = temporaryURL.appending(path: "report", directoryHint: .isDirectory)
    let moduleCacheURL = temporaryURL.appending(path: "module-cache", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    try traceFixture.write(to: fixtureURL, atomically: true, encoding: .utf8)

    let result = try runReport(
      repositoryURL: repositoryURL,
      moduleCacheURL: moduleCacheURL,
      arguments: [
        fixtureURL.path(percentEncoded: false),
        "--output-dir",
        outputURL.path(percentEncoded: false),
        "--scenario",
        "fixture",
        "--limit",
        "all",
      ]
    )
    #expect(
      result.status == 0,
      "trace_performance_report.swift failed: \(result.output)"
    )
    guard result.status == 0 else {
      return
    }

    let jsonData = try Data(
      contentsOf: outputURL.appending(path: "latest.json", directoryHint: .notDirectory))
    let report = try #require(
      JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
    let totals = try #require(report["totals"] as? [String: Any])
    #expect(integer(totals, "generationCount") == 5)
    #expect(integer(totals, "prefillGenerationCount") == 2)
    #expect(integer(totals, "promptTokens") == 1_500)
    #expect(double(totals, "prefillMs") == 3_000)
    #expect(double(totals, "promptTokensPerSecond") == 500)
    #expect(integer(totals, "decodeGenerationCount") == 2)
    #expect(integer(totals, "generatedTokenCount") == 200)
    #expect(double(totals, "decodeMs") == 1_500)
    #expect(isApproximately(double(totals, "decodeTokensPerSecond"), 133.333_333))
    #expect(integer(totals, "legacyDecodeGenerationCount") == 2)
    #expect(integer(totals, "legacyGeneratedTokenCount") == 150)
    #expect(double(totals, "legacyDecodeWallMs") == 6_000)
    #expect(isApproximately(double(totals, "legacyReportedTokensPerSecond"), 37.5))
    #expect(integer(totals, "mlxMaxActiveMemoryBytes") == 10 * mebibyte)
    #expect(integer(totals, "mlxMaxCacheMemoryBytes") == 11 * mebibyte)
    #expect(integer(totals, "mlxMaxPeakMemoryBytes") == 12 * mebibyte)

    let turns = try #require(report["turns"] as? [[String: Any]])
    let turnOne = try #require(turns.first { $0["turnID"] as? String == "turn-1" })
    let turnOneSummary = try #require(turnOne["summary"] as? [String: Any])
    #expect(integer(turnOneSummary, "generationCount") == 3)
    #expect(integer(turnOneSummary, "decodeGenerationCount") == 2)
    #expect(integer(turnOneSummary, "legacyDecodeGenerationCount") == 1)
    #expect(double(turnOneSummary, "legacyDecodeWallMs") == 4_000)
    #expect(double(turnOneSummary, "legacyReportedTokensPerSecond") == 50)

    let turnTwo = try #require(turns.first { $0["turnID"] as? String == "turn-2" })
    let turnTwoSummary = try #require(turnTwo["summary"] as? [String: Any])
    #expect(integer(turnTwoSummary, "generationCount") == 2)
    #expect(integer(turnTwoSummary, "decodeGenerationCount") == 0)
    #expect(integer(turnTwoSummary, "legacyDecodeGenerationCount") == 1)
    #expect(integer(turnTwoSummary, "legacyGeneratedTokenCount") == 50)

    let generations = try #require(report["generations"] as? [[String: Any]])
    let newGeneration = try #require(
      generations.first { $0["generationID"] as? String == "new-1" })
    #expect(newGeneration["decodeSemantics"] as? String == "mlx_generate_time")
    let legacyGeneration = try #require(
      generations.first { $0["generationID"] as? String == "legacy-1" })
    #expect(
      legacyGeneration["decodeSemantics"] as? String == "legacy_wall_after_first_chunk")
    let incompleteGeneration = try #require(
      generations.first { $0["generationID"] as? String == "incomplete" })
    #expect(incompleteGeneration["decodeSemantics"] == nil)
    #expect(incompleteGeneration["prefillMs"] == nil)

    let markdown = try String(
      contentsOf: outputURL.appending(path: "latest.md", directoryHint: .notDirectory),
      encoding: .utf8
    )
    #expect(markdown.contains("## Completion-info Totals"))
    #expect(markdown.contains("## Legacy Decode Timings"))
    #expect(markdown.contains("wall time after the first streamed chunk"))
    #expect(markdown.contains("process-global counter"))
    #expect(
      markdown.contains(
        "| Overall | 5 | 2 | 1500 | 3000.0 | 500.0 | 2 | 200 | 1500.0 | 133.3 | 10.0 | 11.0 | 12.0 |"
      )
    )
    #expect(markdown.contains("| Overall | 2 | 150 | 6000.0 | 37.5 |"))
    #expect(markdown.contains("MLX generateTime"))
    #expect(markdown.contains("legacy wall after first chunk"))
  }

  @Test
  func usesNonSandboxedApplicationSupportAsDefaultTracePath() throws {
    let repositoryURL = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-default-trace-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: temporaryURL)
    }

    let traceURL =
      temporaryURL
      .appending(path: "Library", directoryHint: .isDirectory)
      .appending(path: "Application Support", directoryHint: .isDirectory)
      .appending(path: "Sumika", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
      .appending(path: "gemma-trace.jsonl", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: traceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try traceFixture.write(to: traceURL, atomically: true, encoding: .utf8)

    let result = try runReport(
      repositoryURL: repositoryURL,
      moduleCacheURL: temporaryURL.appending(
        path: "module-cache", directoryHint: .isDirectory),
      arguments: ["--limit", "1", "--stdout-only"],
      environment: [
        "HOME": temporaryURL.path(percentEncoded: false),
        "CFFIXED_USER_HOME": temporaryURL.path(percentEncoded: false),
      ]
    )

    #expect(result.status == 0, "trace_performance_report.swift failed: \(result.output)")
    #expect(result.output.contains("- Trace: \(traceURL.path(percentEncoded: false))"))
    #expect(!result.output.contains("/Library/Containers/chat.sumika/"))
  }
}

private let mebibyte = 1_048_576

private func integer(_ object: [String: Any], _ key: String) -> Int? {
  (object[key] as? NSNumber)?.intValue
}

private func double(_ object: [String: Any], _ key: String) -> Double? {
  (object[key] as? NSNumber)?.doubleValue
}

private func isApproximately(_ value: Double?, _ expected: Double) -> Bool {
  guard let value else {
    return false
  }
  return abs(value - expected) < 0.000_1
}

private struct ReportProcessResult {
  let status: Int32
  let output: String
}

private func runReport(
  repositoryURL: URL,
  moduleCacheURL: URL,
  arguments: [String],
  environment: [String: String] = [:]
) throws -> ReportProcessResult {
  let process = Process()
  let output = Pipe()
  let scriptURL = repositoryURL.appending(
    path: "script/trace_performance_report.swift", directoryHint: .notDirectory)
  process.executableURL = URL(filePath: "/usr/bin/xcrun")
  process.currentDirectoryURL = repositoryURL
  process.arguments =
    [
      "swift",
      "-module-cache-path",
      moduleCacheURL.path(percentEncoded: false),
      scriptURL.path(percentEncoded: false),
    ] + arguments
  process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
    override
  }
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  return ReportProcessResult(
    status: process.terminationStatus,
    output: String(
      data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  )
}

private let traceFixture =
  """
  {"kind":"gemma_request","id":"new-1"}
  {"kind":"turn_trace","phase":"runtime_stream_start","generationID":"new-1","turnID":"turn-1","interactionMode":"agent","durationMs":3,"promptBytes":1200}
  {"kind":"turn_trace","phase":"runtime_prefill","generationID":"new-1","turnID":"turn-1","durationMs":2000,"promptTokens":1000,"tokensPerSecond":500,"mlxActiveMemoryBytesBeforePrefill":1048576,"mlxCacheMemoryBytesBeforePrefill":2097152,"mlxPeakMemoryBytesBeforePrefill":3145728,"mlxActiveMemoryBytesAfterPrefill":4194304,"mlxCacheMemoryBytesAfterPrefill":5242880,"mlxPeakMemoryBytesAfterPrefill":6291456}
  {"kind":"turn_trace","phase":"runtime_decode","generationID":"new-1","turnID":"turn-1","durationMs":1000,"generatedTokenCount":100,"tokensPerSecond":100,"mlxActiveMemoryBytesAfterGeneration":7340032,"mlxCacheMemoryBytesAfterGeneration":8388608,"mlxPeakMemoryBytesAfterGeneration":9437184}
  {"kind":"gemma_response","id":"new-1","metrics":{"generatedTokenCount":100,"tokensPerSecond":100}}
  {"kind":"turn_trace","phase":"runtime_prefill","generationID":"new-2","turnID":"turn-1","durationMs":1000,"promptTokens":500,"tokensPerSecond":500,"mlxActiveMemoryBytesBeforePrefill":2097152,"mlxCacheMemoryBytesBeforePrefill":3145728,"mlxPeakMemoryBytesBeforePrefill":4194304,"mlxActiveMemoryBytesAfterPrefill":8388608,"mlxCacheMemoryBytesAfterPrefill":9437184,"mlxPeakMemoryBytesAfterPrefill":10485760}
  {"kind":"turn_trace","phase":"runtime_decode","generationID":"new-2","turnID":"turn-1","durationMs":500,"generatedTokenCount":100,"tokensPerSecond":200,"mlxActiveMemoryBytesAfterGeneration":10485760,"mlxCacheMemoryBytesAfterGeneration":11534336,"mlxPeakMemoryBytesAfterGeneration":12582912}
  {"kind":"gemma_response","id":"new-2","metrics":{"generatedTokenCount":100,"tokensPerSecond":200}}
  {"kind":"turn_trace","phase":"runtime_stream_start","generationID":"legacy-1","turnID":"turn-1","durationMs":2}
  {"kind":"turn_trace","phase":"runtime_decode","generationID":"legacy-1","turnID":"turn-1","durationMs":4000,"tokensPerSecond":50}
  {"kind":"gemma_response","id":"legacy-1","metrics":{"generatedTokenCount":100,"tokensPerSecond":50}}
  {"kind":"turn_trace","phase":"runtime_decode","generationID":"legacy-2","turnID":"turn-2","durationMs":2000,"tokensPerSecond":25}
  {"kind":"gemma_response","id":"legacy-2","metrics":{"generatedTokenCount":50,"tokensPerSecond":25}}
  {"kind":"turn_trace","phase":"runtime_stream_start","generationID":"incomplete","turnID":"turn-2","durationMs":1}
  """
