#!/usr/bin/env swift
import Foundation

private let supportedSchemaVersion = 3

private let rootKeys: Set<String> = [
  "cases", "crossScenarioGates", "environment", "generatedAt", "schemaVersion", "settings",
]

private let environmentKeys: Set<String> = [
  "chip", "compileCondition", "configuration", "enableTestability", "gitBranch", "gitCommit",
  "gitDirty", "macModel", "optimization", "osBuild", "osVersion", "physicalMemoryBytes",
  "processorCount", "processIsolation", "protocolFingerprint", "sourceFingerprint",
  "swiftVersion", "testHostDiagnostics", "xcodeVersion",
]

private let settingsKeys: Set<String> = [
  "absoluteP95BudgetMs", "absoluteP99BudgetMs", "activeTailAdditiveBudgetMs",
  "activeTailRatioBudget", "deltaCharacters", "fixtureVersion", "historyNoiseBudgetMs",
  "historyRatioBudget", "percentileMethod", "sampleIterations", "streamSemantics",
  "trialsPerCase", "viewportHeight", "viewportWidth", "warmupIterations",
]

private let caseKeys: Set<String> = [
  "cacheAfterMeasurements", "cacheAfterStructuralSample", "cacheBefore", "coldApplyMs",
  "cpuTimeMs", "cpuTimePerIterationMs", "cpuToMeasuredWallRatio", "deltaCharacters", "family",
  "finalTailCharacters", "gates", "id", "initialTailCharacters", "measuredIterations",
  "measuredTailCharactersEnd", "measuredTailCharactersStart", "memoryAfterColdApply",
  "memoryAfterMeasurements", "memoryBeforeFixture", "memoryBeforeHarness",
  "memoryBeforeMeasurements", "notes", "samples", "stableRows", "structuralSampleMs", "tailKind",
  "timings", "viewportHeight", "viewportWidth", "warmupIterations", "work",
]

private let sampleKeys: Set<String> = [
  "activeTailCharacters", "appKitUpdateMs", "heightAndLayoutMs", "iteration", "operation",
  "rendererMs", "rowProjectionMs", "totalMs", "trial", "viewportWidth",
]

private let memorySnapshotKeys: Set<String> = [
  "peakResidentBytes", "physicalFootprintBytes", "residentBytes",
]

private let timingKeys: Set<String> = [
  "appKitUpdate", "heightAndLayout", "renderer", "rowProjection", "total",
]

private let distributionKeys: Set<String> = [
  "count", "maxMs", "meanMs", "p50Ms", "p90Ms", "p95Ms", "p99Ms",
]

private let workKeys: Set<String> = [
  "activeCellConfigurations", "activeHeightCacheMisses", "activeMarkdownParses",
  "activeRenderedItemProjections", "activeRowWrapperProjections", "stableCellConfigurations",
  "stableHeightCacheMisses", "stableMarkdownParses", "stableRenderedItemProjections",
  "stableRowWrapperProjections", "unattributedWork",
]

private let cacheKeys: Set<String> = [
  "assistantBlocks", "heights", "highlightDescriptors", "highlightVersions", "highlightedCode",
  "highlightsInFlight", "markdown", "renderedItems", "streamingBlocks", "thumbnailFailures",
  "thumbnails", "thumbnailsInFlight",
]

private let gateKeys: Set<String> = ["actual", "expected", "id", "passed"]

private enum ComparisonError: LocalizedError {
  case usage
  case unreadableReport(label: String, path: String, underlying: Error)
  case invalidReport(label: String, reason: String)
  case incompatible(reason: String)
  case outputAliasesInput(String)
  case writeFailed(path: String, underlying: Error)

  var errorDescription: String? {
    switch self {
    case .usage:
      return
        "usage: compare_transcript_benchmarks.swift <baseline.json> <candidate.json> <output.md>"
    case .unreadableReport(let label, let path, let underlying):
      return "Could not decode \(label) report at \(path): \(underlying.localizedDescription)"
    case .invalidReport(let label, let reason):
      return "Invalid \(label) report: \(reason)"
    case .incompatible(let reason):
      return "Incompatible benchmark reports: \(reason)"
    case .outputAliasesInput(let path):
      return "Output path must not overwrite an input report: \(path)"
    case .writeFailed(let path, let underlying):
      return "Could not write comparison to \(path): \(underlying.localizedDescription)"
    }
  }
}

