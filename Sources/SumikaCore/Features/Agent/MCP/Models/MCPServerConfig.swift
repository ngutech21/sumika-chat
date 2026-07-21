import Foundation

package enum MCPServerTransportConfiguration: Codable, Equatable, Sendable {
  case stdio(
    command: String,
    arguments: [String],
    environment: [String: String]
  )
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

  package init(from decoder: Decoder) throws {
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
      try Self.validateStreamableHTTPEndpoint(endpoint)
      self = .streamableHTTP(endpoint: endpoint)
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .stdio(let command, let arguments, let environment):
      try container.encode(TransportType.stdio, forKey: .type)
      try container.encode(command, forKey: .command)
      try container.encode(arguments, forKey: .arguments)
      try container.encode(environment, forKey: .environment)
    case .streamableHTTP(let endpoint):
      try Self.validateStreamableHTTPEndpoint(endpoint)
      try container.encode(TransportType.streamableHTTP, forKey: .type)
      try container.encode(endpoint, forKey: .endpoint)
    }
  }

  package static func validateStreamableHTTPEndpoint(_ endpoint: URL) throws {
    guard endpoint.user == nil, endpoint.password == nil else {
      throw MCPServerEndpointError.embeddedCredentials
    }
    guard endpoint.fragment == nil else {
      throw MCPServerEndpointError.fragmentNotAllowed
    }
    guard let scheme = endpoint.scheme?.lowercased(), let host = endpoint.host, !host.isEmpty else {
      throw MCPServerEndpointError.invalidURL
    }

    switch scheme {
    case "https":
      return
    case "http" where isLoopbackHost(host):
      return
    case "http":
      throw MCPServerEndpointError.insecureRemoteHTTP
    default:
      throw MCPServerEndpointError.unsupportedScheme
    }
  }

  package static func isLoopbackEndpoint(_ endpoint: URL) -> Bool {
    endpoint.scheme?.lowercased() == "http"
      && endpoint.host.map(isLoopbackHost) == true
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    let normalized = host.lowercased()
    if normalized == "localhost" || normalized == "::1" {
      return true
    }

    let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
      octets.allSatisfy({ octet in
        guard let value = Int(octet) else { return false }
        return (0...255).contains(value)
      })
    else {
      return false
    }
    return octets[0] == "127"
  }
}

package enum MCPServerEndpointError: LocalizedError, Equatable, Sendable {
  case invalidURL
  case unsupportedScheme
  case insecureRemoteHTTP
  case embeddedCredentials
  case fragmentNotAllowed

  package var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Enter an absolute MCP endpoint URL with a host."
    case .unsupportedScheme:
      return "MCP endpoints must use HTTPS, or HTTP for a loopback address."
    case .insecureRemoteHTTP:
      return "Unencrypted HTTP is allowed only for localhost and loopback addresses."
    case .embeddedCredentials:
      return "MCP endpoint URLs must not contain embedded credentials."
    case .fragmentNotAllowed:
      return "MCP endpoint URLs must not contain a fragment."
    }
  }
}

/// User-configured external MCP server using stdio or Streamable HTTP.
package struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
  package var id: UUID
  package var name: String
  package var transport: MCPServerTransportConfiguration
  package var isEnabled: Bool

  package init(
    id: UUID = UUID(),
    name: String,
    transport: MCPServerTransportConfiguration,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.transport = transport
    self.isEnabled = isEnabled
  }

  /// Convenience initializer for local stdio servers.
  package init(
    id: UUID = UUID(),
    name: String,
    command: String,
    arguments: [String] = [],
    environment: [String: String] = [:],
    isEnabled: Bool = true
  ) {
    self.init(
      id: id,
      name: name,
      transport: .stdio(
        command: command,
        arguments: arguments,
        environment: environment
      ),
      isEnabled: isEnabled
    )
  }

  /// Stable namespace component for qualified tool names (`mcp__<slug>__<tool>`).
  ///
  /// Lowercased, non-alphanumeric runs collapse to a single underscore. Falls
  /// back to `server` for names without alphanumeric characters. Uniqueness
  /// across configured servers is enforced where tool names are composed, not
  /// here.
  package var slug: String {
    var result = ""
    var previousWasSeparator = true
    for character in name.lowercased() {
      if character.isLetter || character.isNumber {
        result.append(character)
        previousWasSeparator = false
      } else if !previousWasSeparator {
        result.append("_")
        previousWasSeparator = true
      }
    }
    while result.hasSuffix("_") {
      result.removeLast()
    }
    return result.isEmpty ? "server" : result
  }
}
