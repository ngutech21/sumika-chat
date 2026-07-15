#!/usr/bin/env swift
import Foundation

func usage() -> Never {
  FileHandle.standardError.write(
    Data("usage: transcript_benchmark_report.swift <input.json> <output.md>\n".utf8)
  )
  exit(2)
}

guard CommandLine.arguments.count == 3 else {
  usage()
}

let inputURL = URL(filePath: CommandLine.arguments[1], directoryHint: .notDirectory)
let outputURL = URL(filePath: CommandLine.arguments[2], directoryHint: .notDirectory)
let rootObject = try JSONSerialization.jsonObject(with: Data(contentsOf: inputURL))
guard let root = rootObject as? [String: Any] else {
  throw ReportError.invalidRoot
}

enum ReportError: Error {
  case invalidRoot
  case missingValue(String)
}

func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
  guard let result = value as? [String: Any] else {
    throw ReportError.missingValue(path)
  }
  return result
}

func dictionaries(_ value: Any?, path: String) throws -> [[String: Any]] {
  guard let result = value as? [[String: Any]] else {
    throw ReportError.missingValue(path)
  }
  return result
}

func string(_ value: Any?, fallback: String = "-") -> String {
  (value as? String) ?? fallback
}

func bool(_ value: Any?) -> Bool {
  (value as? Bool) ?? false
}

func int(_ value: Any?) -> Int {
  if let value = value as? Int {
    return value
  }
  return (value as? NSNumber)?.intValue ?? 0
}

func double(_ value: Any?) -> Double {
  (value as? NSNumber)?.doubleValue ?? 0
}

func formatted(_ value: Double) -> String {
  String(format: "%.3f", value)
}

func megabytes(_ bytes: Int64) -> String {
  String(format: "%.1f", Double(bytes) / 1_048_576)
}

func escaped(_ value: String) -> String {
  value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
}

func gateSymbol(_ passed: Bool) -> String {
  passed ? "PASS" : "FAIL"
}

func percentile(_ percentile: Double, values: [Double]) -> Double {
  let sorted = values.sorted()
  guard !sorted.isEmpty else {
    return 0
  }
  let rank = Int(ceil(percentile * Double(sorted.count))) - 1
  return sorted[max(0, min(rank, sorted.count - 1))]
}

let environment = try dictionary(root["environment"], path: "environment")
let settings = try dictionary(root["settings"], path: "settings")
let cases = try dictionaries(root["cases"], path: "cases")
let crossGates = try dictionaries(root["crossScenarioGates"], path: "crossScenarioGates")

var lines: [String] = [
  "# Transcript Performance Benchmark",
  "",
  "- Generated: \(string(root["generatedAt"]))",
  "- Schema version: \(int(root["schemaVersion"]))",
  "- Git: `\(string(environment["gitCommit"]))` on `\(string(environment["gitBranch"]))` (dirty: \(bool(environment["gitDirty"])))",
  "- Source fingerprint: `\(string(environment["sourceFingerprint"]))`",
  "- Protocol fingerprint: `\(string(environment["protocolFingerprint"]))`",
  "- Build: \(string(environment["configuration"])); \(string(environment["optimization"]))",
  "- Diagnostics: `\(string(environment["compileCondition"]))`",
  "- Test host: \(string(environment["testHostDiagnostics"]))",
  "- Isolation: \(string(environment["processIsolation"]))",
  "- Machine: \(string(environment["macModel"])); \(string(environment["chip"])); \(int(environment["processorCount"])) cores; \(megabytes(Int64(int(environment["physicalMemoryBytes"])))) MiB RAM",
  "- OS: macOS \(string(environment["osVersion"])) (\(string(environment["osBuild"])))",
  "- Toolchain: \(string(environment["xcodeVersion"])); \(string(environment["swiftVersion"]))",
  "- Raw JSON: `\(inputURL.path(percentEncoded: false))`",
  "",
  "## Protocol",
  "",
  "- Fixture version: \(int(settings["fixtureVersion"]))",
  "- Trials per case: \(int(settings["trialsPerCase"]))",
  "- Streaming trace: \(int(settings["sampleIterations"])) ordered chunks after \(int(settings["warmupIterations"])) warm-ups",
  "- Stream semantics: \(string(settings["streamSemantics"]))",
  "- Percentiles: \(string(settings["percentileMethod"]))",
  "- Streaming delta: \(int(settings["deltaCharacters"])) ASCII characters",
  "- Viewport: \(int(settings["viewportWidth"])) x \(int(settings["viewportHeight"])) points",
  "- Absolute budgets: p95 <= \(formatted(double(settings["absoluteP95BudgetMs"]))) ms; p99 < \(formatted(double(settings["absoluteP99BudgetMs"]))) ms",
  "- Timing scope: synchronous offscreen render/update/forced-height-flush microbenchmark; not display-frame latency or the real 60 ms coalescing cadence.",
  "- Statistical scope: percentiles describe one ordered trace. With 100 chunks p99 is the second-largest sample; the 19-leg resize cycle has lower quantile resolution.",
  "- Cross-scenario gates are intra-run scaling invariants, not baseline-versus-candidate regression gates.",
  "- Failed gates are observations in the baseline phase; this runner does not optimize or mutate transcript behavior.",
  "",
  "## Cross-scenario gates",
  "",
  "| Gate | Status | Expected | Actual |",
  "|---|---|---|---|",
]