private struct BenchmarkDistribution: Decodable {
  let count: Int
  let meanMs: Double
  let p50Ms: Double
  let p90Ms: Double
  let p95Ms: Double
  let p99Ms: Double
  let maxMs: Double
}

private struct PhaseDistributions: Decodable {
  let total: BenchmarkDistribution
  let renderer: BenchmarkDistribution
  let rowProjection: BenchmarkDistribution
  let appKitUpdate: BenchmarkDistribution
  let heightAndLayout: BenchmarkDistribution
}

private struct BenchmarkSample: Decodable {
  let trial: Int
  let iteration: Int
  let operation: String
  let activeTailCharacters: Int
  let viewportWidth: Int
  let totalMs: Double
  let rendererMs: Double
  let rowProjectionMs: Double
  let appKitUpdateMs: Double
  let heightAndLayoutMs: Double
}

private struct MemorySnapshot: Decodable {
  let residentBytes: UInt64
  let physicalFootprintBytes: UInt64
  let peakResidentBytes: UInt64
}

private struct BenchmarkWork: Decodable {
  let stableRenderedItemProjections: Int
  let activeRenderedItemProjections: Int
  let stableRowWrapperProjections: Int
  let activeRowWrapperProjections: Int
  let stableMarkdownParses: Int
  let activeMarkdownParses: Int
  let stableHeightCacheMisses: Int
  let activeHeightCacheMisses: Int
  let stableCellConfigurations: Int
  let activeCellConfigurations: Int
  let unattributedWork: Int
}

private struct CacheSnapshot: Decodable {
  let renderedItems: Int
  let assistantBlocks: Int
  let streamingBlocks: Int
  let heights: Int
  let markdown: Int
  let highlightedCode: Int
  let highlightDescriptors: Int
  let highlightsInFlight: Int
  let highlightVersions: Int
  let thumbnails: Int
  let thumbnailFailures: Int
  let thumbnailsInFlight: Int
}

private struct BenchmarkGate: Decodable {
  let id: String
  let passed: Bool
  let expected: String
  let actual: String
}

private struct BenchmarkCase: Decodable {
  let id: String
  let family: String
  let stableRows: Int
  let initialTailCharacters: Int
  let measuredTailCharactersStart: Int
  let measuredTailCharactersEnd: Int
  let finalTailCharacters: Int
  let tailKind: String
  let deltaCharacters: Int
  let warmupIterations: Int
  let measuredIterations: Int
  let viewportWidth: Int
  let viewportHeight: Int
  let coldApplyMs: Double
  let structuralSampleMs: Double
  let samples: [BenchmarkSample]
  let timings: PhaseDistributions
  let work: BenchmarkWork
  let cacheBefore: CacheSnapshot
  let cacheAfterStructuralSample: CacheSnapshot
  let cacheAfterMeasurements: CacheSnapshot
  let memoryBeforeFixture: MemorySnapshot
  let memoryBeforeHarness: MemorySnapshot
  let memoryAfterColdApply: MemorySnapshot
  let memoryBeforeMeasurements: MemorySnapshot
  let memoryAfterMeasurements: MemorySnapshot
  let cpuTimeMs: Double
  let cpuTimePerIterationMs: Double
  let cpuToMeasuredWallRatio: Double
  let gates: [BenchmarkGate]
  let notes: [String]
}

private struct BenchmarkEnvironment: Decodable {
  let gitCommit: String
  let gitBranch: String
  let sourceFingerprint: String
  let gitDirty: Bool
  let protocolFingerprint: String
  let configuration: String
  let optimization: String
  let compileCondition: String
  let enableTestability: Bool
  let testHostDiagnostics: String
  let processIsolation: String
  let macModel: String
  let chip: String
  let physicalMemoryBytes: UInt64
  let processorCount: Int
  let osVersion: String
  let osBuild: String
  let xcodeVersion: String
  let swiftVersion: String
}

