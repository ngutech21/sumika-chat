import Foundation
import Synchronization

/// Streams immutable-revision files to disk so cancellation preserves received bytes.
final class ModelFileDownload: NSObject, URLSessionDataDelegate, Sendable {
  private struct State {
    var task: URLSessionDataTask?
    var continuation: CheckedContinuation<Void, any Error>?
    var handle: FileHandle?
    var error: (any Error)?
    var cancelled = false
    var received: Int64 = 0
  }

  private let state = Mutex(State())
  private let partial: URL
  private let size: Int64
  private let offset: Int64
  private let progress: Progress

  private init(partial: URL, size: Int64, offset: Int64, progress: Progress) {
    self.partial = partial
    self.size = size
    self.offset = offset
    self.progress = progress
  }

  static func download(
    request: URLRequest, to destination: URL, size: Int64, progress: Progress,
    configuration: URLSessionConfiguration
  ) async throws {
    try Task.checkCancellation()
    let manager = FileManager.default
    if fileSize(destination) == size {
      progress.completedUnitCount = progress.totalUnitCount
      return
    }
    try manager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partial = destination.appendingPathExtension("partial")
    var offset = fileSize(partial) ?? 0
    if offset > size {
      try manager.removeItem(at: partial)
      offset = 0
    }
    if offset != size || !manager.fileExists(atPath: partial.path) {
      var request = request
      if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
      let delegate = ModelFileDownload(
        partial: partial, size: size, offset: offset, progress: progress)
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      defer { session.finishTasksAndInvalidate() }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          let task = session.dataTask(with: request)
          delegate.state.withLock {
            $0.continuation = continuation
            $0.task = task
            if $0.cancelled { task.cancel() } else { task.resume() }
          }
        }
      } onCancel: {
        delegate.state.withLock {
          $0.cancelled = true
          $0.task?.cancel()
        }
      }
    }
    try Task.checkCancellation()
    guard fileSize(partial) == size else { throw URLError(.badServerResponse) }
    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
    try manager.moveItem(at: partial, to: destination)
    progress.completedUnitCount = progress.totalUnitCount
  }

  private static func fileSize(_ url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return nil }
    return (attributes[.size] as? NSNumber)?.int64Value
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    do {
      guard let response = response as? HTTPURLResponse,
        response.statusCode == 200 || response.statusCode == 206,
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html")
          != true
      else { throw URLError(.badServerResponse) }
      let base: Int64
      if response.statusCode == 206 {
        guard offset > 0,
          response.value(forHTTPHeaderField: "Content-Range")
            == "bytes \(offset)-\(size - 1)/\(size)"
        else { throw URLError(.badServerResponse) }
        base = offset
      } else {
        base = 0
      }
      if !FileManager.default.fileExists(atPath: partial.path) {
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
      let handle = try FileHandle(forWritingTo: partial)
      do {
        if base == 0 { try handle.truncate(atOffset: 0) }
        try handle.seek(toOffset: UInt64(base))
      } catch {
        try? handle.close()
        throw error
      }
      state.withLock {
        $0.handle = handle
        $0.received = base
      }
      progress.completedUnitCount = base
      completionHandler(.allow)
    } catch {
      state.withLock { $0.error = error }
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    state.withLock {
      guard !$0.cancelled, $0.error == nil, let handle = $0.handle else { return }
      do {
        guard Int64(data.count) <= size - $0.received else { throw URLError(.badServerResponse) }
        try handle.write(contentsOf: data)
        $0.received += Int64(data.count)
        progress.completedUnitCount = $0.received
      } catch {
        $0.error = error
        dataTask.cancel()
      }
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let result = state.withLock { state -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
      var failure = state.error ?? error
      do { try state.handle?.close() } catch { failure = failure ?? error }
      state.handle = nil
      if failure == nil && state.received != size { failure = URLError(.badServerResponse) }
      if state.cancelled { failure = CancellationError() }
      let continuation = state.continuation
      state.continuation = nil
      state.task = nil
      return (continuation, failure)
    }
    if let error = result.1 { result.0?.resume(throwing: error) } else { result.0?.resume() }
  }
}
