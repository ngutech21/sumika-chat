import Foundation
import SumikaCore
import SwiftUI

enum HTMLPreviewConsoleMessageLevel: String, Codable, Equatable, Sendable {
  case log
  case info
  case warn
  case error
  case debug

  var systemImage: String {
    switch self {
    case .log:
      "text.quote"
    case .info:
      "info.circle"
    case .warn:
      "exclamationmark.triangle"
    case .error:
      "xmark.octagon"
    case .debug:
      "ladybug"
    }
  }

  var tint: Color {
    switch self {
    case .log:
      .secondary
    case .info:
      .blue
    case .warn:
      .orange
    case .error:
      .red
    case .debug:
      .purple
    }
  }
}

struct HTMLPreviewConsoleEntry: Identifiable, Equatable, Sendable {
  let id = UUID()
  let level: HTMLPreviewConsoleMessageLevel
  let message: String
  let source: String?
  let line: Int?
  let column: Int?

  var detailText: String? {
    var parts: [String] = []
    if let source, !source.isEmpty {
      parts.append(source)
    }
    if let line {
      parts.append("line \(line)")
    }
    if let column {
      parts.append("column \(column)")
    }
    guard !parts.isEmpty else {
      return nil
    }
    return parts.joined(separator: ", ")
  }
}

struct HTMLPreviewState: Equatable {
  let url: URL
  let readAccessRootURL: URL
  let relativePath: WorkspaceRelativePath

  var title: String {
    url.lastPathComponent
  }
}