private struct BenchmarkSettings: Decodable, Equatable {
  let fixtureVersion: Int
  let trialsPerCase: Int
  let percentileMethod: String
  let streamSemantics: String
  let sampleIterations: Int
  let warmupIterations: Int
  let deltaCharacters: Int
  let viewportWidth: Int
  let viewportHeight: Int
  let absoluteP95BudgetMs: Double
  let absoluteP99BudgetMs: Double
  let historyRatioBudget: Double
  let historyNoiseBudgetMs: Double
  let activeTailRatioBudget: Double
  let activeTailAdditiveBudgetMs: Double
}

private struct BenchmarkReport: Decodable {
  let schemaVersion: Int
  let generatedAt: String
  let environment: BenchmarkEnvironment
  let settings: BenchmarkSettings
  let cases: [BenchmarkCase]
  let crossScenarioGates: [BenchmarkGate]
}

private struct CompatibleReports {
  let baseline: BenchmarkReport
  let candidate: BenchmarkReport
  let baselineCases: [String: BenchmarkCase]
  let candidateCases: [String: BenchmarkCase]
}

private func jsonObject(_ value: Any?, path: String, label: String) throws -> [String: Any] {
  guard let object = value as? [String: Any] else {
    throw ComparisonError.invalidReport(label: label, reason: "\(path) must be an object")
  }
  return object
}

private func jsonArray(_ value: Any?, path: String, label: String) throws -> [Any] {
  guard let array = value as? [Any] else {
    throw ComparisonError.invalidReport(label: label, reason: "\(path) must be an array")
  }
  return array
}

private func requireExactKeys(
  _ object: [String: Any],
  expected: Set<String>,
  path: String,
  label: String
) throws {
  let actual = Set(object.keys)
  guard actual == expected else {
    let missing = expected.subtracting(actual).sorted()
    let unexpected = actual.subtracting(expected).sorted()
    var details: [String] = []
    if !missing.isEmpty {
      details.append("missing [\(missing.joined(separator: ", "))]")
    }
    if !unexpected.isEmpty {
      details.append("unexpected [\(unexpected.joined(separator: ", "))]")
    }
    throw ComparisonError.invalidReport(
      label: label,
      reason: "\(path) has invalid keys: \(details.joined(separator: "; "))"
    )
  }
}

private func validateGateObjects(_ value: Any?, path: String, label: String) throws {
  for (index, value) in try jsonArray(value, path: path, label: label).enumerated() {
    let gate = try jsonObject(value, path: "\(path)[\(index)]", label: label)
    try requireExactKeys(gate, expected: gateKeys, path: "\(path)[\(index)]", label: label)
  }
}

