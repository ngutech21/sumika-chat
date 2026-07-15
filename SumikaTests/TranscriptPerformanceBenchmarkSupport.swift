import Darwin
import Foundation

@testable import Sumika

struct TranscriptBenchmarkDistribution: Codable {
  let count: Int
  let meanMs: Double
  let p50Ms: Double
  let p90Ms: Double
  let p95Ms: Double
  let p99Ms: Double
  let maxMs: Double

  init(values: [Double]) {
    let sorted = values.sorted()
    count = sorted.count
    meanMs = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    p50Ms = Self.percentile(0.50, in: sorted)
    p90Ms = Self.percentile(0.90, in: sorted)
    p95Ms = Self.percentile(0.95, in: sorted)
    p99Ms = Self.percentile(0.99, in: sorted)
    maxMs = sorted.last ?? 0
  }

  private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
    guard !sorted.isEmpty else {
      return 0
    }
    let rank = Int(ceil(percentile * Double(sorted.count))) - 1
    return sorted[max(0, min(rank, sorted.count - 1))]
  }
}

struct TranscriptBenchmarkPhaseDistributions: Codable {
  let total: TranscriptBenchmarkDistribution
  let renderer: TranscriptBenchmarkDistribution
  let rowProjection: TranscriptBenchmarkDistribution
  let appKitUpdate: TranscriptBenchmarkDistribution
  let heightAndLayout: TranscriptBenchmarkDistribution

  init(samples: [TranscriptBenchmarkSample]) {
    total = TranscriptBenchmarkDistribution(values: samples.map(\.totalMs))
    renderer = TranscriptBenchmarkDistribution(values: samples.map(\.rendererMs))
    rowProjection = TranscriptBenchmarkDistribution(values: samples.map(\.rowProjectionMs))
    appKitUpdate = TranscriptBenchmarkDistribution(values: samples.map(\.appKitUpdateMs))
    heightAndLayout = TranscriptBenchmarkDistribution(
      values: samples.map(\.heightAndLayoutMs)
    )
  }
}

struct TranscriptBenchmarkSample: Codable {
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

struct TranscriptBenchmarkMemorySnapshot: Codable {
  let residentBytes: UInt64
  let physicalFootprintBytes: UInt64
  let peakResidentBytes: UInt64
}

struct TranscriptBenchmarkWork: Codable {
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

  init(
    snapshot: TranscriptPerformanceDiagnostics.WorkSnapshot,
    stableRowIDs: Set<String>,
    activeRowID: String
  ) {
    stableRenderedItemProjections = Self.total(
      snapshot.renderedItemProjections,
      matching: stableRowIDs
    )
    activeRenderedItemProjections = snapshot.renderedItemProjections[activeRowID] ?? 0
    stableRowWrapperProjections = Self.total(
      snapshot.rowWrapperProjections,
      matching: stableRowIDs
    )
    activeRowWrapperProjections = snapshot.rowWrapperProjections[activeRowID] ?? 0
    stableMarkdownParses = Self.total(snapshot.markdownParses, matching: stableRowIDs)
    activeMarkdownParses = snapshot.markdownParses[activeRowID] ?? 0
    stableHeightCacheMisses = snapshot.heightCacheMisses.reduce(0) { total, entry in
      total + (stableRowIDs.contains(entry.key.rowID) ? entry.value : 0)
    }
    activeHeightCacheMisses = snapshot.heightCacheMisses.reduce(0) { total, entry in
      total + (entry.key.rowID == activeRowID ? entry.value : 0)
    }
    stableCellConfigurations = snapshot.cellConfigurations.reduce(0) { total, entry in
      total + (stableRowIDs.contains(entry.key.rowID) ? entry.value : 0)
    }
    activeCellConfigurations = snapshot.cellConfigurations.reduce(0) { total, entry in
      total + (entry.key.rowID == activeRowID ? entry.value : 0)
    }

    let attributedIDs = stableRowIDs.union([activeRowID])
    let unattributedRendered = Self.totalExcluding(
      snapshot.renderedItemProjections,
      ids: attributedIDs
    )
    let unattributedRows = Self.totalExcluding(snapshot.rowWrapperProjections, ids: attributedIDs)
    let unattributedMarkdown = Self.totalExcluding(snapshot.markdownParses, ids: attributedIDs)
    let unattributedHeights = snapshot.heightCacheMisses.reduce(0) { total, entry in
      total + (attributedIDs.contains(entry.key.rowID) ? 0 : entry.value)
    }
    let unattributedCells = snapshot.cellConfigurations.reduce(0) { total, entry in
      total + (attributedIDs.contains(entry.key.rowID) ? 0 : entry.value)
    }
    unattributedWork =
      unattributedRendered + unattributedRows + unattributedMarkdown + unattributedHeights
      + unattributedCells
  }

