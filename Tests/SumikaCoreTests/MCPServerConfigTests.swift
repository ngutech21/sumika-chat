import Foundation
import Testing

@testable import SumikaCore

struct MCPServerConfigTests {
  @Test
  func slugCollapsesNonAlphanumericRuns() {
    let config = MCPServerConfig(name: "My GitHub -- Server!", command: "npx")

    #expect(config.slug == "my_github_server")
  }

  @Test
  func slugFallsBackForNonAlphanumericNames() {
    let config = MCPServerConfig(name: "***", command: "npx")

    #expect(config.slug == "server")
  }

  @Test
  func decodingAppliesDefaultsForOptionalFields() throws {
    let json = """
      {
        "id": "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902",
        "name": "everything",
        "command": "npx"
      }
      """

    let config = try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))

    #expect(config.arguments.isEmpty)
    #expect(config.environment.isEmpty)
    #expect(config.isEnabled)
  }

  @Test
  func codableRoundTripPreservesAllFields() throws {
    let config = MCPServerConfig(
      name: "GitHub",
      command: "npx",
      arguments: ["-y", "@modelcontextprotocol/server-github"],
      environment: ["GITHUB_TOKEN": "token-value"],
      isEnabled: false
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)

    #expect(decoded == config)
  }
}

struct MCPServersStoreTests {
  private func makeStore() -> (MCPServersStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "mcp-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let url = directory.appending(path: "mcp-servers.json", directoryHint: .notDirectory)
    return (MCPServersStore(settingsURL: url), url)
  }

  @Test
  func loadReturnsEmptyListWhenFileIsMissing() async {
    let (store, _) = makeStore()

    let servers = await store.servers()

    #expect(servers.isEmpty)
  }

  @Test
  func saveAndLoadRoundTripsServers() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let configs = [
      MCPServerConfig(name: "everything", command: "npx", arguments: ["-y", "server"]),
      MCPServerConfig(name: "local", command: "/usr/local/bin/mcp-local", isEnabled: false),
    ]

    try await store.save(servers: configs)
    let loaded = await store.servers()

    #expect(loaded == configs)
  }

  @Test
  func loadDropsCorruptEntriesInsteadOfFailingEntirely() async throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let json = """
      {
        "servers": [
          {"id": "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902", "name": "ok", "command": "npx"},
          {"name": "missing id and command"}
        ]
      }
      """
    try Data(json.utf8).write(to: url)

    let servers = await store.servers()

    #expect(servers.count == 1)
    #expect(servers.first?.name == "ok")
  }
}
