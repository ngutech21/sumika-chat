import Foundation

public protocol MCPServersStoring: Sendable {
  func servers() async -> [MCPServerConfig]
  func save(servers: [MCPServerConfig]) async throws
}

private enum MCPServersFileCodingKeys: String, CodingKey {
  case servers
}

public actor MCPServersStore: MCPServersStoring {
  private struct ServersFile: Codable {
    var servers: [MCPServerConfig]

    init(servers: [MCPServerConfig]) {
      self.servers = servers
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: MCPServersFileCodingKeys.self)
      servers = try container.decodeLossyArray([MCPServerConfig].self, forKey: .servers)
    }
  }

  private let settingsURL: URL

  public init(
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "mcp-servers.json", directoryHint: .notDirectory)
  ) {
    self.settingsURL = settingsURL
  }

  public func servers() async -> [MCPServerConfig] {
    readServersFile().servers
  }

  public func save(servers: [MCPServerConfig]) async throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(ServersFile(servers: servers))
    try data.write(to: settingsURL, options: .atomic)
  }

  private func readServersFile() -> ServersFile {
    guard
      let data = try? Data(contentsOf: settingsURL),
      let decoded = try? JSONDecoder().decode(ServersFile.self, from: data)
    else {
      return ServersFile(servers: [])
    }

    return decoded
  }
}
