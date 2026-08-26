#!/usr/bin/env swift

import Foundation

struct TraceRuntimeState: Codable, Equatable {
  var applicationActivation: String?
  var applicationVisibility: String?
  var applicationOcclusion: String?
  var mainWindowVisibility: String?
  var generationActivityRequest: String?
}

struct PartialDecodeSample: Codable {
  var timestamp: String?
  var durationMs: Double
  var generatedTokenCount: Int
  var generatedTokenCountIsEstimate: Bool
  var runtimeState: TraceRuntimeState?
}

struct PartialDecodeInterval: Codable {
  var startTimestamp: String?
  var endTimestamp: String?
  var startDurationMs: Double
  var endDurationMs: Double
  var deltaTokenCount: Int
  var durationMs: Double
  var tokensPerSecond: Double?
  var startState: TraceRuntimeState?
  var endState: TraceRuntimeState?
  var hasMatchingEndpointState: Bool
}

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
  var mlxCacheDecision: String?
  var mlxCacheMismatchReason: String?
  var fullPromptTokens: Int?
  var expectedCachedTokens: Int?
  var expectedSuffixTokens: Int?
  var reusedPromptTokens: Int?
  var cacheEfficiency: Double?
  var inputMaskPresent: Bool?
  var preparedMediaPresent: Bool?
  var newMediaPresent: Bool?
  var cacheTrimmable: Bool?
  var cacheTypes: [String]?
  var decodeMs: Double?
  var streamStartState: TraceRuntimeState?
  var streamEndMs: Double?
  var streamEndState: TraceRuntimeState?
  var streamOutcome: String?
  var partialDecodeSamples: [PartialDecodeSample]
  var partialDecodeIntervals: [PartialDecodeInterval]
  var memoryClearMs: Double?
  var memoryClearReason: String?
  var uiFlushCount: Int
  var uiFlushMs: Double
  var generatedTokenCount: Int?
  var tokensPerSecond: Double?
  var firstRowIndex: Int
}

