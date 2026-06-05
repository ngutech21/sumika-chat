import Foundation

public struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let url: URL
  public let displayName: String
  public let kind: ChatAttachmentKind
  public let content: String

  public init(
    id: UUID = UUID(),
    url: URL,
    displayName: String,
    kind: ChatAttachmentKind,
    content: String
  ) {
    self.id = id
    self.url = url
    self.displayName = displayName
    self.kind = kind
    self.content = content
  }

  public var displayPath: String {
    url.path(percentEncoded: false)
  }
}

public enum ChatAttachmentKind: String, Codable, Equatable, Sendable {
  case text
}

public enum ChatAttachmentLimits {
  public static let maxTextFileBytes = 256 * 1024
  public static let maxAttachmentCount = 8

  public static let supportedTextFileExtensions: Set<String> = [
    "c", "cc", "cpp", "css", "csv", "go", "h", "hpp", "html", "java",
    "js", "json", "kt", "log", "md", "mjs", "py", "rb", "rs", "sh",
    "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml",
  ]
}

public enum ChatAttachmentError: LocalizedError {
  case tooManyFiles(Int)
  case unsupportedFileType(String)
  case fileTooLarge(String, Int)
  case unreadableText(String)

  public var errorDescription: String? {
    switch self {
    case .tooManyFiles(let limit):
      "Attach up to \(limit) files."
    case .unsupportedFileType(let name):
      "\(name) is not a supported text file."
    case .fileTooLarge(let name, let limit):
      "\(name) is larger than \(limit / 1024) KB."
    case .unreadableText(let name):
      "\(name) is not valid UTF-8 text."
    }
  }
}
