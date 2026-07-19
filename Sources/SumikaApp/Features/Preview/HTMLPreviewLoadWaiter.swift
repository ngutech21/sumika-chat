import Foundation

@MainActor
enum HTMLPreviewLoadWaitOutcome: Equatable {
  case finished
  case failed(String)
  case timedOut(String)
}

@MainActor
final class HTMLPreviewLoadWaiter {
  static let defaultTimeout: Duration = .seconds(30)
  static let timeoutMessage = "Preview did not finish loading within 30 seconds."

  private let timeout: Duration
  private var waiters: [UUID: CheckedContinuation<HTMLPreviewLoadWaitOutcome, Never>] = [:]
  private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

  init(timeout: Duration = defaultTimeout) {
    self.timeout = timeout
  }

  func waitForLoadIfNeeded() async -> HTMLPreviewLoadWaitOutcome {
    let id = UUID()
    let timeout = self.timeout
    return await withCheckedContinuation { continuation in
      waiters[id] = continuation
      timeoutTasks[id] = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        self?.completeWaiter(id, with: .timedOut(Self.timeoutMessage))
      }
    }
  }

  func finish(error: String?) {
    completeAll(with: error.map(HTMLPreviewLoadWaitOutcome.failed) ?? .finished)
  }

  private func completeWaiter(_ id: UUID, with outcome: HTMLPreviewLoadWaitOutcome) {
    guard let waiter = waiters.removeValue(forKey: id) else {
      return
    }
    timeoutTasks.removeValue(forKey: id)?.cancel()
    waiter.resume(returning: outcome)
  }

  private func completeAll(with outcome: HTMLPreviewLoadWaitOutcome) {
    let waiters = self.waiters
    let timeoutTasks = self.timeoutTasks
    self.waiters.removeAll()
    self.timeoutTasks.removeAll()
    for timeoutTask in timeoutTasks.values {
      timeoutTask.cancel()
    }
    for waiter in waiters.values {
      waiter.resume(returning: outcome)
    }
  }
}
