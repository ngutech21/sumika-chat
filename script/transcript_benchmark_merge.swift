#!/usr/bin/env swift
import CoreFoundation
import Darwin
import Foundation

private let supportedSchemaVersion = 3

private let expectedRootKeys: Set<String> = [
  "cases",
  "crossScenarioGates",
  "environment",
  "generatedAt",
  "schemaVersion",
  "settings",
]

private let expectedEnvironmentKeys: Set<String> = [
  "chip",
  "compileCondition",
  "configuration",
  "enableTestability",
  "gitBranch",
  "gitCommit",
  "gitDirty",
  "macModel",
  "optimization",
  "osBuild",
  "osVersion",
  "physicalMemoryBytes",
  "processorCount",
  "processIsolation",
  "protocolFingerprint",
  "sourceFingerprint",
  "swiftVersion",
  "testHostDiagnostics",
  "xcodeVersion",
]

private let expectedSettingsKeys: Set<String> = [
  "absoluteP95BudgetMs",
  "absoluteP99BudgetMs",
  "activeTailAdditiveBudgetMs",
  "activeTailRatioBudget",
  "deltaCharacters",
  "fixtureVersion",
  "historyNoiseBudgetMs",
  "historyRatioBudget",
  "percentileMethod",
  "sampleIterations",
  "streamSemantics",
  "trialsPerCase",
  "viewportHeight",
  "viewportWidth",
  "warmupIterations",
]

private let expectedCaseKeys: Set<String> = [
  "cacheAfterMeasurements",
  "cacheAfterStructuralSample",
  "cacheBefore",
  "coldApplyMs",
  "cpuTimeMs",
  "deltaCharacters",
  "family",
  "finalTailCharacters",
  "gates",
  "id",
  "initialTailCharacters",
  "measuredTailCharactersEnd",
  "measuredTailCharactersStart",
  "measuredIterations",
  "memoryAfterColdApply",
  "memoryAfterMeasurements",
  "memoryBeforeFixture",
  "memoryBeforeHarness",
  "memoryBeforeMeasurements",
  "notes",
  "samples",
  "stableRows",
  "structuralSampleMs",
  "tailKind",
  "timings",
  "cpuTimePerIterationMs",
  "cpuToMeasuredWallRatio",
  "viewportHeight",
  "viewportWidth",
  "warmupIterations",
  "work",
]

private let expectedSampleKeys: Set<String> = [
  "activeTailCharacters",
  "appKitUpdateMs",
  "heightAndLayoutMs",
  "iteration",
  "operation",
  "rendererMs",
  "rowProjectionMs",
  "totalMs",
  "trial",
  "viewportWidth",
]

private let expectedMemorySnapshotKeys: Set<String> = [
  "peakResidentBytes",
  "physicalFootprintBytes",
  "residentBytes",
]

private enum MergeError: LocalizedError {
  case invalidArguments
  case unreadableJSON(path: String, underlying: Error)
  case invalidObject(path: String, expected: String)
  case invalidKeys(path: String, missing: [String], unexpected: [String])
  case unsupportedSchema(path: String, actual: Int)
  case metadataMismatch(path: String, field: String)
  case invalidCaseCount(path: String, actual: Int)
  case duplicateCaseID(String)
  case missingCase(String)
  case writeFailed(path: String, underlying: Error)

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "usage: transcript_benchmark_merge.swift <output.json> <part1.json> ..."
    case .unreadableJSON(let path, let underlying):
      return "cannot read JSON at \(path): \(underlying.localizedDescription)"
    case .invalidObject(let path, let expected):
      return "invalid benchmark JSON at \(path): expected \(expected)"
    case .invalidKeys(let path, let missing, let unexpected):
      var details: [String] = []
      if !missing.isEmpty {
        details.append("missing [\(missing.joined(separator: ", "))]")
      }
      if !unexpected.isEmpty {
        details.append("unexpected [\(unexpected.joined(separator: ", "))]")
      }
      return "invalid benchmark schema at \(path): \(details.joined(separator: "; "))"
    case .unsupportedSchema(let path, let actual):
      return
        "unsupported schemaVersion at \(path): expected \(supportedSchemaVersion), got \(actual)"
    case .metadataMismatch(let path, let field):
      return "metadata mismatch at \(path): \(field) differs from the first part"
    case .invalidCaseCount(let path, let actual):
      return "invalid benchmark part at \(path): expected exactly 1 case, got \(actual)"
    case .duplicateCaseID(let id):
      return "duplicate benchmark case id: \(id)"
    case .missingCase(let id):
      return "cannot calculate cross-scenario gates: missing case \(id)"
    case .writeFailed(let path, let underlying):
      return "cannot atomically write merged JSON at \(path): \(underlying.localizedDescription)"
    }
  }
}

