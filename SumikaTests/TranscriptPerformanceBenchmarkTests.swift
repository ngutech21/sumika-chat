import Foundation
import Testing

@testable import Sumika

@MainActor
@Suite(.serialized)
struct TranscriptPerformanceBenchmarkTests {
  @Test
  func recordsDeterministicBaselineWhenEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SUMIKA_RUN_TRANSCRIPT_BENCHMARK"] == "1" else {
      return
    }
    guard let outputPath = environment["SUMIKA_TRANSCRIPT_BENCHMARK_OUTPUT"],
      !outputPath.isEmpty
    else {
      Issue.record("SUMIKA_TRANSCRIPT_BENCHMARK_OUTPUT is required")
      return
    }

    let configuration = TranscriptBenchmarkConfiguration(environment: environment)
    let runner = TranscriptBenchmarkRunner(configuration: configuration)
    let report = try runner.run()
    let outputURL = URL(filePath: outputPath, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: outputURL, options: .atomic)
    print("TRANSCRIPT_BENCHMARK_REPORT \(outputURL.path(percentEncoded: false))")
  }
}

private struct TranscriptBenchmarkConfiguration {
  let environment: TranscriptBenchmarkEnvironment
  let settings: TranscriptBenchmarkSettings
  let generatedAt: String
  let requestedCaseID: String?

  init(environment values: [String: String]) {
    let samples = Self.positiveInt(values["SUMIKA_TRANSCRIPT_BENCHMARK_SAMPLES"]) ?? 100
    let warmups = Self.nonnegativeInt(values["SUMIKA_TRANSCRIPT_BENCHMARK_WARMUPS"]) ?? 5
    let deltaCharacters = 40
    let viewportWidth = 760
    let viewportHeight = 520
    requestedCaseID = values["SUMIKA_TRANSCRIPT_BENCHMARK_CASE"]
    environment = TranscriptBenchmarkEnvironment(
      gitCommit: values["SUMIKA_BENCHMARK_GIT_COMMIT"] ?? "unknown",
      gitBranch: values["SUMIKA_BENCHMARK_GIT_BRANCH"] ?? "unknown",
      sourceFingerprint: values["SUMIKA_BENCHMARK_SOURCE_FINGERPRINT"] ?? "unknown",
      protocolFingerprint: values["SUMIKA_BENCHMARK_PROTOCOL_FINGERPRINT"] ?? "unknown",
      gitDirty: values["SUMIKA_BENCHMARK_GIT_DIRTY"] == "1",
      configuration: values["SUMIKA_BENCHMARK_CONFIGURATION"] ?? "unknown",
      optimization: values["SUMIKA_BENCHMARK_OPTIMIZATION"] ?? "unknown",
      compileCondition: values["SUMIKA_BENCHMARK_COMPILE_CONDITION"] ?? "unknown",
      enableTestability: values["SUMIKA_BENCHMARK_ENABLE_TESTABILITY"] == "1",
      testHostDiagnostics: values["SUMIKA_BENCHMARK_TEST_HOST_DIAGNOSTICS"] ?? "unknown",
      processIsolation: values["SUMIKA_BENCHMARK_PROCESS_ISOLATION"] ?? "unknown",
      macModel: values["SUMIKA_BENCHMARK_MAC_MODEL"] ?? "unknown",
      chip: values["SUMIKA_BENCHMARK_CHIP"] ?? "unknown",
      physicalMemoryBytes: UInt64(values["SUMIKA_BENCHMARK_MEMORY_BYTES"] ?? "") ?? 0,
      processorCount: Int(values["SUMIKA_BENCHMARK_PROCESSOR_COUNT"] ?? "") ?? 0,
      osVersion: values["SUMIKA_BENCHMARK_OS_VERSION"] ?? "unknown",
      osBuild: values["SUMIKA_BENCHMARK_OS_BUILD"] ?? "unknown",
      xcodeVersion: values["SUMIKA_BENCHMARK_XCODE_VERSION"] ?? "unknown",
      swiftVersion: values["SUMIKA_BENCHMARK_SWIFT_VERSION"] ?? "unknown"
    )
    settings = TranscriptBenchmarkSettings(
      fixtureVersion: 2,
      trialsPerCase: 1,
      percentileMethod: "nearest-rank: ceil(p * count) - 1",
      streamSemantics: "one sequential growing-tail trace per scenario process",
      sampleIterations: samples,
      warmupIterations: warmups,
      deltaCharacters: deltaCharacters,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      absoluteP95BudgetMs: 8,
      absoluteP99BudgetMs: 16.7,
      historyRatioBudget: 1.2,
      historyNoiseBudgetMs: 0.5,
      activeTailRatioBudget: 2,
      activeTailAdditiveBudgetMs: 2
    )
    generatedAt =
      values["SUMIKA_BENCHMARK_TIMESTAMP"] ?? ISO8601DateFormatter().string(from: Date())
  }