private func validateExactSchema(_ value: Any, label: String) throws {
  let root = try jsonObject(value, path: "root", label: label)
  try requireExactKeys(root, expected: rootKeys, path: "root", label: label)
  guard let schemaVersion = root["schemaVersion"] as? Int else {
    throw ComparisonError.invalidReport(label: label, reason: "schemaVersion must be an integer")
  }
  guard schemaVersion == supportedSchemaVersion else {
    throw ComparisonError.invalidReport(
      label: label,
      reason: "unsupported schemaVersion \(schemaVersion); expected \(supportedSchemaVersion)"
    )
  }

  let environment = try jsonObject(root["environment"], path: "environment", label: label)
  try requireExactKeys(
    environment,
    expected: environmentKeys,
    path: "environment",
    label: label
  )
  let settings = try jsonObject(root["settings"], path: "settings", label: label)
  try requireExactKeys(settings, expected: settingsKeys, path: "settings", label: label)
  try validateGateObjects(root["crossScenarioGates"], path: "crossScenarioGates", label: label)

  for (caseIndex, value) in try jsonArray(root["cases"], path: "cases", label: label).enumerated() {
    let path = "cases[\(caseIndex)]"
    let benchmarkCase = try jsonObject(value, path: path, label: label)
    try requireExactKeys(benchmarkCase, expected: caseKeys, path: path, label: label)

    for (sampleIndex, value) in try jsonArray(
      benchmarkCase["samples"],
      path: "\(path).samples",
      label: label
    ).enumerated() {
      let samplePath = "\(path).samples[\(sampleIndex)]"
      let sample = try jsonObject(value, path: samplePath, label: label)
      try requireExactKeys(sample, expected: sampleKeys, path: samplePath, label: label)
    }

    let timings = try jsonObject(benchmarkCase["timings"], path: "\(path).timings", label: label)
    try requireExactKeys(timings, expected: timingKeys, path: "\(path).timings", label: label)
    for key in timingKeys {
      let distributionPath = "\(path).timings.\(key)"
      let distribution = try jsonObject(timings[key], path: distributionPath, label: label)
      try requireExactKeys(
        distribution,
        expected: distributionKeys,
        path: distributionPath,
        label: label
      )
    }

    let work = try jsonObject(benchmarkCase["work"], path: "\(path).work", label: label)
    try requireExactKeys(work, expected: workKeys, path: "\(path).work", label: label)
    for key in ["cacheBefore", "cacheAfterStructuralSample", "cacheAfterMeasurements"] {
      let cachePath = "\(path).\(key)"
      let cache = try jsonObject(benchmarkCase[key], path: cachePath, label: label)
      try requireExactKeys(cache, expected: cacheKeys, path: cachePath, label: label)
    }
    for key in [
      "memoryBeforeFixture",
      "memoryBeforeHarness",
      "memoryAfterColdApply",
      "memoryBeforeMeasurements",
      "memoryAfterMeasurements",
    ] {
      let snapshotPath = "\(path).\(key)"
      let snapshot = try jsonObject(benchmarkCase[key], path: snapshotPath, label: label)
      try requireExactKeys(
        snapshot,
        expected: memorySnapshotKeys,
        path: snapshotPath,
        label: label
      )
    }
    try validateGateObjects(benchmarkCase["gates"], path: "\(path).gates", label: label)
  }
}

private func loadReport(label: String, from url: URL) throws -> BenchmarkReport {
  do {
    let data = try Data(contentsOf: url)
    let rootObject = try JSONSerialization.jsonObject(with: data)
    try validateExactSchema(rootObject, label: label)
    let decoder = JSONDecoder()
    let report = try decoder.decode(BenchmarkReport.self, from: data)
    try validateStructure(report, label: label)
    return report
  } catch let error as ComparisonError {
    throw error
  } catch {
    throw ComparisonError.unreadableReport(
      label: label,
      path: url.path(percentEncoded: false),
      underlying: error
    )
  }
}

