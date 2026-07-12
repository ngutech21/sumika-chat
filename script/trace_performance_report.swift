#!/usr/bin/env swift

import Foundation

struct GenerationReport: Codable {
  var generationID: String
  var turnID: String?
  var interactionMode: String?
  var toolLoopIteration: Int?
  var cacheMode: String?
  var cacheReason: String?
  var contextSignature: String?
  var previousContextSignature: String?
  var appendOnly: Bool?
  var reusedMessageCount: Int?
  var appendedMessageCount: Int?
  var firstMismatchIndex: Int?
  var systemPromptChanged: Bool?
  var focusedContextChanged: Bool?
  var promptBytes: Int?
  var messageCount: Int?
  var contextTokenLimit: Int?
  var requestSeen: Bool
  var responseSeen: Bool
  var responseError: String?
  var streamStartMs: Double?
  var ttftMs: Double?
  var prefillMs: Double?
  var promptTokens: Int?
  var promptTokensPerSecond: Double?
  var decodeMs: Double?
  var decodeSemantics: DecodeSemantics?
  var partialDecodeMs: Double?
  var memoryClearMs: Double?
  var memoryClearReason: String?
  var uiFlushCount: Int
  var uiFlushMs: Double
  var generatedTokenCount: Int?
  var tokensPerSecond: Double?
  var mlxActiveMemoryBytesBeforePrefill: Int?
  var mlxCacheMemoryBytesBeforePrefill: Int?
  var mlxPeakMemoryBytesBeforePrefill: Int?
  var mlxActiveMemoryBytesAfterPrefill: Int?
  var mlxCacheMemoryBytesAfterPrefill: Int?
  var mlxPeakMemoryBytesAfterPrefill: Int?
  var mlxActiveMemoryBytesAfterGeneration: Int?
  var mlxCacheMemoryBytesAfterGeneration: Int?
  var mlxPeakMemoryBytesAfterGeneration: Int?
  var firstRowIndex: Int
}

enum DecodeSemantics: String, Codable {
  case mlxGenerateTime = "mlx_generate_time"
  case legacyWallAfterFirstChunk = "legacy_wall_after_first_chunk"
}

struct WorkSummary: Codable {
  var generationCount: Int
  var prefillGenerationCount: Int
  var decodeGenerationCount: Int
  var promptTokens: Int?
  var prefillMs: Double?
  var promptTokensPerSecond: Double?
  var generatedTokenCount: Int?
  var decodeMs: Double?
  var decodeTokensPerSecond: Double?
  var legacyDecodeGenerationCount: Int
  var legacyGeneratedTokenCount: Int?
  var legacyDecodeWallMs: Double?
  var legacyReportedTokensPerSecond: Double?
  var mlxMaxActiveMemoryBytes: Int?
  var mlxMaxCacheMemoryBytes: Int?
  var mlxMaxPeakMemoryBytes: Int?
}

struct TurnReport: Codable {
  var turnID: String
  var summary: WorkSummary
}

struct PerformanceReport: Codable {
  var timestamp: String
  var gitCommit: String?
  var gitBranch: String?
  var scenario: String
  var modelID: String?
  var tracePath: String
  var rowCount: Int
  var generationCount: Int
  var totals: WorkSummary
  var turns: [TurnReport]
  var generations: [GenerationReport]
}

func usage() -> Never {
  fputs(
    """
    usage: trace_performance_report.swift [trace.jsonl] [options]

    options:
      --output-dir <path>   directory for reports, default .perf/ui-tests
      --scenario <name>     scenario label, default ui-trace
      --model-id <id>       model label to include in the report
      --limit <n|all>       most recent generations to include, default 20
      --stdout-only         print summary without writing files
      --help                show this help

    The report never copies prompts, file contents, or model output.
    """,
    stderr
  )
  exit(2)
}