private struct BenchmarkPart {
  let path: String
  let root: [String: Any]
  let schemaVersion: Int
  let generatedAt: String
  let environment: [String: Any]
  let settings: [String: Any]
  let benchmarkCase: [String: Any]
  let caseID: String
}

private func exactKeys(_ object: [String: Any], expected: Set<String>, path: String) throws {
  let actual = Set(object.keys)
  guard actual == expected else {
    throw MergeError.invalidKeys(
      path: path,
      missing: expected.subtracting(actual).sorted(),
      unexpected: actual.subtracting(expected).sorted()
    )
  }
}

private func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
  guard let dictionary = value as? [String: Any] else {
    throw MergeError.invalidObject(path: path, expected: "an object")
  }
  return dictionary
}

private func array(_ value: Any?, path: String) throws -> [Any] {
  guard let array = value as? [Any] else {
    throw MergeError.invalidObject(path: path, expected: "an array")
  }
  return array
}

private func string(_ value: Any?, path: String) throws -> String {
  guard let string = value as? String, !string.isEmpty else {
    throw MergeError.invalidObject(path: path, expected: "a non-empty string")
  }
  return string
}

private func number(_ value: Any?, path: String) throws -> Double {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID(),
    number.doubleValue.isFinite
  else {
    throw MergeError.invalidObject(path: path, expected: "a finite number")
  }
  return number.doubleValue
}

private func boolean(_ value: Any?, path: String) throws -> Bool {
  guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
    throw MergeError.invalidObject(path: path, expected: "a boolean")
  }
  return number.boolValue
}

private func integer(_ value: Any?, path: String) throws -> Int {
  let value = try number(value, path: path)
  guard value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) else {
    throw MergeError.invalidObject(path: path, expected: "an integer")
  }
  return Int(value)
}