private func validateStructure(_ report: BenchmarkReport, label: String) throws {
  guard report.schemaVersion == supportedSchemaVersion else {
    throw ComparisonError.invalidReport(
      label: label,
      reason:
        "unsupported schemaVersion \(report.schemaVersion); expected \(supportedSchemaVersion)"
    )
  }
  guard !report.generatedAt.isEmpty else {
    throw ComparisonError.invalidReport(label: label, reason: "generatedAt must not be empty")
  }
  guard !report.environment.protocolFingerprint.isEmpty else {
    throw ComparisonError.invalidReport(
      label: label,
      reason: "environment.protocolFingerprint must not be empty"
    )
  }
  guard report.settings.trialsPerCase > 0,
    report.settings.sampleIterations > 0,
    report.settings.warmupIterations >= 0,
    !report.settings.percentileMethod.isEmpty,
    !report.settings.streamSemantics.isEmpty
  else {
    throw ComparisonError.invalidReport(label: label, reason: "invalid benchmark settings")
  }
  guard !report.cases.isEmpty else {
    throw ComparisonError.invalidReport(label: label, reason: "cases must not be empty")
  }

  var caseIDs = Set<String>()
  for benchmarkCase in report.cases {
    guard !benchmarkCase.id.isEmpty else {
      throw ComparisonError.invalidReport(label: label, reason: "case id must not be empty")
    }
    guard caseIDs.insert(benchmarkCase.id).inserted else {
      throw ComparisonError.invalidReport(
        label: label,
        reason: "duplicate case id \(benchmarkCase.id)"
      )
    }
    guard benchmarkCase.measuredIterations == benchmarkCase.samples.count else {
      throw ComparisonError.invalidReport(
        label: label,
        reason:
          "case \(benchmarkCase.id) has measuredIterations=\(benchmarkCase.measuredIterations) but \(benchmarkCase.samples.count) samples"
      )
    }
    for (index, sample) in benchmarkCase.samples.enumerated() {
      let durations = [
        sample.totalMs,
        sample.rendererMs,
        sample.rowProjectionMs,
        sample.appKitUpdateMs,
        sample.heightAndLayoutMs,
      ]
      guard !sample.operation.isEmpty,
        sample.trial >= 0,
        sample.iteration >= 0,
        sample.activeTailCharacters >= 0,
        sample.viewportWidth > 0,
        durations.allSatisfy({ $0.isFinite && $0 >= 0 })
      else {
        throw ComparisonError.invalidReport(
          label: label,
          reason: "case \(benchmarkCase.id).samples[\(index)] is invalid"
        )
      }
    }
    try validateDistribution(
      benchmarkCase.timings.total,
      expectedCount: benchmarkCase.measuredIterations,
      path: "case \(benchmarkCase.id).timings.total",
      label: label
    )
    try validateDistribution(
      benchmarkCase.timings.renderer,
      expectedCount: benchmarkCase.measuredIterations,
      path: "case \(benchmarkCase.id).timings.renderer",
      label: label
    )
    try validateDistribution(
      benchmarkCase.timings.rowProjection,
      expectedCount: benchmarkCase.measuredIterations,
      path: "case \(benchmarkCase.id).timings.rowProjection",
      label: label
    )
    try validateDistribution(
      benchmarkCase.timings.appKitUpdate,
      expectedCount: benchmarkCase.measuredIterations,
      path: "case \(benchmarkCase.id).timings.appKitUpdate",
      label: label
    )
    try validateDistribution(
      benchmarkCase.timings.heightAndLayout,
      expectedCount: benchmarkCase.measuredIterations,
      path: "case \(benchmarkCase.id).timings.heightAndLayout",
      label: label
    )
    try validateGates(benchmarkCase.gates, path: "case \(benchmarkCase.id).gates", label: label)
  }
  try validateGates(report.crossScenarioGates, path: "crossScenarioGates", label: label)
}

private func validateDistribution(
  _ distribution: BenchmarkDistribution,
  expectedCount: Int,
  path: String,
  label: String
) throws {
  let values = [
    distribution.meanMs,
    distribution.p50Ms,
    distribution.p90Ms,
    distribution.p95Ms,
    distribution.p99Ms,
    distribution.maxMs,
  ]
  guard distribution.count == expectedCount else {
    throw ComparisonError.invalidReport(
      label: label,
      reason: "\(path).count does not match measuredIterations"
    )
  }
  guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
    throw ComparisonError.invalidReport(
      label: label,
      reason: "\(path) contains a negative or non-finite duration"
    )
  }
  guard distribution.p50Ms <= distribution.p90Ms,
    distribution.p90Ms <= distribution.p95Ms,
    distribution.p95Ms <= distribution.p99Ms,
    distribution.p99Ms <= distribution.maxMs
  else {
    throw ComparisonError.invalidReport(label: label, reason: "\(path) percentiles are unordered")
  }
}

private func validateGates(_ gates: [BenchmarkGate], path: String, label: String) throws {
  var gateIDs = Set<String>()
  for gate in gates {
    guard !gate.id.isEmpty else {
      throw ComparisonError.invalidReport(label: label, reason: "\(path) contains an empty id")
    }
    guard gateIDs.insert(gate.id).inserted else {
      throw ComparisonError.invalidReport(
        label: label,
        reason: "\(path) contains duplicate id \(gate.id)"
      )
    }
  }
}

