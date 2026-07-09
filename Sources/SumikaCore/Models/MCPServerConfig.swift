import Foundation

/// User-configured external MCP server launched over stdio.
///
/// v1 scope: stdio transport only. The command is resolved through the same
/// PATH conventions as `run_command`; environment values are stored as plain
/// text next to the other JSON settings stores.
public struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var command: String
  public var arguments: [String]
  public var environment: [String: String]
  public var isEnabled: Bool

  public init(
    id: UUID = UUID(),
    name: String,
    command: String,
    arguments: [String] = [],
    environment: [String: String] = [:],
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.arguments = arguments
    self.environment = environment
    self.isEnabled = isEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case command
    case arguments
    case environment
    case isEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    command = try container.decode(String.self, forKey: .command)
    arguments = try container.decodeIfPresent([String].self, forKey: .arguments, default: [])
    environment = try container.decodeIfPresent(
      [String: String].self, forKey: .environment, default: [:])
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled, default: true)
  }

  /// Stable namespace component for qualified tool names (`mcp__<slug>__<tool>`).
  ///
  /// Lowercased, non-alphanumeric runs collapse to a single underscore. Falls
  /// back to `server` for names without alphanumeric characters. Uniqueness
  /// across configured servers is enforced where tool names are composed, not
  /// here.
  public var slug: String {
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
