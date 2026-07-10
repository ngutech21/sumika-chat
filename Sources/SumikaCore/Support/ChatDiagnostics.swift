#if DEBUG && canImport(OSLog)
  import OSLog
#endif

public enum ChatDiagnostics {
  public enum Category: String {
    case generation = "ChatGeneration"
    case transcript = "ChatTranscript"
  }

  public struct Metadata: Sendable {
    fileprivate let summary: String

    public init(_ summary: String) {
      self.summary = summary
    }
  }

  public struct Interval {
    #if DEBUG && canImport(OSLog)
      fileprivate let category: Category
      fileprivate let name: StaticString
      fileprivate let state: OSSignpostIntervalState

      fileprivate init(category: Category, name: StaticString, state: OSSignpostIntervalState) {
        self.category = category
        self.name = name
        self.state = state
      }
    #else
      fileprivate init() {}
    #endif
  }

  public static func beginInterval(
    _ name: StaticString,
    category: Category
  ) -> Interval {
    #if DEBUG && canImport(OSLog)
      let signposter = signposter(for: category)
      return Interval(category: category, name: name, state: signposter.beginInterval(name))
    #else
      return Interval()
    #endif
  }

  public static func beginInterval(
    _ name: StaticString,
    category: Category,
    metadata: @autoclosure () -> Metadata
  ) -> Interval {
    #if DEBUG && canImport(OSLog)
      let metadata = metadata()
      let signposter = signposter(for: category)
      return Interval(
        category: category,
        name: name,
        state: signposter.beginInterval(name, "\(metadata.summary, privacy: .public)")
      )
    #else
      return Interval()
    #endif
  }

  public static func endInterval(_ interval: Interval) {
    #if DEBUG && canImport(OSLog)
      signposter(for: interval.category).endInterval(interval.name, interval.state)
    #endif
  }

  @discardableResult
  public static func measure<T>(
    _ name: StaticString,
    category: Category,
    _ operation: () throws -> T
  ) rethrows -> T {
    #if DEBUG && canImport(OSLog)
      let interval = beginInterval(name, category: category)
      defer {
        endInterval(interval)
      }
      return try operation()
    #else
      return try operation()
    #endif
  }

  @discardableResult
  public static func measure<T>(
    _ name: StaticString,
    category: Category,
    metadata: @autoclosure () -> Metadata,
    _ operation: () throws -> T
  ) rethrows -> T {
    #if DEBUG && canImport(OSLog)
      let interval = beginInterval(name, category: category, metadata: metadata())
      defer {
        endInterval(interval)
      }
      return try operation()
    #else
      return try operation()
    #endif
  }

  #if DEBUG && canImport(OSLog)
    private static let generationSignposter = OSSignposter(
      subsystem: SumikaTelemetry.subsystem,
      category: Category.generation.rawValue
    )
    private static let transcriptSignposter = OSSignposter(
      subsystem: SumikaTelemetry.subsystem,
      category: Category.transcript.rawValue
    )

    private static func signposter(for category: Category) -> OSSignposter {
      switch category {
      case .generation:
        generationSignposter
      case .transcript:
        transcriptSignposter
      }
    }
  #endif
}