func defaultTraceURL() -> URL {
  URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    .appending(path: "Library", directoryHint: .isDirectory)
    .appending(path: "Application Support", directoryHint: .isDirectory)
    .appending(path: "Sumika", directoryHint: .isDirectory)
    .appending(path: "debug", directoryHint: .isDirectory)
    .appending(path: "gemma-trace.jsonl", directoryHint: .notDirectory)
}

func value<T>(_ dictionary: [String: Any], _ key: String, as _: T.Type) -> T? {
  dictionary[key] as? T
}

func doubleValue(_ dictionary: [String: Any], _ key: String) -> Double? {
  if let value = dictionary[key] as? Double {
    return value
  }
  if let value = dictionary[key] as? Int {
    return Double(value)
  }
  if let value = dictionary[key] as? NSNumber {
    return value.doubleValue
  }
  return nil
}

func intValue(_ dictionary: [String: Any], _ key: String) -> Int? {
  if let value = dictionary[key] as? Int {
    return value
  }
  if let value = dictionary[key] as? NSNumber {
    return value.intValue
  }
  return nil
}

func boolValue(_ dictionary: [String: Any], _ key: String) -> Bool? {
  if let value = dictionary[key] as? Bool {
    return value
  }
  if let value = dictionary[key] as? NSNumber {
    return value.boolValue
  }
  return nil
}

func timestampForFileName(_ date: Date = Date()) -> String {
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
  return formatter.string(from: date)
}

func timestampISO8601(_ date: Date = Date()) -> String {
  ISO8601DateFormatter().string(from: date)
}

func gitValue(_ arguments: [String]) -> String? {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/git")
  process.arguments = arguments

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = Pipe()

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return nil
  }

  guard process.terminationStatus == 0 else {
    return nil
  }

  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let text = String(data: data, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return text?.isEmpty == false ? text : nil
}

func newGenerationReport(id: String, rowIndex: Int) -> GenerationReport {
  GenerationReport(
    generationID: id,
    toolLoopIteration: nil,
    requestSeen: false,
    responseSeen: false,
    uiFlushCount: 0,
    uiFlushMs: 0,
    firstRowIndex: rowIndex
  )
}

func mergeTraceFields(_ object: [String: Any], into report: inout GenerationReport) {
  report.turnID = report.turnID ?? value(object, "turnID", as: String.self)
  report.interactionMode =
    report.interactionMode ?? value(object, "interactionMode", as: String.self)
  report.toolLoopIteration = report.toolLoopIteration ?? intValue(object, "toolLoopIteration")
  report.cacheMode = report.cacheMode ?? value(object, "cacheMode", as: String.self)
  report.cacheReason =
    report.cacheReason
    ?? value(object, "cacheReason", as: String.self)
    ?? value(object, "mismatchReason", as: String.self)
  report.memoryClearReason =
    report.memoryClearReason ?? value(object, "memoryClearReason", as: String.self)
  report.contextSignature =
    report.contextSignature ?? value(object, "contextSignature", as: String.self)
  report.previousContextSignature =
    report.previousContextSignature ?? value(object, "previousContextSignature", as: String.self)
  report.appendOnly = report.appendOnly ?? boolValue(object, "appendOnly")
  report.reusedMessageCount =
    report.reusedMessageCount ?? intValue(object, "reusedMessageCount")
  report.appendedMessageCount =
    report.appendedMessageCount ?? intValue(object, "appendedMessageCount")
  report.firstMismatchIndex =
    report.firstMismatchIndex ?? intValue(object, "firstMismatchIndex")
  report.systemPromptChanged =
    report.systemPromptChanged ?? boolValue(object, "systemPromptChanged")
  report.focusedContextChanged =
    report.focusedContextChanged ?? boolValue(object, "focusedContextChanged")
  report.promptBytes = report.promptBytes ?? intValue(object, "promptBytes")
  report.messageCount = report.messageCount ?? intValue(object, "messageCount")
}