  private static func positiveInt(_ value: String?) -> Int? {
    guard let value, let parsed = Int(value), parsed > 0 else {
      return nil
    }
    return parsed
  }

  private static func nonnegativeInt(_ value: String?) -> Int? {
    guard let value, let parsed = Int(value), parsed >= 0 else {
      return nil
    }
    return parsed
  }
}

@MainActor
private struct TranscriptBenchmarkRunner {
  private enum RunnerError: Error {
    case unknownCase(String)
  }

  private static let caseIDs = [
    "history-10-tail-10000-paragraph",
    "history-100-tail-10000-paragraph",
    "history-500-tail-10000-paragraph",
    "history-1000-tail-10000-paragraph",
    "tail-500-1000-paragraph",
    "tail-500-10000-paragraph",
    "tail-500-50000-paragraph",
    "tail-500-1000-openCodeFence",
    "tail-500-10000-openCodeFence",
    "tail-500-50000-openCodeFence",
    "worst-1000-tail-50000-paragraph",
    "tool-heavy-500-tail-10000",
    "mixed-500-tail-10000",
    "attachment-history-500-text-tail-10000",
    "resize-1000-760-360-760",
  ]

  let configuration: TranscriptBenchmarkConfiguration

  func run() throws -> TranscriptBenchmarkReport {
    let caseIDs = configuration.requestedCaseID.map { [$0] } ?? Self.caseIDs
    let results = try caseIDs.map(runCase)

    return TranscriptBenchmarkReport(
      schemaVersion: 3,
      generatedAt: configuration.generatedAt,
      environment: configuration.environment,
      settings: configuration.settings,
      cases: results,
      crossScenarioGates: crossScenarioGates(results: results)
    )
  }

  private func runCase(id: String) throws -> TranscriptBenchmarkCaseResult {
    switch id {
    case "history-10-tail-10000-paragraph":
      return try runHistoryCase(stableRows: 10)
    case "history-100-tail-10000-paragraph":
      return try runHistoryCase(stableRows: 100)
    case "history-500-tail-10000-paragraph":
      return try runHistoryCase(stableRows: 500)
    case "history-1000-tail-10000-paragraph":
      return try runHistoryCase(stableRows: 1_000)
    case "tail-500-1000-paragraph":
      return try runTailCase(characters: 1_000, kind: .paragraph)
    case "tail-500-10000-paragraph":
      return try runTailCase(characters: 10_000, kind: .paragraph)
    case "tail-500-50000-paragraph":
      return try runTailCase(characters: 50_000, kind: .paragraph)
    case "tail-500-1000-openCodeFence":
      return try runTailCase(characters: 1_000, kind: .openCodeFence)
    case "tail-500-10000-openCodeFence":
      return try runTailCase(characters: 10_000, kind: .openCodeFence)
    case "tail-500-50000-openCodeFence":
      return try runTailCase(characters: 50_000, kind: .openCodeFence)
    case "worst-1000-tail-50000-paragraph":
      return try runAppendCase(
        id: id,
        family: "combined-worst-case",
        fixtureFactory: {
          .history(stableRows: 1_000, tailCharacters: 50_000, tailKind: .paragraph)
        },
        tailKind: .paragraph,
        notes: ["Combines the largest history and active paragraph fixtures."]
      )
    case "tool-heavy-500-tail-10000":
      return try runAppendCase(
        id: id,
        family: "tool-heavy",
        fixtureFactory: { .toolHeavy(stableRows: 500, tailCharacters: 10_000) },
        tailKind: .paragraph,
        notes: [
          "One canonical batch contains 500 completed run_command rows.",
          "Each collapsed tool result carries a deterministic 2048-character output.",
        ]
      )
    case "mixed-500-tail-10000":
      return try runAppendCase(
        id: id,
        family: "mixed-smoke",
        fixtureFactory: { .mixed(stableRows: 500, tailCharacters: 10_000) },
        tailKind: .paragraph,
        notes: ["Mixes user, thinking, Markdown/table/code, and completed tool rows."]
      )
    case "attachment-history-500-text-tail-10000":
      return try runAppendCase(
        id: id,
        family: "attachment-history",
        fixtureFactory: { .attachmentHeavy(stableRows: 500, tailCharacters: 10_000) },
        tailKind: .paragraph,
        notes: [
          "Each stable user row owns two deterministic text attachments.",
          "The active streaming assistant row has no attachments, matching the product flow.",
          "Text attachments isolate identity/hash, layout, and view cost without thumbnail I/O.",
        ]
      )
    case "resize-1000-760-360-760":
      return try runResizeCase()
    default:
      throw RunnerError.unknownCase(id)
    }
  }