for gate in crossGates {
  lines.append(
    "| \(escaped(string(gate["id"]))) | \(gateSymbol(bool(gate["passed"]))) | \(escaped(string(gate["expected"]))) | \(escaped(string(gate["actual"]))) |"
  )
}

lines.append(contentsOf: [
  "",
  "## Timing summary",
  "",
  "| Scenario | Rows | Initial tail | Measured tail range | Samples | >=16.7 ms | Cold apply ms | Total p50 ms | Total p95 ms | Total p99 ms | Max ms | Renderer p95 | Rows p95 | AppKit p95 | Height/layout p95 |",
  "|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
])

for benchmarkCase in cases {
  let samples = try dictionaries(benchmarkCase["samples"], path: "case.samples")
  let timings = try dictionary(benchmarkCase["timings"], path: "case.timings")
  let total = try dictionary(timings["total"], path: "case.timings.total")
  let renderer = try dictionary(timings["renderer"], path: "case.timings.renderer")
  let rows = try dictionary(timings["rowProjection"], path: "case.timings.rowProjection")
  let appKit = try dictionary(timings["appKitUpdate"], path: "case.timings.appKitUpdate")
  let height = try dictionary(timings["heightAndLayout"], path: "case.timings.heightAndLayout")
  lines.append(
    [
      escaped(string(benchmarkCase["id"])),
      "\(int(benchmarkCase["stableRows"]))",
      "\(int(benchmarkCase["initialTailCharacters"]))",
      "\(int(benchmarkCase["measuredTailCharactersStart"]))...\(int(benchmarkCase["measuredTailCharactersEnd"]))",
      "\(int(benchmarkCase["measuredIterations"]))",
      "\(samples.count { double($0["totalMs"]) >= 16.7 })",
      formatted(double(benchmarkCase["coldApplyMs"])),
      formatted(double(total["p50Ms"])),
      formatted(double(total["p95Ms"])),
      formatted(double(total["p99Ms"])),
      formatted(double(total["maxMs"])),
      formatted(double(renderer["p95Ms"])),
      formatted(double(rows["p95Ms"])),
      formatted(double(appKit["p95Ms"])),
      formatted(double(height["p95Ms"])),
    ].joined(separator: " | ").wrappedTableRow()
  )
}

if let resizeCase = cases.first(where: { string($0["family"]) == "resize" }) {
  let resizeSamples = try dictionaries(resizeCase["samples"], path: "resize.samples")
  lines.append(contentsOf: [
    "",
    "## Resize legs",
    "",
    "The first 760-to-720-point cold transition is the structural sample. Timed cold widths and warm revisits remain separate below; no streaming budget is applied to resize.",
    "",
    "| Leg | Widths | Samples | p50 ms | p95 ms | Max ms |",
    "|---|---|---:|---:|---:|---:|",
  ])
  for operation in ["cold-width", "warm-revisit"] {
    let matching = resizeSamples.filter { string($0["operation"]) == operation }
    let values = matching.map { double($0["totalMs"]) }
    let widths = matching.map { String(int($0["viewportWidth"])) }.joined(separator: ", ")
    lines.append(
      [
        operation,
        widths,
        "\(values.count)",
        formatted(percentile(0.50, values: values)),
        formatted(percentile(0.95, values: values)),
        formatted(values.max() ?? 0),
      ].joined(separator: " | ").wrappedTableRow()
    )
  }
}

lines.append(contentsOf: [
  "",
  "## Append-only work",
  "",
  "One structural sample runs with deterministic work counters enabled. Its duration is reported separately and is not part of the timing distribution.",
  "Active tuple notation is item/row-wrapper/Markdown/height/cell.",
  "",
  "| Scenario | Structural ms | Stable item projections | Stable row wrappers | Stable Markdown parses | Stable height misses | Stable cell configs | Active i/r/m/h/c | Unattributed | Structural gate |",
  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|",
])

for benchmarkCase in cases {
  let work = try dictionary(benchmarkCase["work"], path: "case.work")
  let gates = try dictionaries(benchmarkCase["gates"], path: "case.gates")
  let structuralGate = gates.first {
    let id = string($0["id"])
    return id == "append-only-stable-work" || id == "resize-no-semantic-recreation"
  }
  lines.append(
    [
      escaped(string(benchmarkCase["id"])),
      formatted(double(benchmarkCase["structuralSampleMs"])),
      "\(int(work["stableRenderedItemProjections"]))",
      "\(int(work["stableRowWrapperProjections"]))",
      "\(int(work["stableMarkdownParses"]))",
      "\(int(work["stableHeightCacheMisses"]))",
      "\(int(work["stableCellConfigurations"]))",
      "\(int(work["activeRenderedItemProjections"]))/\(int(work["activeRowWrapperProjections"]))/\(int(work["activeMarkdownParses"]))/\(int(work["activeHeightCacheMisses"]))/\(int(work["activeCellConfigurations"]))",
      "\(int(work["unattributedWork"]))",
      structuralGate.map { gateSymbol(bool($0["passed"])) } ?? "N/A",
    ].joined(separator: " | ").wrappedTableRow()
  )
}