func summary(for generations: [GenerationReport]) -> WorkSummary {
  let completionInfoGenerations = generations.filter {
    $0.decodeSemantics == .mlxGenerateTime
  }
  let legacyGenerations = generations.filter {
    $0.decodeSemantics == .legacyWallAfterFirstChunk
  }
  let promptTokens = sum(generations.map(\.promptTokens))
  let prefillMs = sum(generations.map(\.prefillMs))
  let generatedTokens = sum(completionInfoGenerations.map(\.generatedTokenCount))
  let decodeMs = sum(completionInfoGenerations.map(\.decodeMs))

  return WorkSummary(
    generationCount: generations.count,
    prefillGenerationCount: generations.count(where: { $0.prefillMs != nil }),
    decodeGenerationCount: completionInfoGenerations.count,
    promptTokens: promptTokens,
    prefillMs: prefillMs,
    promptTokensPerSecond: weightedThroughput(
      generations.map { ($0.promptTokens, $0.prefillMs) }
    ),
    generatedTokenCount: generatedTokens,
    decodeMs: decodeMs,
    decodeTokensPerSecond: weightedThroughput(
      completionInfoGenerations.map { ($0.generatedTokenCount, $0.decodeMs) }
    ),
    legacyDecodeGenerationCount: legacyGenerations.count,
    legacyGeneratedTokenCount: sum(legacyGenerations.map(\.generatedTokenCount)),
    legacyDecodeWallMs: sum(legacyGenerations.map(\.decodeMs)),
    legacyReportedTokensPerSecond: aggregateReportedThroughput(
      legacyGenerations.map { ($0.generatedTokenCount, $0.tokensPerSecond) }
    ),
    mlxMaxActiveMemoryBytes: maximum(
      generations.flatMap {
        [
          $0.mlxActiveMemoryBytesBeforePrefill,
          $0.mlxActiveMemoryBytesAfterPrefill,
          $0.mlxActiveMemoryBytesAfterGeneration,
        ]
      }
    ),
    mlxMaxCacheMemoryBytes: maximum(
      generations.flatMap {
        [
          $0.mlxCacheMemoryBytesBeforePrefill,
          $0.mlxCacheMemoryBytesAfterPrefill,
          $0.mlxCacheMemoryBytesAfterGeneration,
        ]
      }
    ),
    mlxMaxPeakMemoryBytes: maximum(
      generations.flatMap {
        [
          $0.mlxPeakMemoryBytesBeforePrefill,
          $0.mlxPeakMemoryBytesAfterPrefill,
          $0.mlxPeakMemoryBytesAfterGeneration,
        ]
      }
    )
  )
}

func turnReports(for generations: [GenerationReport]) -> [TurnReport] {
  var orderedTurnIDs: [String] = []
  var seenTurnIDs: Set<String> = []
  for generation in generations {
    guard let turnID = generation.turnID, seenTurnIDs.insert(turnID).inserted else {
      continue
    }
    orderedTurnIDs.append(turnID)
  }

  return orderedTurnIDs.map { turnID in
    TurnReport(
      turnID: turnID,
      summary: summary(for: generations.filter { $0.turnID == turnID })
    )
  }
}

func sum(_ values: [Int?]) -> Int? {
  let values = values.compactMap { $0 }
  return values.isEmpty ? nil : values.reduce(0, +)
}

func sum(_ values: [Double?]) -> Double? {
  let values = values.compactMap { $0 }
  return values.isEmpty ? nil : values.reduce(0, +)
}

func maximum(_ values: [Int?]) -> Int? {
  values.compactMap { $0 }.max()
}

func weightedThroughput(_ samples: [(tokens: Int?, durationMs: Double?)]) -> Double? {
  let completeSamples = samples.compactMap { sample -> (Int, Double)? in
    guard let tokens = sample.tokens, let durationMs = sample.durationMs, durationMs > 0 else {
      return nil
    }
    return (tokens, durationMs)
  }
  guard !completeSamples.isEmpty else {
    return nil
  }

  let totalTokens = completeSamples.reduce(0) { $0 + $1.0 }
  let totalDurationMs = completeSamples.reduce(0) { $0 + $1.1 }
  return Double(totalTokens) / totalDurationMs * 1_000
}