  private func runHistoryCase(stableRows: Int) throws -> TranscriptBenchmarkCaseResult {
    try runAppendCase(
      id: "history-\(stableRows)-tail-10000-paragraph",
      family: "history-scaling",
      fixtureFactory: {
        .history(stableRows: stableRows, tailCharacters: 10_000, tailKind: .paragraph)
      },
      tailKind: .paragraph,
      notes: ["Isolates historical row-count scaling with an identical active tail."]
    )
  }

  private func runTailCase(
    characters: Int,
    kind: TranscriptBenchmarkTailKind
  ) throws -> TranscriptBenchmarkCaseResult {
    try runAppendCase(
      id: "tail-500-\(characters)-\(kind.rawValue)",
      family: "active-tail-scaling",
      fixtureFactory: {
        .history(stableRows: 500, tailCharacters: characters, tailKind: kind)
      },
      tailKind: kind,
      notes: ["Isolates active-tail length with 500 stable historical rows."]
    )
  }

  private func runAppendCase(
    id: String,
    family: String,
    fixtureFactory: () -> TranscriptBenchmarkFixture,
    tailKind: TranscriptBenchmarkTailKind,
    notes: [String]
  ) throws -> TranscriptBenchmarkCaseResult {
    let settings = configuration.settings
    let memoryBeforeFixture = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let fixture = fixtureFactory()
    let memoryBeforeHarness = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let harness = try TranscriptBenchmarkHarness(
      fixture: fixture,
      viewportWidth: settings.viewportWidth,
      viewportHeight: settings.viewportHeight
    )
    let memoryAfterColdApply = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    for index in 0..<settings.warmupIterations {
      autoreleasepool {
        _ = harness.append(
          delta(index: -settings.warmupIterations + index),
          trial: 0,
          iteration: index - settings.warmupIterations
        )
      }
    }

    let cacheBefore = harness.cacheSnapshot()
    TranscriptPerformanceDiagnostics.beginRecording()
    let structuralSample = autoreleasepool {
      harness.append(delta(index: 0), trial: 0, iteration: -1)
    }
    let workSnapshot = TranscriptPerformanceDiagnostics.endRecording()
    let work = TranscriptBenchmarkWork(
      snapshot: workSnapshot,
      stableRowIDs: harness.stableRowIDs,
      activeRowID: harness.activeRowID
    )
    let cacheAfterStructuralSample = harness.cacheSnapshot()

    let memoryBeforeMeasurements = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let cpuBefore = TranscriptBenchmarkProcessMetrics.cpuTime()
    var samples: [TranscriptBenchmarkSample] = []
    samples.reserveCapacity(settings.sampleIterations)
    for index in 0..<settings.sampleIterations {
      samples.append(
        autoreleasepool {
          harness.append(delta(index: index + 1), trial: 0, iteration: index)
        })
    }
    let cpuAfter = TranscriptBenchmarkProcessMetrics.cpuTime()
    let memoryAfterMeasurements = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let cacheAfterMeasurements = harness.cacheSnapshot()
    let timings = TranscriptBenchmarkPhaseDistributions(samples: samples)
    let cpuTimeMs = (cpuAfter.seconds - cpuBefore.seconds) * 1_000
    let measuredWallMs = samples.reduce(0) { $0 + $1.totalMs }
    let gates = caseGates(
      timings: timings,
      work: work,
      cacheBefore: cacheBefore,
      cacheAfter: cacheAfterMeasurements,
      allowsHistoricalRowWrappers: false,
      allowsHistoricalHeightMisses: false
    )

    return TranscriptBenchmarkCaseResult(
      id: id,
      family: family,
      stableRows: fixture.stableRowCount,
      initialTailCharacters: fixture.initialActiveContent.count,
      measuredTailCharactersStart: samples.first?.activeTailCharacters
        ?? harness.activeContent.count,
      measuredTailCharactersEnd: samples.last?.activeTailCharacters
        ?? harness.activeContent.count,
      finalTailCharacters: harness.activeContent.count,
      tailKind: tailKind.rawValue,
      deltaCharacters: settings.deltaCharacters,
      warmupIterations: settings.warmupIterations,
      measuredIterations: settings.sampleIterations,
      viewportWidth: settings.viewportWidth,
      viewportHeight: settings.viewportHeight,
      coldApplyMs: harness.coldApplyMs,
      structuralSampleMs: structuralSample.totalMs,
      samples: samples,
      timings: timings,
      work: work,
      cacheBefore: cacheBefore,
      cacheAfterStructuralSample: cacheAfterStructuralSample,
      cacheAfterMeasurements: cacheAfterMeasurements,
      memoryBeforeFixture: memoryBeforeFixture,
      memoryBeforeHarness: memoryBeforeHarness,
      memoryAfterColdApply: memoryAfterColdApply,
      memoryBeforeMeasurements: memoryBeforeMeasurements,
      memoryAfterMeasurements: memoryAfterMeasurements,
      cpuTimeMs: cpuTimeMs,
      cpuTimePerIterationMs: cpuTimeMs / Double(max(samples.count, 1)),
      cpuToMeasuredWallRatio: cpuTimeMs / max(measuredWallMs, 0.001),
      gates: gates,
      notes: notes + [
        "Measured samples are ordered chunks in one growing-tail streaming trace, not independent trials."
      ]
    )
  }