struct MemorySnapshotReport: Codable {
  var timestamp: String?
  var memoryScopeID: String
  var memoryPhase: String
  var baselineMemoryPhase: String?
  var turnID: String?
  var generationID: String?
  var toolLoopIteration: Int?
  var interactionMode: String?
  var modelLoadOutcome: String?
  var runtimeStreamOutcome: String?
  var memoryClearReason: String?
  var durationMs: Double
  var activeMemoryBytes: Int
  var cacheMemoryBytes: Int
  var peakMemoryBytes: Int
  var activeMemoryDeltaBytes: Int?
  var cacheMemoryDeltaBytes: Int?
  var peakMemoryDeltaBytes: Int?
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
  var generations: [GenerationReport]
  var memorySnapshots: [MemorySnapshotReport]
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

func debugDirectories() -> [URL] {
  let homeDirectory = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
  return [
    homeDirectory
      .appending(path: "Library/Application Support/Sumika/debug", directoryHint: .isDirectory),
    homeDirectory
      .appending(
        path: "Library/Containers/chat.sumika/Data/Library/Application Support/Sumika/debug",
        directoryHint: .isDirectory
      ),
  ]
}

func defaultTraceURL() -> URL {
  let fileManager = FileManager.default
  var candidates = debugDirectories().map {
    $0.appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
  }

  for directory in debugDirectories() {
    let traceDirectory = directory.appending(path: "traces", directoryHint: .isDirectory)
    let runTraces =
      (try? fileManager.contentsOfDirectory(
        at: traceDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    candidates.append(
      contentsOf: runTraces.filter {
        $0.lastPathComponent.hasSuffix("-mlx-trace.jsonl")
      })
  }

  let existingCandidates = candidates.filter {
    fileManager.fileExists(atPath: $0.path(percentEncoded: false))
  }
  return existingCandidates.max { left, right in
    let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    return (leftDate ?? .distantPast) < (rightDate ?? .distantPast)
  } ?? candidates[0]
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

func memorySnapshotReport(_ object: [String: Any]) -> MemorySnapshotReport? {
  guard
    value(object, "kind", as: String.self) == "turn_trace",
    value(object, "phase", as: String.self) == "runtime_memory",
    let memoryScopeID = value(object, "memoryScopeID", as: String.self),
    let memoryPhase = value(object, "memoryPhase", as: String.self),
    let durationMs = doubleValue(object, "durationMs"),
    let activeMemoryBytes = intValue(object, "activeMemoryBytes"),
    let cacheMemoryBytes = intValue(object, "cacheMemoryBytes"),
    let peakMemoryBytes = intValue(object, "peakMemoryBytes")
  else {
    return nil
  }

  return MemorySnapshotReport(
    timestamp: value(object, "timestamp", as: String.self),
    memoryScopeID: memoryScopeID,
    memoryPhase: memoryPhase,
    baselineMemoryPhase: value(object, "baselineMemoryPhase", as: String.self),
    turnID: value(object, "turnID", as: String.self),
    generationID: value(object, "generationID", as: String.self),
    toolLoopIteration: intValue(object, "toolLoopIteration"),
    interactionMode: value(object, "interactionMode", as: String.self),
    modelLoadOutcome: value(object, "modelLoadOutcome", as: String.self),
    runtimeStreamOutcome: value(object, "runtimeStreamOutcome", as: String.self),
    memoryClearReason: value(object, "memoryClearReason", as: String.self),
    durationMs: durationMs,
    activeMemoryBytes: activeMemoryBytes,
    cacheMemoryBytes: cacheMemoryBytes,
    peakMemoryBytes: peakMemoryBytes,
    activeMemoryDeltaBytes: intValue(object, "activeMemoryDeltaBytes"),
    cacheMemoryDeltaBytes: intValue(object, "cacheMemoryDeltaBytes"),
    peakMemoryDeltaBytes: intValue(object, "peakMemoryDeltaBytes")
  )
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
    partialDecodeSamples: [],
    partialDecodeIntervals: [],
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

func traceRuntimeState(_ object: [String: Any]) -> TraceRuntimeState? {
  let state = TraceRuntimeState(
    applicationActivation: value(object, "applicationActivation", as: String.self),
    applicationVisibility: value(object, "applicationVisibility", as: String.self),
    applicationOcclusion: value(object, "applicationOcclusion", as: String.self),
    mainWindowVisibility: value(object, "mainWindowVisibility", as: String.self),
    generationActivityRequest: value(object, "generationActivityRequest", as: String.self)
  )
  guard state != TraceRuntimeState() else {
    return nil
  }
  return state
}

func partialDecodeIntervals(
  for samples: [PartialDecodeSample]
) -> [PartialDecodeInterval] {
  zip(samples, samples.dropFirst()).compactMap { start, end in
    let durationMs = end.durationMs - start.durationMs
    let deltaTokenCount = end.generatedTokenCount - start.generatedTokenCount
    guard durationMs > 0, deltaTokenCount >= 0 else {
      return nil
    }
    let hasMatchingEndpointState = start.runtimeState == end.runtimeState
    return PartialDecodeInterval(
      startTimestamp: start.timestamp,
      endTimestamp: end.timestamp,
      startDurationMs: start.durationMs,
      endDurationMs: end.durationMs,
      deltaTokenCount: deltaTokenCount,
      durationMs: durationMs,
      tokensPerSecond: hasMatchingEndpointState
        ? Double(deltaTokenCount) / durationMs * 1000 : nil,
      startState: start.runtimeState,
      endState: end.runtimeState,
      hasMatchingEndpointState: hasMatchingEndpointState
    )
  }
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
    "| # | Mode | Iter | Cache | Reason | MLX decision | MLX mismatch | Memory clear | TTFT ms | Prefill ms | Prompt tokens | Full tokens | Reused tokens | Cache % | Decode ms | tok/s | Prompt bytes | Outcome | Error |",
    "|---:|---|---:|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|",
  ]

  for (index, generation) in report.generations.enumerated() {
    let row: [String] = [
      "\(index + 1)",
      generation.interactionMode ?? "-",
      generation.toolLoopIteration.map(String.init) ?? "-",
      generation.cacheMode ?? "-",
      generation.cacheReason ?? "-",
      generation.mlxCacheDecision ?? "-",
      generation.mlxCacheMismatchReason ?? "-",
      generation.memoryClearReason ?? "-",
      formatted(generation.ttftMs),
      formatted(generation.prefillMs),
      generation.promptTokens.map(String.init) ?? "-",
      generation.fullPromptTokens.map(String.init) ?? "-",
      generation.reusedPromptTokens.map(String.init) ?? "-",
      generation.cacheEfficiency.map { String(format: "%.1f", $0 * 100) } ?? "-",
      formatted(generation.decodeMs),
      formatted(generation.tokensPerSecond),
      generation.promptBytes.map(String.init) ?? "-",
      generation.streamOutcome ?? "-",
      generation.responseError ?? "-",
    ]
    lines.append(row.joined(separator: " | ").wrappedTableRow())
  }

  appendUIFlushes(to: &lines, generations: report.generations)
  appendToolLoopTTFTComparison(to: &lines, generations: report.generations)
  appendDecodeStateIntervals(to: &lines, generations: report.generations)
  appendMemorySnapshots(to: &lines, snapshots: report.memorySnapshots)

  lines.append("")
  return lines.joined(separator: "\n")
}

func appendUIFlushes(
  to lines: inout [String],
  generations: [GenerationReport]
) {
  guard !generations.isEmpty else {
    return
  }

  lines.append(contentsOf: [
    "",
    "## UI Flushes",
    "",
    "Only visible Core `uiFlush` events are included; thinking flushes remain Debug signposts.",
    "",
    "| Generation | Decode ms | Visible flushes | Flushes / decode s | Total ms | Average ms |",
    "|---|---:|---:|---:|---:|---:|",
  ])

  for generation in generations {
    let flushesPerDecodeSecond = generation.decodeMs.flatMap { decodeMs in
      decodeMs > 0 ? Double(generation.uiFlushCount) / decodeMs * 1_000 : nil
    }
    let averageMs =
      generation.uiFlushCount > 0
      ? generation.uiFlushMs / Double(generation.uiFlushCount)
      : nil
    lines.append(
      [
        String(generation.generationID.prefix(8)),
        formatted(generation.decodeMs),
        String(generation.uiFlushCount),
        formatted(flushesPerDecodeSecond),
        formatted(generation.uiFlushMs),
        formatted(averageMs),
      ].joined(separator: " | ").wrappedTableRow()
    )
  }
}

func appendDecodeStateIntervals(
  to lines: inout [String],
  generations: [GenerationReport]
) {
  let intervals = generations.flatMap { generation in
    generation.partialDecodeIntervals.map { (generation.generationID, $0) }
  }
  guard !intervals.isEmpty else {
    return
  }

  lines.append(contentsOf: [
    "",
    "## Decode State Intervals",
    "",
    "Rates use delta estimated tokens divided by delta elapsed time. Intervals with different endpoint states do not receive a rate.",
    "",
    "| Generation | End timestamp | Activation | App visibility | App occlusion | Main window | Activity request | Delta tokens | Delta ms | tok/s | State |",
    "|---|---|---|---|---|---|---|---:|---:|---:|---|",
  ])

  for (generationID, interval) in intervals {
    lines.append(
      [
        String(generationID.prefix(8)),
        interval.endTimestamp ?? "-",
        stateTransition(
          from: interval.startState,
          to: interval.endState,
          keyPath: \.applicationActivation
        ),
        stateTransition(
          from: interval.startState,
          to: interval.endState,
          keyPath: \.applicationVisibility
        ),
        stateTransition(
          from: interval.startState,
          to: interval.endState,
          keyPath: \.applicationOcclusion
        ),
        stateTransition(
          from: interval.startState,
          to: interval.endState,
          keyPath: \.mainWindowVisibility
        ),
        stateTransition(
          from: interval.startState,
          to: interval.endState,
          keyPath: \.generationActivityRequest
        ),
        String(interval.deltaTokenCount),
        formatted(interval.durationMs),
        formatted(interval.tokensPerSecond),
        interval.hasMatchingEndpointState ? "matching" : "mixed",
      ].joined(separator: " | ").wrappedTableRow()
    )
  }
}

func stateTransition(
  from start: TraceRuntimeState?,
  to end: TraceRuntimeState?,
  keyPath: KeyPath<TraceRuntimeState, String?>
) -> String {
  let startValue = start?[keyPath: keyPath] ?? "-"
  let endValue = end?[keyPath: keyPath] ?? "-"
  return startValue == endValue ? startValue : "\(startValue)->\(endValue)"
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

func appendMemorySnapshots(
  to lines: inout [String],
  snapshots: [MemorySnapshotReport]
) {
  guard !snapshots.isEmpty else {
    return
  }

  lines.append(contentsOf: [
    "",
    "## MLX Memory Snapshots",
    "",
    "`Global peak` is MLX's process-global high-water mark; its delta is the increase in that global counter.",
    "",
    "| Phase | Scope | Generation | Outcome / reason | Active MiB | Delta active MiB | Cache MiB | Delta cache MiB | Global peak MiB | Delta peak MiB |",
    "|---|---|---|---|---:|---:|---:|---:|---:|---:|",
  ])

  for snapshot in snapshots {
    let outcomeAndReason = [
      snapshot.modelLoadOutcome.map { "model=\($0)" },
      snapshot.runtimeStreamOutcome.map { "stream=\($0)" },
      snapshot.memoryClearReason.map { "clear=\($0)" },
    ].compactMap { $0 }.joined(separator: ", ")
    lines.append(
      [
        snapshot.memoryPhase,
        String(snapshot.memoryScopeID.prefix(8)),
        snapshot.generationID.map { String($0.prefix(8)) } ?? "run-wide",
        outcomeAndReason.isEmpty ? "-" : outcomeAndReason,
        formattedMemoryMiB(snapshot.activeMemoryBytes),
        formattedMemoryDeltaMiB(snapshot.activeMemoryDeltaBytes),
        formattedMemoryMiB(snapshot.cacheMemoryBytes),
        formattedMemoryDeltaMiB(snapshot.cacheMemoryDeltaBytes),
        formattedMemoryMiB(snapshot.peakMemoryBytes),
        formattedMemoryDeltaMiB(snapshot.peakMemoryDeltaBytes),
      ].joined(separator: " | ").wrappedTableRow()
    )
  }
}

func formattedMemoryMiB(_ bytes: Int) -> String {
  String(format: "%.2f", Double(bytes) / 1_048_576)
}

func formattedMemoryDeltaMiB(_ bytes: Int?) -> String {
  guard let bytes else {
    return "-"
  }
  return String(format: "%+.2f", Double(bytes) / 1_048_576)
}

func formatted(_ value: Double?) -> String {
  guard let value else {
    return "-"
  }
  return String(format: "%.1f", value)
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
var memorySnapshots: [MemorySnapshotReport] = []

for (rowIndex, row) in rows.enumerated() {
  guard
    let data = String(row).data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let kind = value(object, "kind", as: String.self)
  else {
    continue
  }

  if let memorySnapshot = memorySnapshotReport(object) {
    memorySnapshots.append(memorySnapshot)
    continue
  }

  let id: String?
  switch kind {
  case "turn_trace":
    id = value(object, "generationID", as: String.self)
  case "mlx_request", "mlx_response":
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
  case "mlx_request":
    report.requestSeen = true
    report.contextTokenLimit = report.contextTokenLimit ?? intValue(object, "contextTokenLimit")
  case "mlx_response":
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
      report.streamStartState = traceRuntimeState(object)
    case "runtime_stream_end":
      report.streamEndMs = doubleValue(object, "durationMs")
      report.streamEndState = traceRuntimeState(object)
      report.streamOutcome = value(object, "runtimeStreamOutcome", as: String.self)
      report.generatedTokenCount =
        intValue(object, "generatedTokenCount") ?? report.generatedTokenCount
      report.tokensPerSecond =
        doubleValue(object, "tokensPerSecond") ?? report.tokensPerSecond
    case "runtime_ttft":
      report.ttftMs = doubleValue(object, "ttftMs") ?? doubleValue(object, "durationMs")
    case "runtime_prefill":
      report.prefillMs = doubleValue(object, "durationMs")
      report.promptTokens = intValue(object, "promptTokens")
      report.mlxCacheDecision = value(object, "mlxCacheDecision", as: String.self)
      report.mlxCacheMismatchReason =
        value(object, "mlxCacheMismatchReason", as: String.self)
      report.fullPromptTokens = intValue(object, "fullPromptTokens")
      report.expectedCachedTokens = intValue(object, "expectedCachedTokens")
      report.expectedSuffixTokens = intValue(object, "expectedSuffixTokens")
      report.reusedPromptTokens = intValue(object, "reusedPromptTokens")
      report.cacheEfficiency = doubleValue(object, "cacheEfficiency")
      report.inputMaskPresent = boolValue(object, "inputMaskPresent")
      report.preparedMediaPresent = boolValue(object, "preparedMediaPresent")
      report.newMediaPresent = boolValue(object, "newMediaPresent")
      report.cacheTrimmable = boolValue(object, "cacheTrimmable")
      report.cacheTypes = value(object, "cacheTypes", as: [String].self)
    case "runtime_decode":
      report.decodeMs = doubleValue(object, "durationMs")
      report.tokensPerSecond = doubleValue(object, "tokensPerSecond") ?? report.tokensPerSecond
    case "runtime_partial_decode":
      if let durationMs = doubleValue(object, "durationMs"),
        let generatedTokenCount = intValue(object, "generatedTokenCount")
      {
        report.partialDecodeSamples.append(
          PartialDecodeSample(
            timestamp: value(object, "timestamp", as: String.self),
            durationMs: durationMs,
            generatedTokenCount: generatedTokenCount,
            generatedTokenCountIsEstimate:
              boolValue(object, "generatedTokenCountIsEstimate") ?? true,
            runtimeState: traceRuntimeState(object)
          )
        )
      }
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

var generations = generationOrder.compactMap { generationID -> GenerationReport? in
  guard var report = reportsByGenerationID[generationID] else {
    return nil
  }
  report.partialDecodeIntervals = partialDecodeIntervals(for: report.partialDecodeSamples)
  return report
}
if let limit, generations.count > limit {
  generations = Array(generations.suffix(limit))
}
let retainedGenerationIDs = Set(generations.map(\.generationID))
memorySnapshots = memorySnapshots.filter { snapshot in
  guard let generationID = snapshot.generationID else {
    return true
  }
  return retainedGenerationIDs.contains(generationID)
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
  generations: generations,
  memorySnapshots: memorySnapshots
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