func aggregateReportedThroughput(_ samples: [(tokens: Int?, tokensPerSecond: Double?)])
  -> Double?
{
  let completeSamples = samples.compactMap { sample -> (Int, Double)? in
    guard
      let tokens = sample.tokens,
      let tokensPerSecond = sample.tokensPerSecond,
      tokensPerSecond > 0
    else {
      return nil
    }
    return (tokens, tokensPerSecond)
  }
  guard !completeSamples.isEmpty else {
    return nil
  }

  let totalTokens = completeSamples.reduce(0) { $0 + $1.0 }
  let effectiveDurationSeconds = completeSamples.reduce(0.0) {
    $0 + Double($1.0) / $1.1
  }
  return effectiveDurationSeconds > 0 ? Double(totalTokens) / effectiveDurationSeconds : nil
}

func markdown(_ report: PerformanceReport) -> String {
  var lines: [String] = [
    "# Sumika Performance Report",
    "",
    "- Timestamp: \(report.timestamp)",
    "- Scenario: \(report.scenario)",
    "- Model: \(report.modelID ?? "-")",
    "- Git commit: \(report.gitCommit ?? "-")",
    "- Git branch: \(report.gitBranch ?? "-")",
    "- Trace: \(report.tracePath)",
    "- Rows: \(report.rowCount)",
    "- Generations: \(report.generationCount)",
    "",
    "## Completion-info Totals",
    "",
    "Decode duration is MLX `GenerateCompletionInfo.generateTime`. Legacy decode wall timings are excluded and reported separately below.",
    "Memory columns are maximum observed snapshots, not sums. MLX peak memory is a process-global counter, not a per-generation peak.",
    "",
    "| Scope | Generations | Prefills | Prompt tokens | Prefill ms | Prompt tok/s | MLX decodes | MLX generated tokens | MLX generate ms | MLX decode tok/s | Max active MiB | Max cache MiB | Process peak MiB |",
    "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
  ]

  appendSummaryRow(scope: "Overall", summary: report.totals, to: &lines)
  for turn in report.turns {
    appendSummaryRow(scope: "Turn \(turn.turnID)", summary: turn.summary, to: &lines)
  }

  appendLegacyDecodeSummary(to: &lines, report: report)

  lines.append(contentsOf: [
    "",
    "## Generations",
    "",
    "| # | Mode | Iter | Cache | Reason | Memory clear | TTFT ms | Prompt tokens | Prefill ms | Prompt tok/s | Generated | Decode semantics | Decode ms | Decode tok/s | Prompt bytes | Error |",
    "|---:|---|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---|",
  ])

  for (index, generation) in report.generations.enumerated() {
    let row: [String] = [
      String(index + 1),
      generation.interactionMode ?? "-",
      generation.toolLoopIteration.map(String.init) ?? "-",
      generation.cacheMode ?? "-",
      generation.cacheReason ?? "-",
      generation.memoryClearReason ?? "-",
      formatted(generation.ttftMs),
      generation.promptTokens.map(String.init) ?? "-",
      formatted(generation.prefillMs),
      formatted(generation.promptTokensPerSecond),
      generation.generatedTokenCount.map(String.init) ?? "-",
      decodeSemanticsLabel(generation.decodeSemantics),
      formatted(generation.decodeMs),
      formatted(generation.tokensPerSecond),
      generation.promptBytes.map(String.init) ?? "-",
      generation.responseError ?? "-",
    ]
    lines.append(row.joined(separator: " | ").wrappedTableRow())
  }

  appendMemoryTable(to: &lines, generations: report.generations)
  appendToolLoopTTFTComparison(to: &lines, generations: report.generations)

  lines.append("")
  return lines.joined(separator: "\n")
}