lines.append(contentsOf: [
  "",
  "## Cache entry counts",
  "",
  "Append scenarios require exact steady-state entry counts. Resize intentionally creates height entries for unseen widths, so its cache policy is reported without a pass/fail gate.",
  "",
  "| Scenario | Renderer before/structural/after | Height before/structural/after | Markdown before/structural/after | Cache gate |",
  "|---|---:|---:|---:|---|",
])

for benchmarkCase in cases {
  let before = try dictionary(benchmarkCase["cacheBefore"], path: "case.cacheBefore")
  let after = try dictionary(
    benchmarkCase["cacheAfterMeasurements"],
    path: "case.cacheAfterMeasurements"
  )
  let structural = try dictionary(
    benchmarkCase["cacheAfterStructuralSample"],
    path: "case.cacheAfterStructuralSample"
  )
  let gates = try dictionaries(benchmarkCase["gates"], path: "case.gates")
  let cacheGate = gates.first { string($0["id"]) == "cache-entry-counts-bounded" }
  lines.append(
    [
      escaped(string(benchmarkCase["id"])),
      "\(int(before["renderedItems"]))/\(int(structural["renderedItems"]))/\(int(after["renderedItems"]))",
      "\(int(before["heights"]))/\(int(structural["heights"]))/\(int(after["heights"]))",
      "\(int(before["markdown"]))/\(int(structural["markdown"]))/\(int(after["markdown"]))",
      cacheGate.map { gateSymbol(bool($0["passed"])) } ?? "N/A",
    ].joined(separator: " | ").wrappedTableRow()
  )
}

lines.append(contentsOf: [
  "",
  "## Process memory and CPU",
  "",
  "Every scenario runs in a fresh process. Stage tuple: before fixture / before harness / after cold apply / before measurements / after measurements. RSS, physical footprint, and process peak remain informational rather than gates.",
  "",
  "| Scenario | RSS stages MiB | Footprint stages MiB | Final process peak MiB | Measured RSS delta MiB | CPU total ms | CPU/sample ms | CPU/wall |",
  "|---|---|---|---:|---:|---:|---:|---:|",
])

for benchmarkCase in cases {
  let memoryKeys = [
    "memoryBeforeFixture",
    "memoryBeforeHarness",
    "memoryAfterColdApply",
    "memoryBeforeMeasurements",
    "memoryAfterMeasurements",
  ]
  let memories = try memoryKeys.map {
    try dictionary(benchmarkCase[$0], path: "case.\($0)")
  }
  let rssStages = memories.map {
    megabytes(Int64(int($0["residentBytes"])))
  }.joined(separator: " / ")
  let footprintStages = memories.map {
    megabytes(Int64(int($0["physicalFootprintBytes"])))
  }.joined(separator: " / ")
  let measuredRSSDelta =
    Int64(int(memories[4]["residentBytes"])) - Int64(int(memories[3]["residentBytes"]))
  lines.append(
    [
      escaped(string(benchmarkCase["id"])),
      rssStages,
      footprintStages,
      megabytes(Int64(int(memories[4]["peakResidentBytes"]))),
      megabytes(measuredRSSDelta),
      formatted(double(benchmarkCase["cpuTimeMs"])),
      formatted(double(benchmarkCase["cpuTimePerIterationMs"])),
      formatted(double(benchmarkCase["cpuToMeasuredWallRatio"])),
    ].joined(separator: " | ").wrappedTableRow()
  )
}

lines.append(contentsOf: [
  "",
  "## Per-case gates",
  "",
  "| Scenario | Gate | Status | Expected | Actual |",
  "|---|---|---|---|---|",
])

for benchmarkCase in cases {
  for gate in try dictionaries(benchmarkCase["gates"], path: "case.gates") {
    lines.append(
      "| \(escaped(string(benchmarkCase["id"]))) | \(escaped(string(gate["id"]))) | \(gateSymbol(bool(gate["passed"]))) | \(escaped(string(gate["expected"]))) | \(escaped(string(gate["actual"]))) |"
    )
  }
}

lines.append("")
try FileManager.default.createDirectory(
  at: outputURL.deletingLastPathComponent(),
  withIntermediateDirectories: true
)
try lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
print("Wrote \(outputURL.path(percentEncoded: false))")

extension String {
  func wrappedTableRow() -> String {
    "| " + self + " |"
  }
}
