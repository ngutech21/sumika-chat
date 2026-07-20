import Foundation

package enum SlashCommand: Equatable, Sendable {
  case preview(path: String)
  case show(path: String)
}

/// Static metadata for a slash command, used both for parsing and to drive the
/// composer autocomplete suggestions.
package struct SlashCommandDescriptor: Equatable, Sendable, Identifiable {
  package let name: String
  package let summary: String
  package let argumentHint: String?

  package init(name: String, summary: String, argumentHint: String?) {
    self.name = name
    self.summary = summary
    self.argumentHint = argumentHint
  }

  package var id: String { name }

  /// The full command token as typed, e.g. `/show`.
  package var token: String { "/" + name }

  /// A one-line usage hint, e.g. `Usage: /show <path>`.
  package var usage: String {
    guard let argumentHint else {
      return "Usage: \(token)"
    }
    return "Usage: \(token) \(argumentHint)"
  }
}

package enum SlashCommandRegistry {
  package static let all: [SlashCommandDescriptor] = [
    SlashCommandDescriptor(
      name: "show",
      summary: "Show a file locally without adding it to the model context",
      argumentHint: "<path>"
    ),
    SlashCommandDescriptor(
      name: "preview",
      summary: "Preview an HTML file in a live browser pane",
      argumentHint: "<path-to-html-file>"
    ),
  ]

  /// Commands whose name starts with `prefix` (case-insensitive). An empty
  /// prefix returns every command.
  package static func matching(prefix: String) -> [SlashCommandDescriptor] {
    guard !prefix.isEmpty else {
      return all
    }
    let lowered = prefix.lowercased()
    return all.filter { $0.name.lowercased().hasPrefix(lowered) }
  }

  /// The command whose name exactly equals `name` (case-insensitive).
  package static func descriptor(named name: String) -> SlashCommandDescriptor? {
    let lowered = name.lowercased()
    return all.first { $0.name.lowercased() == lowered }
  }
}

package struct SlashCommandParser: Sendable {
  package init() {}

  package func parse(_ input: String) -> SlashCommand? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else {
      return nil
    }

    let withoutSlash = trimmed.dropFirst()
    let name = String(withoutSlash.prefix { !$0.isWhitespace })
    guard let descriptor = SlashCommandRegistry.descriptor(named: name) else {
      return nil
    }

    let argument =
      withoutSlash
      .dropFirst(name.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return command(for: descriptor, argument: argument)
  }

  private func command(for descriptor: SlashCommandDescriptor, argument: String) -> SlashCommand? {
    guard !argument.isEmpty else {
      return nil
    }

    switch descriptor.name {
    case "show":
      return .show(path: argument)
    case "preview":
      return .preview(path: argument)
    default:
      return nil
    }
  }
}