  private func runResizeCase() throws -> TranscriptBenchmarkCaseResult {
    let settings = configuration.settings
    let memoryBeforeFixture = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let fixture = TranscriptBenchmarkFixture.history(
      stableRows: 1_000,
      tailCharacters: 10_000,
      tailKind: .paragraph
    )
    let memoryBeforeHarness = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let harness = try TranscriptBenchmarkHarness(
      fixture: fixture,
      viewportWidth: settings.viewportWidth,
      viewportHeight: settings.viewportHeight
    )
    let memoryAfterColdApply = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let cacheBefore = harness.cacheSnapshot()
    TranscriptPerformanceDiagnostics.beginRecording()
    let structuralSample = autoreleasepool {
      harness.updateAtViewportWidth(
        720,
        trial: 0,
        iteration: -1,
        operation: "cold-width"
      )
    }
    let workSnapshot = TranscriptPerformanceDiagnostics.endRecording()
    let work = TranscriptBenchmarkWork(
      snapshot: workSnapshot,
      stableRowIDs: harness.stableRowIDs,
      activeRowID: harness.activeRowID
    )
    let cacheAfterStructuralSample = harness.cacheSnapshot()

    let widths =
      Array(stride(from: 680, through: 360, by: -40))
      + Array(stride(from: 400, through: 760, by: 40))
    let measuredWidths = Array(widths.prefix(settings.sampleIterations))
    let memoryBeforeMeasurements = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let cpuBefore = TranscriptBenchmarkProcessMetrics.cpuTime()
    var samples: [TranscriptBenchmarkSample] = []
    samples.reserveCapacity(measuredWidths.count)
    for (index, width) in measuredWidths.enumerated() {
      let operation =
        width < (samples.last?.viewportWidth ?? 720)
        ? "cold-width"
        : "warm-revisit"
      samples.append(
        autoreleasepool {
          harness.updateAtViewportWidth(
            width,
            trial: 0,
            iteration: index,
            operation: operation
          )
        })
    }
    let cpuAfter = TranscriptBenchmarkProcessMetrics.cpuTime()
    let memoryAfterMeasurements = TranscriptBenchmarkProcessMetrics.memorySnapshot()
    let cacheAfterMeasurements = harness.cacheSnapshot()
    let timings = TranscriptBenchmarkPhaseDistributions(samples: samples)
    let cpuTimeMs = (cpuAfter.seconds - cpuBefore.seconds) * 1_000
    let measuredWallMs = samples.reduce(0) { $0 + $1.totalMs }

    return TranscriptBenchmarkCaseResult(
      id: "resize-1000-760-360-760",
      family: "resize",
      stableRows: fixture.stableRowCount,
      initialTailCharacters: fixture.initialActiveContent.count,
      measuredTailCharactersStart: samples.first?.activeTailCharacters
        ?? harness.activeContent.count,
      measuredTailCharactersEnd: samples.last?.activeTailCharacters
        ?? harness.activeContent.count,
      finalTailCharacters: harness.activeContent.count,
      tailKind: TranscriptBenchmarkTailKind.paragraph.rawValue,
      deltaCharacters: 0,
      warmupIterations: 0,
      measuredIterations: samples.count,
      viewportWidth: settings.viewportWidth,
      viewportHeight: settings.viewportHeight,
      coldApplyMs: harness.coldApplyMs,
      structuralSampleMs: structuralSample.totalMs,
      samples: samples,
      timings: timings,
      work: work,
      cacheBefore: cacheBefore,
      cacheAfterStructuralSample: cacheAfterStructuralSample,
      cacheAfterMeasurements: cacheAfterMeasurements,
      memoryBeforeFixture: memoryBeforeFixture,
      memoryBeforeHarness: memoryBeforeHarness,
      memoryAfterColdApply: memoryAfterColdApply,
      memoryBeforeMeasurements: memoryBeforeMeasurements,
      memoryAfterMeasurements: memoryAfterMeasurements,
      cpuTimeMs: cpuTimeMs,
      cpuTimePerIterationMs: cpuTimeMs / Double(max(samples.count, 1)),
      cpuToMeasuredWallRatio: cpuTimeMs / max(measuredWallMs, 0.001),
      gates: resizeGates(work: work),
      notes: [
        "The structural sample is the first cold width change from 760 to 720 points.",
        "Timed samples sweep unseen widths down to 360, then revisit cached widths up to 760.",
        "Cold-width and warm-revisit legs are identified in every raw sample.",
        "Resize may remeasure rows but must not recreate semantic item projections.",
        "Absolute streaming budgets do not apply to this resize lifecycle scenario.",
      ]
    )
  }