private func canonicalJSON(_ object: Any, path: String) throws -> Data {
  guard JSONSerialization.isValidJSONObject(object) else {
    throw MergeError.invalidObject(path: path, expected: "a valid JSON value")
  }
  return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func validateEnvironment(_ environment: [String: Any], path: String) throws {
  for key in [
    "chip",
    "compileCondition",
    "configuration",
    "gitBranch",
    "gitCommit",
    "macModel",
    "optimization",
    "osBuild",
    "osVersion",
    "processIsolation",
    "protocolFingerprint",
    "sourceFingerprint",
    "swiftVersion",
    "testHostDiagnostics",
    "xcodeVersion",
  ] {
    _ = try string(environment[key], path: "\(path).\(key)")
  }
  _ = try boolean(environment["enableTestability"], path: "\(path).enableTestability")
  _ = try boolean(environment["gitDirty"], path: "\(path).gitDirty")
  _ = try integer(environment["physicalMemoryBytes"], path: "\(path).physicalMemoryBytes")
  _ = try integer(environment["processorCount"], path: "\(path).processorCount")
}

private func validateSettings(_ settings: [String: Any], path: String) throws {
  for key in [
    "deltaCharacters",
    "fixtureVersion",
    "sampleIterations",
    "trialsPerCase",
    "viewportHeight",
    "viewportWidth",
    "warmupIterations",
  ] {
    _ = try integer(settings[key], path: "\(path).\(key)")
  }
  for key in ["percentileMethod", "streamSemantics"] {
    _ = try string(settings[key], path: "\(path).\(key)")
  }
  for key in [
    "absoluteP95BudgetMs",
    "absoluteP99BudgetMs",
    "activeTailAdditiveBudgetMs",
    "activeTailRatioBudget",
    "historyNoiseBudgetMs",
    "historyRatioBudget",
  ] {
    _ = try number(settings[key], path: "\(path).\(key)")
  }
}

private func validateSample(_ sample: [String: Any], path: String) throws {
  try exactKeys(sample, expected: expectedSampleKeys, path: path)
  for key in ["activeTailCharacters", "iteration", "trial", "viewportWidth"] {
    _ = try integer(sample[key], path: "\(path).\(key)")
  }
  _ = try string(sample["operation"], path: "\(path).operation")
  for key in [
    "appKitUpdateMs",
    "heightAndLayoutMs",
    "rendererMs",
    "rowProjectionMs",
    "totalMs",
  ] {
    _ = try number(sample[key], path: "\(path).\(key)")
  }
}

private func validateMemorySnapshot(_ snapshot: [String: Any], path: String) throws {
  try exactKeys(snapshot, expected: expectedMemorySnapshotKeys, path: path)
  for key in expectedMemorySnapshotKeys {
    let value = try number(snapshot[key], path: "\(path).\(key)")
    guard value >= 0 else {
      throw MergeError.invalidObject(path: "\(path).\(key)", expected: "a nonnegative number")
    }
  }
}

private func loadPart(path: String) throws -> BenchmarkPart {
  let rootObject: Any
  do {
    let data = try Data(contentsOf: URL(filePath: path, directoryHint: .notDirectory))
    rootObject = try JSONSerialization.jsonObject(with: data)
  } catch {
    throw MergeError.unreadableJSON(path: path, underlying: error)
  }

  let root = try dictionary(rootObject, path: path)
  try exactKeys(root, expected: expectedRootKeys, path: path)

  let schemaVersion = try integer(root["schemaVersion"], path: "\(path).schemaVersion")
  guard schemaVersion == supportedSchemaVersion else {
    throw MergeError.unsupportedSchema(path: path, actual: schemaVersion)
  }

  let generatedAt = try string(root["generatedAt"], path: "\(path).generatedAt")
  let environment = try dictionary(root["environment"], path: "\(path).environment")
  try exactKeys(environment, expected: expectedEnvironmentKeys, path: "\(path).environment")
  try validateEnvironment(environment, path: "\(path).environment")
  let settings = try dictionary(root["settings"], path: "\(path).settings")
  try exactKeys(settings, expected: expectedSettingsKeys, path: "\(path).settings")
  try validateSettings(settings, path: "\(path).settings")

  _ = try array(root["crossScenarioGates"], path: "\(path).crossScenarioGates")
  let cases = try array(root["cases"], path: "\(path).cases")
  guard cases.count == 1 else {
    throw MergeError.invalidCaseCount(path: path, actual: cases.count)
  }
  let benchmarkCase = try dictionary(cases[0], path: "\(path).cases[0]")
  try exactKeys(benchmarkCase, expected: expectedCaseKeys, path: "\(path).cases[0]")
  let caseID = try string(benchmarkCase["id"], path: "\(path).cases[0].id")

  for key in ["measuredTailCharactersEnd", "measuredTailCharactersStart"] {
    _ = try integer(benchmarkCase[key], path: "\(path).cases[0].\(key)")
  }
  for key in ["cpuTimeMs", "cpuTimePerIterationMs", "cpuToMeasuredWallRatio"] {
    _ = try number(benchmarkCase[key], path: "\(path).cases[0].\(key)")
  }
  let samples = try array(benchmarkCase["samples"], path: "\(path).cases[0].samples")
  for (index, value) in samples.enumerated() {
    let sample = try dictionary(value, path: "\(path).cases[0].samples[\(index)]")
    try validateSample(sample, path: "\(path).cases[0].samples[\(index)]")
  }
  for key in [
    "memoryAfterColdApply",
    "memoryAfterMeasurements",
    "memoryBeforeFixture",
    "memoryBeforeHarness",
    "memoryBeforeMeasurements",
  ] {
    let snapshot = try dictionary(benchmarkCase[key], path: "\(path).cases[0].\(key)")
    try validateMemorySnapshot(snapshot, path: "\(path).cases[0].\(key)")
  }

  let timings = try dictionary(benchmarkCase["timings"], path: "\(path).cases[0].timings")
  let total = try dictionary(timings["total"], path: "\(path).cases[0].timings.total")
  _ = try number(total["p95Ms"], path: "\(path).cases[0].timings.total.p95Ms")

  return BenchmarkPart(
    path: path,
    root: root,
    schemaVersion: schemaVersion,
    generatedAt: generatedAt,
    environment: environment,
    settings: settings,
    benchmarkCase: benchmarkCase,
    caseID: caseID
  )
}

private func p95(case benchmarkCase: [String: Any], id: String) throws -> Double {
  let timings = try dictionary(benchmarkCase["timings"], path: "case \(id).timings")
  let total = try dictionary(timings["total"], path: "case \(id).timings.total")
  return try number(total["p95Ms"], path: "case \(id).timings.total.p95Ms")
}

private func gate(
  id: String,
  smallLabel: String,
  largeLabel: String,
  smallP95: Double,
  largeP95: Double,
  allowed: Double,
  expected: String
) -> [String: Any] {
  [
    "actual": String(
      format: "\(smallLabel)=%.3f ms \(largeLabel)=%.3f ms",
      smallP95,
      largeP95
    ),
    "expected": String(format: expected, allowed),
    "id": id,
    "passed": largeP95 <= allowed,
  ]
}

private func crossScenarioGates(
  cases: [[String: Any]],
  settings: [String: Any]
) throws -> [[String: Any]] {
  var casesByID: [String: [String: Any]] = [:]
  for benchmarkCase in cases {
    let id = try string(benchmarkCase["id"], path: "case.id")
    casesByID[id] = benchmarkCase
  }

  func requiredCase(_ id: String) throws -> [String: Any] {
    guard let benchmarkCase = casesByID[id] else {
      throw MergeError.missingCase(id)
    }
    return benchmarkCase
  }

  let historySmallID = "history-10-tail-10000-paragraph"
  let historyLargeID = "history-1000-tail-10000-paragraph"
  let historySmall = try p95(case: requiredCase(historySmallID), id: historySmallID)
  let historyLarge = try p95(case: requiredCase(historyLargeID), id: historyLargeID)
  let historyRatio = try number(
    settings["historyRatioBudget"],
    path: "settings.historyRatioBudget"
  )
  let historyNoise = try number(
    settings["historyNoiseBudgetMs"],
    path: "settings.historyNoiseBudgetMs"
  )
  let historyAllowed = max(historySmall * historyRatio, historySmall + historyNoise)

  var gates = [
    gate(
      id: "history-10-to-1000-p95",
      smallLabel: "10",
      largeLabel: "1000",
      smallP95: historySmall,
      largeP95: historyLarge,
      allowed: historyAllowed,
      expected: "1000-row p95 <= %.3f ms"
    )
  ]

  let tailRatio = try number(
    settings["activeTailRatioBudget"],
    path: "settings.activeTailRatioBudget"
  )
  let tailAdditive = try number(
    settings["activeTailAdditiveBudgetMs"],
    path: "settings.activeTailAdditiveBudgetMs"
  )
  for kind in ["paragraph", "openCodeFence"] {
    let smallID = "tail-500-1000-\(kind)"
    let largeID = "tail-500-50000-\(kind)"
    let small = try p95(case: requiredCase(smallID), id: smallID)
    let large = try p95(case: requiredCase(largeID), id: largeID)
    let allowed = min(small * tailRatio, small + tailAdditive)
    gates.append(
      gate(
        id: "tail-1k-to-50k-p95-\(kind)",
        smallLabel: "1k",
        largeLabel: "50k",
        smallP95: small,
        largeP95: large,
        allowed: allowed,
        expected: "50k-tail p95 <= %.3f ms"
      ))
  }
  return gates
}

private func merge(outputPath: String, partPaths: [String]) throws {
  let parts = try partPaths.map(loadPart(path:))
  guard let first = parts.first else {
    throw MergeError.invalidArguments
  }

  let expectedEnvironment = try canonicalJSON(first.environment, path: "environment")
  let expectedSettings = try canonicalJSON(first.settings, path: "settings")
  var seenCaseIDs: Set<String> = []
  var cases: [[String: Any]] = []
  cases.reserveCapacity(parts.count)

  for part in parts {
    guard part.schemaVersion == first.schemaVersion else {
      throw MergeError.metadataMismatch(path: part.path, field: "schemaVersion")
    }
    guard part.generatedAt == first.generatedAt else {
      throw MergeError.metadataMismatch(path: part.path, field: "generatedAt")
    }
    let actualEnvironment = try canonicalJSON(
      part.environment,
      path: "\(part.path).environment"
    )
    guard actualEnvironment == expectedEnvironment else {
      throw MergeError.metadataMismatch(path: part.path, field: "environment")
    }
    guard try canonicalJSON(part.settings, path: "\(part.path).settings") == expectedSettings
    else {
      throw MergeError.metadataMismatch(path: part.path, field: "settings")
    }
    guard seenCaseIDs.insert(part.caseID).inserted else {
      throw MergeError.duplicateCaseID(part.caseID)
    }
    cases.append(part.benchmarkCase)
  }

  var merged = first.root
  merged["cases"] = cases
  merged["crossScenarioGates"] = try crossScenarioGates(cases: cases, settings: first.settings)

  let outputURL = URL(filePath: outputPath, directoryHint: .notDirectory)
  do {
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
      withJSONObject: merged,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: outputURL, options: .atomic)
  } catch {
    throw MergeError.writeFailed(path: outputPath, underlying: error)
  }
}

guard CommandLine.arguments.count >= 3 else {
  FileHandle.standardError.write(Data("\(MergeError.invalidArguments.localizedDescription)\n".utf8))
  exit(2)
}

do {
  try merge(
    outputPath: CommandLine.arguments[1],
    partPaths: Array(CommandLine.arguments.dropFirst(2))
  )
} catch {
  FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
  exit(1)
}