func appendLegacyDecodeSummary(to lines: inout [String], report: PerformanceReport) {
  guard report.totals.legacyDecodeGenerationCount > 0 else {
    return
  }

  lines.append(contentsOf: [
    "",
    "## Legacy Decode Timings",
    "",
    "Legacy `runtime_decode` duration is wall time after the first streamed chunk, not MLX `generateTime`. These rows remain visible for backward compatibility but are excluded from completion-info totals. Reported tok/s is aggregated independently from legacy completion metrics.",
    "",
    "| Scope | Legacy decodes | Legacy generated tokens | Wall after first chunk ms | Reported decode tok/s |",
    "|---|---:|---:|---:|---:|",
  ])
  appendLegacyDecodeSummaryRow(scope: "Overall", summary: report.totals, to: &lines)
  for turn in report.turns where turn.summary.legacyDecodeGenerationCount > 0 {
    appendLegacyDecodeSummaryRow(
      scope: "Turn \(turn.turnID)", summary: turn.summary, to: &lines)
  }
}

func appendLegacyDecodeSummaryRow(
  scope: String,
  summary: WorkSummary,
  to lines: inout [String]
) {
  lines.append(
    [
      scope,
      String(summary.legacyDecodeGenerationCount),
      summary.legacyGeneratedTokenCount.map(String.init) ?? "-",
      formatted(summary.legacyDecodeWallMs),
      formatted(summary.legacyReportedTokensPerSecond),
    ].joined(separator: " | ").wrappedTableRow()
  )
}

func appendSummaryRow(scope: String, summary: WorkSummary, to lines: inout [String]) {
  lines.append(
    [
      scope,
      String(summary.generationCount),
      String(summary.prefillGenerationCount),
      summary.promptTokens.map(String.init) ?? "-",
      formatted(summary.prefillMs),
      formatted(summary.promptTokensPerSecond),
      String(summary.decodeGenerationCount),
      summary.generatedTokenCount.map(String.init) ?? "-",
      formatted(summary.decodeMs),
      formatted(summary.decodeTokensPerSecond),
      formattedMiB(summary.mlxMaxActiveMemoryBytes),
      formattedMiB(summary.mlxMaxCacheMemoryBytes),
      formattedMiB(summary.mlxMaxPeakMemoryBytes),
    ].joined(separator: " | ").wrappedTableRow()
  )
}

func appendMemoryTable(to lines: inout [String], generations: [GenerationReport]) {
  guard generations.contains(where: { $0.hasMLXMemorySnapshot }) else {
    return
  }

  lines.append(contentsOf: [
    "",
    "## MLX Memory by Generation",
    "",
    "Values are MiB at before-prefill / after-prefill / after-generation.",
    "Peak is the process-global MLX peak counter at each observation, not a peak attributable to that generation.",
    "",
    "| # | Active MiB | Cache MiB | Peak MiB |",
    "|---:|---|---|---|",
  ])

  for (index, generation) in generations.enumerated() {
    lines.append(
      [
        String(index + 1),
        memoryProgression(
          generation.mlxActiveMemoryBytesBeforePrefill,
          generation.mlxActiveMemoryBytesAfterPrefill,
          generation.mlxActiveMemoryBytesAfterGeneration
        ),
        memoryProgression(
          generation.mlxCacheMemoryBytesBeforePrefill,
          generation.mlxCacheMemoryBytesAfterPrefill,
          generation.mlxCacheMemoryBytesAfterGeneration
        ),
        memoryProgression(
          generation.mlxPeakMemoryBytesBeforePrefill,
          generation.mlxPeakMemoryBytesAfterPrefill,
          generation.mlxPeakMemoryBytesAfterGeneration
        ),
      ].joined(separator: " | ").wrappedTableRow()
    )
  }
}

