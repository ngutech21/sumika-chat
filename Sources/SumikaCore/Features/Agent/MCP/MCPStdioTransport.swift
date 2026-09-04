import Foundation
import Logging
import MCP

/// Adapts owned, bounded process I/O to the SDK's message transport boundary.
actor MCPStdioTransport: Transport {
  nonisolated let logger = Logger(
    label: "sumika.mcp.stdio",
    factory: { _ in SwiftLogNoOpLogHandler() }
  )

  private let process: OwnedProcess
  private let onReceiveEnded: @Sendable () -> Void
  private var isConnected = false
  private var outstandingWrites = 0

  init(process: OwnedProcess, onReceiveEnded: @escaping @Sendable () -> Void) {
    self.process = process
    self.onReceiveEnded = onReceiveEnded
  }

  func connect() async throws {
    isConnected = true
  }

  func disconnect() async {
    isConnected = false
    _ = await process.stop(.stopped)
  }

  func send(_ message: Data) async throws {
    guard isConnected else {
      throw MCPError.connectionClosed
    }
    guard message.count <= 8 * 1024 * 1024, outstandingWrites < 2 else {
      isConnected = false
      let detail =
        message.count > 8 * 1024 * 1024
        ? "Outgoing MCP frame exceeds 8 MiB."
        : "Outgoing MCP data exceeds two outstanding writes."
      let failure = OwnedProcess.Failure.resourceLimit(detail)
      _ = await process.stop(.failed(failure))
      throw failure
    }
    outstandingWrites += 1
    defer { outstandingWrites -= 1 }
    var framed = message
    framed.append(0x0A)
    try await process.write(framed)
  }

  func receive() -> AsyncThrowingStream<Data, any Error> {
    // Pull directly from the process's bounded frame queue. A second stream
    // continuation would otherwise introduce another potentially unbounded queue.
    AsyncThrowingStream(unfolding: { [process, onReceiveEnded] in
      do {
        guard let frame = try await process.nextFrame() else {
          throw MCPError.connectionClosed
        }
        return frame
      } catch {
        onReceiveEnded()
        throw error
      }
    })
  }
}
