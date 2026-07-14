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
  func formerFlatStdioSchemaIsNotDecoded() {
    let json = """
      {
        "id": "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902",
        "name": "everything",
        "command": "npx",
        "isEnabled": true
      }
      """

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
    }
  }

  @Test
  func stdioCodableRoundTripPreservesTaggedTransport() throws {
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

    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let transport = try #require(object["transport"] as? [String: Any])
    #expect(transport["type"] as? String == "stdio")
    #expect(transport["command"] as? String == "npx")
    #expect(transport["arguments"] as? [String] == ["-y", "@modelcontextprotocol/server-github"])
    #expect(transport["environment"] as? [String: String] == ["GITHUB_TOKEN": "token-value"])
    #expect(transport["endpoint"] == nil)
  }

  @Test
  func streamableHTTPCodableRoundTripPreservesTaggedTransport() throws {
    let endpoint = try #require(URL(string: "https://mcp.example.com/service"))
    let config = MCPServerConfig(
      name: "Remote",
      transport: .streamableHTTP(endpoint: endpoint)
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)

    #expect(decoded == config)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let transport = try #require(object["transport"] as? [String: Any])
    #expect(transport["type"] as? String == "streamableHTTP")
    #expect(transport["endpoint"] as? String == endpoint.absoluteString)
    #expect(transport["command"] == nil)
  }

  @Test
  func endpointPolicyAcceptsHTTPSAndLoopbackHTTP() throws {
    let endpoints = [
      "https://mcp.example.com/mcp",
      "http://localhost:8080/mcp",
      "http://127.0.0.1:8080/mcp",
      "http://127.42.3.9/mcp",
      "http://[::1]:8080/mcp",
    ]

    for value in endpoints {
      let endpoint = try #require(URL(string: value))
      try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(endpoint)
    }
  }

  @Test
  func endpointPolicyRejectsUnsafeURLs() throws {
    let cases: [(String, MCPServerEndpointError)] = [
      ("http://mcp.example.com/mcp", .insecureRemoteHTTP),
      ("ftp://localhost/mcp", .unsupportedScheme),
      ("https://user:pass@mcp.example.com/mcp", .embeddedCredentials),
      ("https://mcp.example.com/mcp#fragment", .fragmentNotAllowed),
      ("/relative/mcp", .invalidURL),
    ]

    for (value, expectedError) in cases {
      let endpoint = try #require(URL(string: value))
      #expect(throws: expectedError) {
        try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(endpoint)
      }
    }
  }

  @Test
  func onlyHTTPLoopbackEndpointsExposeRoots() throws {
    #expect(
      MCPServerTransportConfiguration.isLoopbackEndpoint(
        try #require(URL(string: "http://localhost:8080/mcp"))
      )
    )
    #expect(
      !MCPServerTransportConfiguration.isLoopbackEndpoint(
        try #require(URL(string: "https://localhost:8443/mcp"))
      )
    )
    #expect(
      !MCPServerTransportConfiguration.isLoopbackEndpoint(
        try #require(URL(string: "https://mcp.example.com/mcp"))
      )
    )
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
          {
            "id": "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902",
            "name": "ok",
            "transport": {
              "type": "stdio",
              "command": "npx",
              "arguments": [],
              "environment": {}
            },
            "isEnabled": true
          },
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
