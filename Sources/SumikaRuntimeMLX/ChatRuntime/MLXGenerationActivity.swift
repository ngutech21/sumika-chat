import Foundation
import SumikaCore
import Synchronization

final class MLXGenerationActivityLease: Sendable {
  let request: GenerationActivityRequest
  private let endOperation: Mutex<(@Sendable () -> Void)?>

  init(
    request: GenerationActivityRequest,
    end: @escaping @Sendable () -> Void
  ) {
    self.request = request
    self.endOperation = Mutex(end)
  }

  func end() {
    let operation = endOperation.withLock { operation in
      defer { operation = nil }
      return operation
    }
    operation?()
  }

  deinit {
    end()
  }
}

struct MLXGenerationActivity: Sendable {
  private let beginOperation: @Sendable () -> MLXGenerationActivityLease

  static let live = Self(
    begin: {
      let activity = LiveProcessActivity()
      return MLXGenerationActivityLease(
        request: .userInitiatedAllowingIdleSystemSleep,
        end: activity.end
      )
    }
  )

  static let disabled = Self(
    begin: {
      MLXGenerationActivityLease(
        request: .none,
        end: {}
      )
    }
  )

  static func configured(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    environment["SUMIKA_GENERATION_ACTIVITY"]?.lowercased() == "disabled"
      ? .disabled
      : .live
  }

  init(
    begin: @escaping @Sendable () -> MLXGenerationActivityLease
  ) {
    self.beginOperation = begin
  }

  func start<Stream>(
    _ makeStream: () -> Stream
  ) -> MLXStartedGeneration<Stream> {
    let startedAt = Date()
    let lease = beginOperation()
    return MLXStartedGeneration(
      stream: makeStream(),
      startedAt: startedAt,
      activityLease: lease
    )
  }
}

struct MLXStartedGeneration<Stream> {
  let stream: Stream
  let startedAt: Date
  let activityLease: MLXGenerationActivityLease
}

private final class LiveProcessActivity: @unchecked Sendable {
  private let processInfo = ProcessInfo.processInfo
  private let token: NSObjectProtocol

  init() {
    token = processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Generating a local model response"
    )
  }

  func end() {
    processInfo.endActivity(token)
  }
}