func appendToolLoopTTFTComparison(to lines: inout [String], generations: [GenerationReport]) {
  let groupedByTurn = Dictionary(
    grouping: generations.filter { $0.turnID != nil && $0.toolLoopIteration != nil },
    by: { $0.turnID ?? "" }
  )
  let comparisons = groupedByTurn.compactMap {
    turnID, generations -> (
      String, Double?, Double?, Double?
    )? in
    let firstToolTTFT =
      generations
      .filter { $0.toolLoopIteration == 1 }
      .compactMap(\.ttftMs)
      .first
    let followUpTTFTs =
      generations
      .filter { ($0.toolLoopIteration ?? 0) > 1 }
      .compactMap(\.ttftMs)

    guard firstToolTTFT != nil || !followUpTTFTs.isEmpty else {
      return nil
    }

    return (
      turnID,
      firstToolTTFT,
      followUpTTFTs.min(),
      followUpTTFTs.max()
    )
  }
  .sorted { left, right in left.0 < right.0 }

  guard !comparisons.isEmpty else {
    return
  }

  lines.append(contentsOf: [
    "",
    "## Tool Loop TTFT",
    "",
    "| Turn | First tool TTFT ms | Follow-up min TTFT ms | Follow-up max TTFT ms |",
    "|---|---:|---:|---:|",
  ])

  for comparison in comparisons {
    lines.append(
      [
        comparison.0,
        formatted(comparison.1),
        formatted(comparison.2),
        formatted(comparison.3),
      ].joined(separator: " | ").wrappedTableRow()
    )
  }
}

func formatted(_ value: Double?) -> String {
  guard let value else {
    return "-"
  }
  return String(format: "%.1f", value)
}

func decodeSemanticsLabel(_ semantics: DecodeSemantics?) -> String {
  switch semantics {
  case .mlxGenerateTime:
    "MLX generateTime"
  case .legacyWallAfterFirstChunk:
    "legacy wall after first chunk"
  case nil:
    "-"
  }
}

func formattedMiB(_ bytes: Int?) -> String {
  guard let bytes else {
    return "-"
  }
  return String(format: "%.1f", Double(bytes) / 1_048_576)
}

func memoryProgression(_ beforePrefill: Int?, _ afterPrefill: Int?, _ afterGeneration: Int?)
  -> String
{
  [beforePrefill, afterPrefill, afterGeneration]
    .map(formattedMiB)
    .joined(separator: " / ")
}

var traceURL = defaultTraceURL()
var outputDirectory = URL(filePath: ".perf/ui-tests", directoryHint: .isDirectory)
var scenario = "ui-trace"
var modelID: String?
var limit: Int? = 20
var stdoutOnly = false

let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
var didSetTracePath = false
while index < arguments.count {
  let argument = arguments[index]
  switch argument {
  case "--help", "-h":
    usage()
  case "--output-dir":
    index += 1
    guard index < arguments.count else { usage() }
    outputDirectory = URL(filePath: arguments[index], directoryHint: .isDirectory)
  case "--scenario":
    index += 1
    guard index < arguments.count else { usage() }
    scenario = arguments[index]
  case "--model-id":
    index += 1
    guard index < arguments.count else { usage() }
    modelID = arguments[index]
  case "--limit":
    index += 1
    guard index < arguments.count else { usage() }
    if arguments[index] == "all" {
      limit = nil
    } else if let parsedLimit = Int(arguments[index]), parsedLimit > 0 {
      limit = parsedLimit
    } else {
      usage()
    }
  case "--stdout-only":
    stdoutOnly = true
  default:
    guard !argument.hasPrefix("-"), !didSetTracePath else {
      usage()
    }
    traceURL = URL(filePath: argument, directoryHint: .notDirectory)
    didSetTracePath = true
  }
  index += 1
}

guard FileManager.default.fileExists(atPath: traceURL.path(percentEncoded: false)) else {
  fputs("trace file not found: \(traceURL.path(percentEncoded: false))\n", stderr)
  exit(1)
}