private func requireCompatibility(
  baseline: BenchmarkReport,
  candidate: BenchmarkReport
) throws -> CompatibleReports {
  guard baseline.schemaVersion == candidate.schemaVersion else {
    throw ComparisonError.incompatible(
      reason:
        "schemaVersion differs (baseline \(baseline.schemaVersion), candidate \(candidate.schemaVersion))"
    )
  }
  guard baseline.settings == candidate.settings else {
    throw ComparisonError.incompatible(reason: "settings differ")
  }

  let baselineEnvironment = baseline.environment
  let candidateEnvironment = candidate.environment
  var mismatches: [String] = []
  checkEqual(
    baselineEnvironment.protocolFingerprint,
    candidateEnvironment.protocolFingerprint,
    field: "environment.protocolFingerprint",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.configuration,
    candidateEnvironment.configuration,
    field: "environment.configuration",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.optimization,
    candidateEnvironment.optimization,
    field: "environment.optimization",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.compileCondition,
    candidateEnvironment.compileCondition,
    field: "environment.compileCondition",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.enableTestability,
    candidateEnvironment.enableTestability,
    field: "environment.enableTestability",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.testHostDiagnostics,
    candidateEnvironment.testHostDiagnostics,
    field: "environment.testHostDiagnostics",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.processIsolation,
    candidateEnvironment.processIsolation,
    field: "environment.processIsolation",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.macModel,
    candidateEnvironment.macModel,
    field: "environment.macModel",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.chip,
    candidateEnvironment.chip,
    field: "environment.chip",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.physicalMemoryBytes,
    candidateEnvironment.physicalMemoryBytes,
    field: "environment.physicalMemoryBytes",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.processorCount,
    candidateEnvironment.processorCount,
    field: "environment.processorCount",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.osVersion,
    candidateEnvironment.osVersion,
    field: "environment.osVersion",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.osBuild,
    candidateEnvironment.osBuild,
    field: "environment.osBuild",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.xcodeVersion,
    candidateEnvironment.xcodeVersion,
    field: "environment.xcodeVersion",
    mismatches: &mismatches
  )
  checkEqual(
    baselineEnvironment.swiftVersion,
    candidateEnvironment.swiftVersion,
    field: "environment.swiftVersion",
    mismatches: &mismatches
  )
  guard mismatches.isEmpty else {
    throw ComparisonError.incompatible(reason: mismatches.joined(separator: ", "))
  }

  let baselineCases = Dictionary(uniqueKeysWithValues: baseline.cases.map { ($0.id, $0) })
  let candidateCases = Dictionary(uniqueKeysWithValues: candidate.cases.map { ($0.id, $0) })
  let baselineIDs = Set(baselineCases.keys)
  let candidateIDs = Set(candidateCases.keys)
  guard baselineIDs == candidateIDs else {
    let missing = baselineIDs.subtracting(candidateIDs).sorted().joined(separator: ", ")
    let added = candidateIDs.subtracting(baselineIDs).sorted().joined(separator: ", ")
    throw ComparisonError.incompatible(
      reason: "case id set differs (missing: [\(missing)]; added: [\(added)])"
    )
  }

  return CompatibleReports(
    baseline: baseline,
    candidate: candidate,
    baselineCases: baselineCases,
    candidateCases: candidateCases
  )
}

private func checkEqual<Value: Equatable>(
  _ baseline: Value,
  _ candidate: Value,
  field: String,
  mismatches: inout [String]
) {
  if baseline != candidate {
    mismatches.append("\(field) differs")
  }
}

