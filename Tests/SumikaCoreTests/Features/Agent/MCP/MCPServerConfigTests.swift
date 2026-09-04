import Foundation
import SumikaTestSupport
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

@Suite(TemporaryDirectoryTrait(named: "sumika-mcp-store-tests"))
struct MCPServersStoreTests {
  private func makeStore() throws -> (MCPServersStore, URL) {
    let directory = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let url = directory.appending(path: "mcp-servers.json", directoryHint: .notDirectory)
    return (MCPServersStore(settingsURL: url), url)
  }

  @Test
  func loadReturnsEmptyListWhenFileIsMissing() async throws {
    let (store, _) = try makeStore()

    let servers = try await store.load()

    #expect(servers.isEmpty)
  }

  @Test
  func saveAndLoadRoundTripsServers() async throws {
    let (store, _) = try makeStore()
    let configs = [
      MCPServerConfig(name: "everything", command: "npx", arguments: ["-y", "server"]),
      MCPServerConfig(name: "local", command: "/usr/local/bin/mcp-local", isEnabled: false),
    ]

    try await store.save(servers: configs)
    let loaded = try await store.load()

    #expect(loaded == configs)
  }

  @Test
  func loadMigratesUnversionedServersFileToVersionOne() async throws {
    let (store, url) = try makeStore()
    try write(
      """
      {
        "servers": [
          {
            "id": "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902",
            "name": "legacy",
            "transport": {
              "type": "stdio",
              "command": "npx",
              "arguments": ["-y", "server"],
              "environment": {"TOKEN": "secret"}
            },
            "isEnabled": false
          }
        ]
      }
      """,
      to: url
    )

    let servers = try await store.load()

    #expect(
      servers == [
        MCPServerConfig(
          id: try #require(UUID(uuidString: "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902")),
          name: "legacy",
          command: "npx",
          arguments: ["-y", "server"],
          environment: ["TOKEN": "secret"],
          isEnabled: false
        )
      ]
    )
    let migrated = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    #expect(migrated["schemaVersion"] as? Int == 1)
    #expect((migrated["servers"] as? [[String: Any]])?.count == 1)
  }

  @Test
  func loadAcceptsCurrentVersionWithoutRewritingIt() async throws {
    let (store, url) = try makeStore()
    let current = """
      {
        "schemaVersion": 1,
        "servers": [
          {
            "id": "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902",
            "name": "remote",
            "transport": {
              "type": "streamableHTTP",
              "endpoint": "https://mcp.example.com/service"
            },
            "isEnabled": true
          }
        ]
      }
      """
    try write(current, to: url)
    let originalData = try Data(contentsOf: url)

    let servers = try await store.load()

    #expect(servers.count == 1)
    #expect(servers.first?.name == "remote")
    #expect(try Data(contentsOf: url) == originalData)
  }

  @Test
  func loadRejectsCorruptEntryWithoutDroppingItOrRewritingFile() async throws {
    let (store, url) = try makeStore()
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
    try write(json, to: url)
    let originalData = try Data(contentsOf: url)

    await #expect(
      throws: VersionedJSONFileError.decodeFailed(
        fileName: "mcp-servers.json",
        schemaVersion: 0
      )
    ) {
      try await store.load()
    }
    #expect(try Data(contentsOf: url) == originalData)
  }

  @Test
  func loadRejectsFutureVersionWithoutRewritingFile() async throws {
    let (store, url) = try makeStore()
    let json = """
      {
        "schemaVersion": 2,
        "servers": []
      }
      """
    try write(json, to: url)
    let originalData = try Data(contentsOf: url)

    await #expect(
      throws: VersionedJSONFileError.unsupportedSchemaVersion(
        fileName: "mcp-servers.json",
        found: 2,
        current: 1
      )
    ) {
      try await store.load()
    }
    #expect(try Data(contentsOf: url) == originalData)
  }

  @Test
  func loadRejectsFormerFlatServersFileSchema() async throws {
    let (store, url) = try makeStore()
    let json = """
      {
        "id": "6F1B4E86-3A6C-4E5E-9C61-27FBA9D9A902",
        "name": "everything",
        "command": "npx",
        "isEnabled": true
      }
      """
    try write(json, to: url)

    await #expect(throws: VersionedJSONFileError.self) {
      try await store.load()
    }
  }

  private func write(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(json.utf8).write(to: url)
  }
}