let traceText = try String(contentsOf: traceURL, encoding: .utf8)
let rows = traceText.split(separator: "\n", omittingEmptySubsequences: true)
var reportsByGenerationID: [String: GenerationReport] = [:]
var generationOrder: [String] = []

for (rowIndex, row) in rows.enumerated() {
  guard
    let data = String(row).data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let kind = value(object, "kind", as: String.self)
  else {
    continue
  }

  let id: String?
  switch kind {
  case "turn_trace":
    id = value(object, "generationID", as: String.self)
  case "gemma_request", "gemma_response":
    id = value(object, "id", as: String.self)
  default:
    id = nil
  }

  guard let generationID = id else {
    continue
  }

  if reportsByGenerationID[generationID] == nil {
    reportsByGenerationID[generationID] = newGenerationReport(id: generationID, rowIndex: rowIndex)
    generationOrder.append(generationID)
  }

  guard var report = reportsByGenerationID[generationID] else {
    continue
  }

  switch kind {
  case "gemma_request":
    report.requestSeen = true
    report.contextTokenLimit = report.contextTokenLimit ?? intValue(object, "contextTokenLimit")
  case "gemma_response":
    report.responseSeen = true
    report.responseError = value(object, "error", as: String.self)
    if let metrics = value(object, "metrics", as: [String: Any].self) {
      report.generatedTokenCount =
        report.generatedTokenCount ?? intValue(metrics, "generatedTokenCount")
      report.tokensPerSecond = report.tokensPerSecond ?? doubleValue(metrics, "tokensPerSecond")
    }
  case "turn_trace":
    mergeTraceFields(object, into: &report)
    switch value(object, "phase", as: String.self) {
    case "runtime_stream_start":
      report.streamStartMs = doubleValue(object, "durationMs")
    case "runtime_ttft":
      report.ttftMs = doubleValue(object, "ttftMs") ?? doubleValue(object, "durationMs")
    case "runtime_prefill":
      report.prefillMs = doubleValue(object, "durationMs")
      report.promptTokens = intValue(object, "promptTokens") ?? report.promptTokens
      report.promptTokensPerSecond =
        doubleValue(object, "tokensPerSecond") ?? report.promptTokensPerSecond
      report.mlxActiveMemoryBytesBeforePrefill =
        intValue(object, "mlxActiveMemoryBytesBeforePrefill")
        ?? report.mlxActiveMemoryBytesBeforePrefill
      report.mlxCacheMemoryBytesBeforePrefill =
        intValue(object, "mlxCacheMemoryBytesBeforePrefill")
        ?? report.mlxCacheMemoryBytesBeforePrefill
      report.mlxPeakMemoryBytesBeforePrefill =
        intValue(object, "mlxPeakMemoryBytesBeforePrefill")
        ?? report.mlxPeakMemoryBytesBeforePrefill
      report.mlxActiveMemoryBytesAfterPrefill =
        intValue(object, "mlxActiveMemoryBytesAfterPrefill")
        ?? report.mlxActiveMemoryBytesAfterPrefill
      report.mlxCacheMemoryBytesAfterPrefill =
        intValue(object, "mlxCacheMemoryBytesAfterPrefill")
        ?? report.mlxCacheMemoryBytesAfterPrefill
      report.mlxPeakMemoryBytesAfterPrefill =
        intValue(object, "mlxPeakMemoryBytesAfterPrefill")
        ?? report.mlxPeakMemoryBytesAfterPrefill
    case "runtime_decode":
      let completionInfoGeneratedTokenCount = intValue(object, "generatedTokenCount")
      report.decodeMs = doubleValue(object, "durationMs")
      report.decodeSemantics =
        completionInfoGeneratedTokenCount != nil || report.prefillMs != nil
        ? .mlxGenerateTime
        : .legacyWallAfterFirstChunk
      report.generatedTokenCount =
        completionInfoGeneratedTokenCount ?? report.generatedTokenCount
      report.tokensPerSecond = doubleValue(object, "tokensPerSecond") ?? report.tokensPerSecond
      report.mlxActiveMemoryBytesAfterGeneration =
        intValue(object, "mlxActiveMemoryBytesAfterGeneration")
        ?? report.mlxActiveMemoryBytesAfterGeneration
      report.mlxCacheMemoryBytesAfterGeneration =
        intValue(object, "mlxCacheMemoryBytesAfterGeneration")
        ?? report.mlxCacheMemoryBytesAfterGeneration
      report.mlxPeakMemoryBytesAfterGeneration =
        intValue(object, "mlxPeakMemoryBytesAfterGeneration")
        ?? report.mlxPeakMemoryBytesAfterGeneration
    case "runtime_partial_decode":
      report.partialDecodeMs = doubleValue(object, "durationMs")
    case "memory_clear":
      report.memoryClearMs = doubleValue(object, "durationMs")
    case "ui_flush":
      report.uiFlushCount += 1
      report.uiFlushMs += doubleValue(object, "durationMs") ?? 0
    default:
      break
    }
  default:
    break
  }

  reportsByGenerationID[generationID] = report
}

