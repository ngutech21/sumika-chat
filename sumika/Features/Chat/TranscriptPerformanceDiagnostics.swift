import Foundation

/// Benchmark-only counters for proving that one streaming append does not redo
/// work for stable transcript rows. Calls compile to no-ops in production
/// Release builds; benchmark timing samples leave recording disabled as well.
@MainActor
enum TranscriptPerformanceDiagnostics {
  enum CellConfigurationSource: String, Hashable {
    case dataSource
    case visibleReconfigure
  }

  struct CellConfiguration: Hashable {
    let rowID: String
    let source: CellConfigurationSource
  }

  struct HeightCacheMiss: Hashable {
    let rowID: String
    let reason: String
    let width: Int
  }

  struct WorkSnapshot {
    var renderedItemProjections: [String: Int] = [:]
    var rowWrapperProjections: [String: Int] = [:]
    var markdownParses: [String: Int] = [:]
    var heightCacheMisses: [HeightCacheMiss: Int] = [:]
    var cellConfigurations: [CellConfiguration: Int] = [:]
  }

  struct RendererCacheSnapshot {
    let renderedItems: Int
    let assistantBlocks: Int
    let streamingBlocks: Int
  }

  struct HighlightStoreEntryCounts {
    let descriptors: Int
    let inFlight: Int
    let versions: Int
  }

  struct ThumbnailStoreEntryCounts {
    let cached: Int
    let failed: Int
    let inFlight: Int
  }

  struct CoordinatorCacheSnapshot {
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

  #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
    private static var currentSnapshot = WorkSnapshot()
    private(set) static var isRecording = false
  #else
    static let isRecording = false
  #endif

  static func beginRecording() {
    #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
      currentSnapshot = WorkSnapshot()
      isRecording = true
    #endif
  }

  static func endRecording() -> WorkSnapshot {
    #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
      isRecording = false
      return currentSnapshot
    #else
      return WorkSnapshot()
    #endif
  }

  @inline(__always)
  static func recordRenderedItemProjection(rowID: String) {
    #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
      guard isRecording else {
        return
      }
      currentSnapshot.renderedItemProjections[rowID, default: 0] += 1
    #endif
  }

  @inline(__always)
  static func recordRowWrapperProjection(rowID: String) {
    #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
      guard isRecording else {
        return
      }
      currentSnapshot.rowWrapperProjections[rowID, default: 0] += 1
    #endif
  }

  @inline(__always)
  static func recordMarkdownParse(rowID: String?) {
    #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
      guard isRecording else {
        return
      }
      currentSnapshot.markdownParses[rowID ?? "unknown", default: 0] += 1
    #endif
  }

  @inline(__always)
  static func recordHeightCacheMiss(rowID: String, reason: String, width: Int) {
    #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
      guard isRecording else {
        return
      }
      let miss = HeightCacheMiss(rowID: rowID, reason: reason, width: width)
      currentSnapshot.heightCacheMisses[miss, default: 0] += 1
    #endif
  }

  @inline(__always)
  static func recordCellConfiguration(
    rowID: String,
    source: CellConfigurationSource
  ) {
    #if DEBUG || SUMIKA_PERFORMANCE_DIAGNOSTICS
      guard isRecording else {
        return
      }
      let configuration = CellConfiguration(rowID: rowID, source: source)
      currentSnapshot.cellConfigurations[configuration, default: 0] += 1
    #endif
  }
}
