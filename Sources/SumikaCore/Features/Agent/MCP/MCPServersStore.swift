import Foundation

package protocol MCPServersStoring: Sendable {
  func load() async throws -> [MCPServerConfig]
  func save(servers: [MCPServerConfig]) async throws
}

package actor MCPServersStore: MCPServersStoring {
  private let file: VersionedJSONFile<MCPServersFileFormat>

  package init(
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "mcp-servers.json", directoryHint: .notDirectory)
  ) {
    self.file = VersionedJSONFile(fileURL: settingsURL)
  }

  package func load() async throws -> [MCPServerConfig] {
    switch try await file.load() {
    case .missing:
      return []
    case .current(let document):
      return document.servers.map(\.domainConfig)
    case .migrated(let document, fromVersion: _):
      return document.servers.map(\.domainConfig)
    }
  }

  package func save(servers: [MCPServerConfig]) async throws {
    try await file.save(try MCPServersFileV1(servers: servers))
  }
}

private enum MCPServersFileFormat: VersionedJSONFormat {
  typealias CurrentDocument = MCPServersFileV1

  static let currentVersion = 1

  static func decode(_ data: Data, sourceVersion: Int) throws -> CurrentDocument {
    switch sourceVersion {
    case 0:
      let legacy = try JSONDecoder().decode(MCPServersFileV0.self, from: data)
      return MCPServersFileV1(migrating: legacy)
    case currentVersion:
      return try JSONDecoder().decode(CurrentDocument.self, from: data)
    default:
      throw MCPServersFileError.unsupportedSourceVersion(sourceVersion)
    }
  }
}

private enum MCPServersFileError: Error {
  case unsupportedSourceVersion(Int)
}

private struct MCPServersFileV0: Decodable, Sendable {
  var servers: [MCPServerConfigFileV0]
}

private struct MCPServerConfigFileV0: Decodable, Sendable {
  var id: UUID
  var name: String
  var transport: MCPServerTransportFileV0
  var isEnabled: Bool
}

private enum MCPServerTransportFileV0: Decodable, Sendable {
  case stdio(command: String, arguments: [String], environment: [String: String])
  case streamableHTTP(endpoint: URL)

  private enum TransportType: String, Decodable {
    case stdio
    case streamableHTTP
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case command
    case arguments
    case environment
    case endpoint
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(TransportType.self, forKey: .type) {
    case .stdio:
      self = try .stdio(
        command: container.decode(String.self, forKey: .command),
        arguments: container.decode([String].self, forKey: .arguments),
        environment: container.decode([String: String].self, forKey: .environment)
      )
    case .streamableHTTP:
      let endpoint = try container.decode(URL.self, forKey: .endpoint)
      try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(endpoint)
      self = .streamableHTTP(endpoint: endpoint)
    }
  }
}

private struct MCPServersFileV1: Codable, Equatable, Sendable {
  let schemaVersion: Int
  var servers: [MCPServerConfigFileV1]

  init(servers: [MCPServerConfig]) throws {
    schemaVersion = MCPServersFileFormat.currentVersion
    self.servers = try servers.map(MCPServerConfigFileV1.init(config:))
  }

  init(migrating legacy: MCPServersFileV0) {
    schemaVersion = MCPServersFileFormat.currentVersion
    servers = legacy.servers.map(MCPServerConfigFileV1.init(migrating:))
  }
}

private struct MCPServerConfigFileV1: Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var transport: MCPServerTransportFileV1
  var isEnabled: Bool

  init(config: MCPServerConfig) throws {
    id = config.id
    name = config.name
    transport = try MCPServerTransportFileV1(configuration: config.transport)
    isEnabled = config.isEnabled
  }

  init(migrating legacy: MCPServerConfigFileV0) {
    id = legacy.id
    name = legacy.name
    transport = MCPServerTransportFileV1(migrating: legacy.transport)
    isEnabled = legacy.isEnabled
  }

  var domainConfig: MCPServerConfig {
    MCPServerConfig(
      id: id,
      name: name,
      transport: transport.domainConfiguration,
      isEnabled: isEnabled
    )
  }
}

private enum MCPServerTransportFileV1: Codable, Equatable, Sendable {
  case stdio(command: String, arguments: [String], environment: [String: String])
  case streamableHTTP(endpoint: URL)

  private enum TransportType: String, Codable {
    case stdio
    case streamableHTTP
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case command
    case arguments
    case environment
    case endpoint
  }

  init(configuration: MCPServerTransportConfiguration) throws {
    switch configuration {
    case .stdio(let command, let arguments, let environment):
      self = .stdio(command: command, arguments: arguments, environment: environment)
    case .streamableHTTP(let endpoint):
      try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(endpoint)
      self = .streamableHTTP(endpoint: endpoint)
    }
  }

  init(migrating legacy: MCPServerTransportFileV0) {
    switch legacy {
    case .stdio(let command, let arguments, let environment):
      self = .stdio(command: command, arguments: arguments, environment: environment)
    case .streamableHTTP(let endpoint):
      self = .streamableHTTP(endpoint: endpoint)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(TransportType.self, forKey: .type) {
    case .stdio:
      self = try .stdio(
        command: container.decode(String.self, forKey: .command),
        arguments: container.decode([String].self, forKey: .arguments),
        environment: container.decode([String: String].self, forKey: .environment)
      )
    case .streamableHTTP:
      let endpoint = try container.decode(URL.self, forKey: .endpoint)
      try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(endpoint)
      self = .streamableHTTP(endpoint: endpoint)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .stdio(let command, let arguments, let environment):
      try container.encode(TransportType.stdio, forKey: .type)
      try container.encode(command, forKey: .command)
      try container.encode(arguments, forKey: .arguments)
      try container.encode(environment, forKey: .environment)
    case .streamableHTTP(let endpoint):
      try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(endpoint)
      try container.encode(TransportType.streamableHTTP, forKey: .type)
      try container.encode(endpoint, forKey: .endpoint)
    }
  }

  var domainConfiguration: MCPServerTransportConfiguration {
    switch self {
    case .stdio(let command, let arguments, let environment):
      return .stdio(command: command, arguments: arguments, environment: environment)
    case .streamableHTTP(let endpoint):
      return .streamableHTTP(endpoint: endpoint)
    }
  }
}