private func makeMarkdown(
  reports: CompatibleReports,
  baselineURL: URL,
  candidateURL: URL
) -> String {
  let baseline = reports.baseline
  let candidate = reports.candidate
  let baselineEnvironment = baseline.environment
  let candidateEnvironment = candidate.environment
  var lines = [
    "# Transcript Benchmark Comparison",
    "",
    "The reports use the same benchmark protocol. Timing deltas are descriptive; this comparison does not apply an additional regression threshold.",
    "",
    "## Provenance",
    "",
    "| Field | Baseline | Candidate |",
    "|---|---|---|",
    tableRow(
      "Input", baselineURL.path(percentEncoded: false), candidateURL.path(percentEncoded: false)),
    tableRow("Generated", baseline.generatedAt, candidate.generatedAt),
    tableRow("Schema version", "\(baseline.schemaVersion)", "\(candidate.schemaVersion)"),
    tableRow("Git commit", baselineEnvironment.gitCommit, candidateEnvironment.gitCommit),
    tableRow("Git branch", baselineEnvironment.gitBranch, candidateEnvironment.gitBranch),
    tableRow(
      "Git dirty", yesNo(baselineEnvironment.gitDirty), yesNo(candidateEnvironment.gitDirty)),
    tableRow(
      "Source fingerprint",
      baselineEnvironment.sourceFingerprint,
      candidateEnvironment.sourceFingerprint
    ),
    tableRow(
      "Protocol fingerprint",
      baselineEnvironment.protocolFingerprint,
      candidateEnvironment.protocolFingerprint
    ),
    tableRow(
      "Protocol settings",
      settingsDescription(baseline.settings),
      settingsDescription(candidate.settings)
    ),
    tableRow(
      "Build",
      "\(baselineEnvironment.configuration); \(baselineEnvironment.optimization)",
      "\(candidateEnvironment.configuration); \(candidateEnvironment.optimization)"
    ),
    tableRow(
      "Testability",
      yesNo(baselineEnvironment.enableTestability),
      yesNo(candidateEnvironment.enableTestability)
    ),
    tableRow(
      "Diagnostics",
      "\(baselineEnvironment.compileCondition); host: \(baselineEnvironment.testHostDiagnostics)",
      "\(candidateEnvironment.compileCondition); host: \(candidateEnvironment.testHostDiagnostics)"
    ),
    tableRow(
      "Process isolation",
      baselineEnvironment.processIsolation,
      candidateEnvironment.processIsolation
    ),
    tableRow(
      "Machine",
      machineDescription(baselineEnvironment),
      machineDescription(candidateEnvironment)
    ),
    tableRow(
      "OS",
      "macOS \(baselineEnvironment.osVersion) (\(baselineEnvironment.osBuild))",
      "macOS \(candidateEnvironment.osVersion) (\(candidateEnvironment.osBuild))"
    ),
    tableRow(
      "Toolchain",
      "\(baselineEnvironment.xcodeVersion); \(baselineEnvironment.swiftVersion)",
      "\(candidateEnvironment.xcodeVersion); \(candidateEnvironment.swiftVersion)"
    ),
    "",
    "## Timing deltas",
    "",
    "Positive deltas mean the candidate took longer.",
    "",
    "| Case | Baseline p50 ms | Candidate p50 ms | Delta ms | Delta % | Baseline p95 ms | Candidate p95 ms | Delta ms | Delta % | Baseline p99 ms | Candidate p99 ms | Delta ms | Delta % |",
    "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
  ]

  for id in reports.baselineCases.keys.sorted() {
    guard let baselineCase = reports.baselineCases[id],
      let candidateCase = reports.candidateCases[id]
    else {
      continue
    }
    lines.append(
      timingRow(
        id: id,
        baseline: baselineCase.timings.total,
        candidate: candidateCase.timings.total
      )
    )
  }

  lines.append(contentsOf: [
    "",
    "## Current per-case gates",
    "",
    "These are the gates recorded by the candidate run.",
    "",
    "| Case | Gate | Status | Expected | Actual |",
    "|---|---|---|---|---|",
  ])
  for id in reports.candidateCases.keys.sorted() {
    guard let benchmarkCase = reports.candidateCases[id] else {
      continue
    }
    for gate in benchmarkCase.gates {
      lines.append(
        "| \(escaped(id)) | \(escaped(gate.id)) | \(gateStatus(gate)) | \(escaped(gate.expected)) | \(escaped(gate.actual)) |"
      )
    }
  }

  lines.append(contentsOf: [
    "",
    "## Current cross-scenario gates",
    "",
    "These are the gates recorded by the candidate run.",
    "",
    "| Gate | Status | Expected | Actual |",
    "|---|---|---|---|",
  ])
  for gate in candidate.crossScenarioGates {
    lines.append(
      "| \(escaped(gate.id)) | \(gateStatus(gate)) | \(escaped(gate.expected)) | \(escaped(gate.actual)) |"
    )
  }
  lines.append("")
  return lines.joined(separator: "\n")
}

