import Foundation

package protocol DocumentMarkdownConverting: Sendable {
  func markdown(from data: Data) async throws -> String
}

package enum DocumentMarkdownConversionError: Error {
  case needsOCR
}

enum DocumentContentPolicy {
  static let maximumSourceBytes = 64 * 1024 * 1024
  static let maximumMarkdownBytes = 256 * 1024
  static let maximumContentCharacters = 32_000

  // Filename aliases from the pinned AnyDocSwift version. CSV keeps its UTF-8 route.
  static let supportedFileExtensions: Set<String> = [
    "doc", "docx", "docm", "odt", "pdf", "ppt", "pps", "pot", "pptx", "pptm",
    "ppsx", "ppsm", "rtf", "epub", "xlsx", "xlsm", "xlsb", "xls", "ods", "odp",
  ]
}
