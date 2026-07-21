import Foundation

/// Newline-framed text lines from a pipe, delivered as an `AsyncStream`.
///
/// Uses `FileHandle.readabilityHandler` (the same mechanism as the command
/// runner's `PipeDataCollector`) instead of `FileHandle.bytes`, so a silent
/// stream never occupies an executor thread and consuming tasks may stay
/// actor-isolated. Lines keep their arrival order; the stream finishes after
/// the final line once the pipe reaches EOF.
enum PipeLineStream {
  static func lines(from fileHandle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
      let framer = LineFramer()
      fileHandle.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          handle.readabilityHandler = nil
          if let tail = framer.finish() {
            continuation.yield(tail)
          }
          continuation.finish()
          return
        }
        for line in framer.consume(data) {
          continuation.yield(line)
        }
      }
      continuation.onTermination = { _ in
        fileHandle.readabilityHandler = nil
      }
    }
  }

  /// Splits an incoming byte stream into complete `\n`-terminated lines.
  /// `readabilityHandler` invocations are serial per handle; the lock guards
  /// against the terminal `finish()` racing a late handler call.
  private final class LineFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func consume(_ data: Data) -> [String] {
      lock.lock()
      defer { lock.unlock() }
      buffer.append(data)

      var lines: [String] = []
      while let newlineIndex = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.prefix(upTo: newlineIndex)
        buffer.removeSubrange(...newlineIndex)
        lines.append(Self.decoded(lineData))
      }
      return lines
    }

    func finish() -> String? {
      lock.lock()
      defer { lock.unlock() }
      guard !buffer.isEmpty else {
        return nil
      }
      let tail = Self.decoded(buffer)
      buffer.removeAll()
      return tail
    }

    private static func decoded(_ data: Data) -> String {
      String(data: data, encoding: .utf8) ?? ""
    }
  }
}