  private func delta(index: Int) -> String {
    let prefix = String(format: " d%08d ", index)
    let padding = max(configuration.settings.deltaCharacters - prefix.count, 0)
    return String(
      (prefix + String(repeating: "x", count: padding)).prefix(
        configuration.settings.deltaCharacters
      ))
  }

  private func caseGates(
    timings: TranscriptBenchmarkPhaseDistributions,
    work: TranscriptBenchmarkWork,
    cacheBefore: TranscriptBenchmarkCacheSnapshot,
    cacheAfter: TranscriptBenchmarkCacheSnapshot,
    allowsHistoricalRowWrappers: Bool,
    allowsHistoricalHeightMisses: Bool
  ) -> [TranscriptBenchmarkGate] {
    let settings = configuration.settings
    let forbiddenStableWork =
      work.stableRenderedItemProjections + work.stableMarkdownParses
      + work.stableCellConfigurations
      + (allowsHistoricalRowWrappers ? 0 : work.stableRowWrapperProjections)
      + (allowsHistoricalHeightMisses ? 0 : work.stableHeightCacheMisses)
    let activeWork =
      work.activeRenderedItemProjections + work.activeRowWrapperProjections
      + work.activeMarkdownParses + work.activeHeightCacheMisses
      + work.activeCellConfigurations
    return [
      TranscriptBenchmarkGate(
        id: "absolute-p95",
        passed: timings.total.p95Ms <= settings.absoluteP95BudgetMs,
        expected: "total p95 <= \(settings.absoluteP95BudgetMs) ms",
        actual: String(format: "%.3f ms", timings.total.p95Ms)
      ),
      TranscriptBenchmarkGate(
        id: "absolute-p99",
        passed: timings.total.p99Ms < settings.absoluteP99BudgetMs,
        expected: "total p99 < \(settings.absoluteP99BudgetMs) ms",
        actual: String(format: "%.3f ms", timings.total.p99Ms)
      ),
      TranscriptBenchmarkGate(
        id: "append-only-stable-work",
        passed: forbiddenStableWork == 0 && work.unattributedWork == 0,
        expected: "0 forbidden stable-row events and 0 unattributed events",
        actual: "stable=\(forbiddenStableWork) unattributed=\(work.unattributedWork)"
      ),
      TranscriptBenchmarkGate(
        id: "active-row-observed",
        passed: activeWork > 0,
        expected: "at least 1 active-row work event",
        actual: "active=\(activeWork)"
      ),
      TranscriptBenchmarkGate(
        id: "cache-entry-counts-bounded",
        passed: cacheBefore == cacheAfter,
        expected: "cache entry counts unchanged across steady-state samples",
        actual: cacheBefore == cacheAfter ? "unchanged" : "changed"
      ),
    ]
  }