  var stableWorkTotal: Int {
    stableRenderedItemProjections + stableRowWrapperProjections + stableMarkdownParses
      + stableHeightCacheMisses + stableCellConfigurations
  }

  private static func total(_ counts: [String: Int], matching ids: Set<String>) -> Int {
    counts.reduce(0) { total, entry in
      total + (ids.contains(entry.key) ? entry.value : 0)
    }
  }

  private static func totalExcluding(_ counts: [String: Int], ids: Set<String>) -> Int {
    counts.reduce(0) { total, entry in
      total + (ids.contains(entry.key) ? 0 : entry.value)
    }
  }
}

struct TranscriptBenchmarkCacheSnapshot: Codable, Equatable {
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

  init(
    renderer: TranscriptPerformanceDiagnostics.RendererCacheSnapshot,
    coordinator: TranscriptPerformanceDiagnostics.CoordinatorCacheSnapshot
  ) {
    renderedItems = renderer.renderedItems
    assistantBlocks = renderer.assistantBlocks
    streamingBlocks = renderer.streamingBlocks
    heights = coordinator.heights
    markdown = coordinator.markdown
    highlightedCode = coordinator.highlightedCode
    highlightDescriptors = coordinator.highlightDescriptors
    highlightsInFlight = coordinator.highlightsInFlight
    highlightVersions = coordinator.highlightVersions
    thumbnails = coordinator.thumbnails
    thumbnailFailures = coordinator.thumbnailFailures
    thumbnailsInFlight = coordinator.thumbnailsInFlight
  }
}

struct TranscriptBenchmarkGate: Codable {
  let id: String
  let passed: Bool
  let expected: String
  let actual: String
}

struct TranscriptBenchmarkCaseResult: Codable {
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
  let samples: [TranscriptBenchmarkSample]
  let timings: TranscriptBenchmarkPhaseDistributions
  let work: TranscriptBenchmarkWork
  let cacheBefore: TranscriptBenchmarkCacheSnapshot
  let cacheAfterStructuralSample: TranscriptBenchmarkCacheSnapshot
  let cacheAfterMeasurements: TranscriptBenchmarkCacheSnapshot
  let memoryBeforeFixture: TranscriptBenchmarkMemorySnapshot
  let memoryBeforeHarness: TranscriptBenchmarkMemorySnapshot
  let memoryAfterColdApply: TranscriptBenchmarkMemorySnapshot
  let memoryBeforeMeasurements: TranscriptBenchmarkMemorySnapshot
  let memoryAfterMeasurements: TranscriptBenchmarkMemorySnapshot
  let cpuTimeMs: Double
  let cpuTimePerIterationMs: Double
  let cpuToMeasuredWallRatio: Double
  var gates: [TranscriptBenchmarkGate]
  let notes: [String]
}

struct TranscriptBenchmarkEnvironment: Codable {
  let gitCommit: String
  let gitBranch: String
  let sourceFingerprint: String
  let protocolFingerprint: String
  let gitDirty: Bool
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

struct TranscriptBenchmarkSettings: Codable {
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

struct TranscriptBenchmarkReport: Codable {
  let schemaVersion: Int
  let generatedAt: String
  let environment: TranscriptBenchmarkEnvironment
  let settings: TranscriptBenchmarkSettings
  var cases: [TranscriptBenchmarkCaseResult]
  var crossScenarioGates: [TranscriptBenchmarkGate]
}

enum TranscriptBenchmarkProcessMetrics {
  struct CPUTime {
    let seconds: Double
  }

  static func memorySnapshot() -> TranscriptBenchmarkMemorySnapshot {
    var basicInfo = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let basicStatus = withUnsafeMutablePointer(to: &basicInfo) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          rebound,
          &count
        )
      }
    }
    guard basicStatus == KERN_SUCCESS else {
      return TranscriptBenchmarkMemorySnapshot(
        residentBytes: 0,
        physicalFootprintBytes: 0,
        peakResidentBytes: 0
      )
    }

    var vmInfo = task_vm_info_data_t()
    count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let vmStatus = withUnsafeMutablePointer(to: &vmInfo) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(
          mach_task_self_,
          task_flavor_t(TASK_VM_INFO),
          rebound,
          &count
        )
      }
    }
    return TranscriptBenchmarkMemorySnapshot(
      residentBytes: UInt64(basicInfo.resident_size),
      physicalFootprintBytes: vmStatus == KERN_SUCCESS ? UInt64(vmInfo.phys_footprint) : 0,
      peakResidentBytes: vmStatus == KERN_SUCCESS ? UInt64(vmInfo.resident_size_peak) : 0
    )
  }

  static func cpuTime() -> CPUTime {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
      return CPUTime(seconds: 0)
    }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return CPUTime(seconds: user + system)
  }
}

@inline(__always)
func transcriptBenchmarkMilliseconds(since start: UInt64, until end: UInt64) -> Double {
  Double(end - start) / 1_000_000
}
