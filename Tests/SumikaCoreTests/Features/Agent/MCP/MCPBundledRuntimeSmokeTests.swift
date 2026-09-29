import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

/// Explicit opt-in only: exercises an app's helper with fresh private Python/package storage.
@Suite(TemporaryDirectoryTrait(named: "sumika-bundled-uv-smoke"))
struct MCPBundledRuntimeSmokeTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SUMIKA_TEST_BUNDLED_UV"] != nil))
  func coldOfflineFailureThenDownloadAndCachedOfflineRestart() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["SUMIKA_TEST_BUNDLED_UV"])
    let root = try scopedTemporaryDirectory()
    let runtime = MCPRuntimeConfiguration(
      uvExecutableURL: URL(filePath: path), dataDirectoryURL: root.appending(path: "data"),
      cacheDirectoryURL: root.appending(path: "cache"))

    func connection(offline: Bool) -> MCPServerConnection {
      MCPServerConnection(
        config: MCPServerConfig(
          name: "Fetch smoke", command: "uvx",
          arguments: [
            // This server predates the Python SDK's incompatible v2 error names.
            "--python", "3.12", "--with", "mcp==1.26.0",
            "--from", "mcp-server-fetch==2025.4.7", "mcp-server-fetch",
          ],
          environment: ["UV_NO_CONFIG": "1", "UV_OFFLINE": offline ? "1" : "0"]),
        workspaceRootURL: root, baseEnvironment: ["PATH": "/usr/bin:/bin"],
        pathPrefixDirectories: [], runtimeConfiguration: runtime)
    }

    let cold = connection(offline: true)
    await #expect(throws: (any Error).self) { try await cold.start() }
    await cold.shutdown()
    for offline in [false, true] {
      let server = connection(offline: offline)
      let tools = try await server.start()
      #expect(tools.contains { $0.name == "fetch" })
      await server.shutdown()
    }
  }
}