  private func resizeGates(work: TranscriptBenchmarkWork) -> [TranscriptBenchmarkGate] {
    let semanticWork =
      work.stableRenderedItemProjections + work.activeRenderedItemProjections
      + work.stableMarkdownParses + work.activeMarkdownParses
      + work.stableCellConfigurations + work.activeCellConfigurations
    let layoutWork =
      work.stableRowWrapperProjections + work.activeRowWrapperProjections
      + work.stableHeightCacheMisses + work.activeHeightCacheMisses
    return [
      TranscriptBenchmarkGate(
        id: "resize-no-semantic-recreation",
        passed: semanticWork == 0 && work.unattributedWork == 0,
        expected: "0 semantic item/Markdown/cell events and 0 unattributed events",
        actual: "semantic=\(semanticWork) unattributed=\(work.unattributedWork)"
      ),
      TranscriptBenchmarkGate(
        id: "resize-layout-work-observed",
        passed: layoutWork > 0,
        expected: "at least 1 row-wrapper or height event for an unseen width",
        actual: "layout=\(layoutWork)"
      ),
    ]
  }

  private func crossScenarioGates(
    results: [TranscriptBenchmarkCaseResult]
  ) -> [TranscriptBenchmarkGate] {
    var gates: [TranscriptBenchmarkGate] = []
    if let small = results.first(where: { $0.id == "history-10-tail-10000-paragraph" }),
      let large = results.first(where: { $0.id == "history-1000-tail-10000-paragraph" })
    {
      let allowed = max(
        small.timings.total.p95Ms * configuration.settings.historyRatioBudget,
        small.timings.total.p95Ms + configuration.settings.historyNoiseBudgetMs
      )
      gates.append(
        TranscriptBenchmarkGate(
          id: "history-10-to-1000-p95",
          passed: large.timings.total.p95Ms <= allowed,
          expected: String(format: "1000-row p95 <= %.3f ms", allowed),
          actual: String(
            format: "10=%.3f ms 1000=%.3f ms",
            small.timings.total.p95Ms,
            large.timings.total.p95Ms
          )
        ))
    }
    gates.append(contentsOf: tailScalingGates(results: results, kind: .paragraph))
    gates.append(contentsOf: tailScalingGates(results: results, kind: .openCodeFence))
    return gates
  }

  private func tailScalingGates(
    results: [TranscriptBenchmarkCaseResult],
    kind: TranscriptBenchmarkTailKind
  ) -> [TranscriptBenchmarkGate] {
    guard
      let small = results.first(where: { $0.id == "tail-500-1000-\(kind.rawValue)" }),
      let large = results.first(where: { $0.id == "tail-500-50000-\(kind.rawValue)" })
    else {
      return []
    }
    let allowed = min(
      small.timings.total.p95Ms * configuration.settings.activeTailRatioBudget,
      small.timings.total.p95Ms + configuration.settings.activeTailAdditiveBudgetMs
    )
    return [
      TranscriptBenchmarkGate(
        id: "tail-1k-to-50k-p95-\(kind.rawValue)",
        passed: large.timings.total.p95Ms <= allowed,
        expected: String(format: "50k-tail p95 <= %.3f ms", allowed),
        actual: String(
          format: "1k=%.3f ms 50k=%.3f ms",
          small.timings.total.p95Ms,
          large.timings.total.p95Ms
        )
      )
    ]
  }
}