var generations = generationOrder.compactMap { reportsByGenerationID[$0] }
if let limit, generations.count > limit {
  generations = Array(generations.suffix(limit))
}

let now = Date()
let report = PerformanceReport(
  timestamp: timestampISO8601(now),
  gitCommit: gitValue(["rev-parse", "--short", "HEAD"]),
  gitBranch: gitValue(["branch", "--show-current"]),
  scenario: scenario,
  modelID: modelID,
  tracePath: traceURL.path(percentEncoded: false),
  rowCount: rows.count,
  generationCount: generations.count,
  totals: summary(for: generations),
  turns: turnReports(for: generations),
  generations: generations
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let jsonData = try encoder.encode(report)
let markdownText = markdown(report)

if stdoutOnly {
  print(markdownText)
  exit(0)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let baseName = [
  timestampForFileName(now),
  modelID,
  scenario,
].compactMap { $0?.replacingOccurrences(of: "/", with: "-") }
  .joined(separator: "-")

let jsonURL = outputDirectory.appending(path: "\(baseName).json", directoryHint: .notDirectory)
let markdownURL = outputDirectory.appending(path: "\(baseName).md", directoryHint: .notDirectory)
let latestJSONURL = outputDirectory.appending(path: "latest.json", directoryHint: .notDirectory)
let latestMarkdownURL = outputDirectory.appending(path: "latest.md", directoryHint: .notDirectory)

try jsonData.write(to: jsonURL, options: .atomic)
try markdownText.write(to: markdownURL, atomically: true, encoding: .utf8)
try jsonData.write(to: latestJSONURL, options: .atomic)
try markdownText.write(to: latestMarkdownURL, atomically: true, encoding: .utf8)

print("Wrote \(jsonURL.path(percentEncoded: false))")
print("Wrote \(markdownURL.path(percentEncoded: false))")

extension String {
  func wrappedTableRow() -> String {
    "| " + self + " |"
  }
}

extension GenerationReport {
  var hasMLXMemorySnapshot: Bool {
    [
      mlxActiveMemoryBytesBeforePrefill,
      mlxCacheMemoryBytesBeforePrefill,
      mlxPeakMemoryBytesBeforePrefill,
      mlxActiveMemoryBytesAfterPrefill,
      mlxCacheMemoryBytesAfterPrefill,
      mlxPeakMemoryBytesAfterPrefill,
      mlxActiveMemoryBytesAfterGeneration,
      mlxCacheMemoryBytesAfterGeneration,
      mlxPeakMemoryBytesAfterGeneration,
    ].contains(where: { $0 != nil })
  }
}