private func timingRow(
  id: String,
  baseline: BenchmarkDistribution,
  candidate: BenchmarkDistribution
) -> String {
  let values = [
    escaped(id),
    formatted(baseline.p50Ms),
    formatted(candidate.p50Ms),
    signedMilliseconds(candidate.p50Ms - baseline.p50Ms),
    percentageDelta(baseline: baseline.p50Ms, candidate: candidate.p50Ms),
    formatted(baseline.p95Ms),
    formatted(candidate.p95Ms),
    signedMilliseconds(candidate.p95Ms - baseline.p95Ms),
    percentageDelta(baseline: baseline.p95Ms, candidate: candidate.p95Ms),
    formatted(baseline.p99Ms),
    formatted(candidate.p99Ms),
    signedMilliseconds(candidate.p99Ms - baseline.p99Ms),
    percentageDelta(baseline: baseline.p99Ms, candidate: candidate.p99Ms),
  ]
  return "| " + values.joined(separator: " | ") + " |"
}

private func tableRow(_ field: String, _ baseline: String, _ candidate: String) -> String {
  "| \(escaped(field)) | \(escaped(baseline)) | \(escaped(candidate)) |"
}

private func escaped(_ value: String) -> String {
  value
    .replacingOccurrences(of: "|", with: "\\|")
    .replacingOccurrences(of: "\r", with: " ")
    .replacingOccurrences(of: "\n", with: " ")
}

private func formatted(_ value: Double) -> String {
  String(format: "%.3f", value)
}

private func signedMilliseconds(_ value: Double) -> String {
  String(format: "%+.3f", value)
}

private func percentageDelta(baseline: Double, candidate: Double) -> String {
  guard baseline != 0 else {
    return "n/a"
  }
  return String(format: "%+.2f%%", ((candidate - baseline) / baseline) * 100)
}

private func gateStatus(_ gate: BenchmarkGate) -> String {
  gate.passed ? "PASS" : "FAIL"
}

private func yesNo(_ value: Bool) -> String {
  value ? "yes" : "no"
}

private func machineDescription(_ environment: BenchmarkEnvironment) -> String {
  let memoryGiB = Double(environment.physicalMemoryBytes) / 1_073_741_824
  return
    "\(environment.macModel); \(environment.chip); \(environment.processorCount) cores; \(String(format: "%.1f", memoryGiB)) GiB RAM"
}

private func settingsDescription(_ settings: BenchmarkSettings) -> String {
  "fixture \(settings.fixtureVersion); \(settings.trialsPerCase) trials; \(settings.sampleIterations) samples after \(settings.warmupIterations) warmups; delta \(settings.deltaCharacters); viewport \(settings.viewportWidth)x\(settings.viewportHeight); \(settings.percentileMethod); \(settings.streamSemantics)"
}

private func canonicalURL(for path: String) -> URL {
  URL(filePath: path, directoryHint: .notDirectory).standardizedFileURL
}

private func run() throws {
  guard CommandLine.arguments.count == 4 else {
    throw ComparisonError.usage
  }
  let baselineURL = canonicalURL(for: CommandLine.arguments[1])
  let candidateURL = canonicalURL(for: CommandLine.arguments[2])
  let outputURL = canonicalURL(for: CommandLine.arguments[3])
  guard outputURL != baselineURL, outputURL != candidateURL else {
    throw ComparisonError.outputAliasesInput(outputURL.path(percentEncoded: false))
  }

  let baseline = try loadReport(label: "baseline", from: baselineURL)
  let candidate = try loadReport(label: "candidate", from: candidateURL)
  let reports = try requireCompatibility(baseline: baseline, candidate: candidate)
  let markdown = makeMarkdown(
    reports: reports,
    baselineURL: baselineURL,
    candidateURL: candidateURL
  )
  do {
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(markdown.utf8).write(to: outputURL, options: .atomic)
  } catch {
    throw ComparisonError.writeFailed(
      path: outputURL.path(percentEncoded: false),
      underlying: error
    )
  }
  print("Wrote \(outputURL.path(percentEncoded: false))")
}

do {
  try run()
} catch {
  let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  if case ComparisonError.usage = error {
    exit(2)
  }
  exit(1)
}
