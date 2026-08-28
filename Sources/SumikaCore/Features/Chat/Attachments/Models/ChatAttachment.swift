import Foundation

package typealias AttachmentID = UUID

package struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
  package let id: AttachmentID
  package let displayName: String
  package let payload: ChatAttachmentPayload
  package let createdAt: Date

  package init(
    id: AttachmentID = AttachmentID(),
    displayName: String,
    payload: ChatAttachmentPayload,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.displayName = displayName
    self.payload = payload
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case payload
    case createdAt
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(AttachmentID.self, forKey: .id, default: AttachmentID())
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName, default: "")
    payload = try container.decode(ChatAttachmentPayload.self, forKey: .payload)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt, default: Date())
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(payload, forKey: .payload)
    try container.encode(createdAt, forKey: .createdAt)
  }

  package var kind: ChatAttachmentKind {
    payload.kind
  }

  package var content: String {
    switch payload {
    case .text(let textPayload):
      textPayload.content
    case .image(let imagePayload):
      "[Image attachment: \(displayName), \(imagePayload.mimeType), \(imagePayload.byteSize) bytes]"
    }
  }

  package var byteSize: Int {
    payload.byteSize
  }

  package var contentSHA256: String {
    payload.contentSHA256
  }

  /// Stable identity of the attachment bytes, used in cache prefix snapshots.
  /// Falls back to the attachment ID when no content hash was recorded, so two
  /// different attachments can never share a signature.
  package var contentSignature: String {
    contentSHA256.isEmpty ? "attachment:\(id.uuidString)" : "sha256:\(contentSHA256)"
  }

  package var mimeType: String? {
    payload.mimeType
  }

}

package enum ChatAttachmentKind: String, Equatable, Sendable {
  case text
  case image
}

package enum ChatAttachmentPayload: Codable, Equatable, Sendable {
  case text(TextAttachmentPayload)
  case image(ImageAttachmentPayload)

  package var kind: ChatAttachmentKind {
    switch self {
    case .text:
      .text
    case .image:
      .image
    }
  }

  package var byteSize: Int {
    switch self {
    case .text(let payload):
      payload.byteSize
    case .image(let payload):
      payload.byteSize
    }
  }

  package var contentSHA256: String {
    switch self {
    case .text(let payload):
      payload.contentSHA256
    case .image(let payload):
      payload.contentSHA256
    }
  }

  package var mimeType: String? {
    switch self {
    case .text:
      nil
    case .image(let payload):
      payload.mimeType
    }
  }
}

package struct TextAttachmentPayload: Codable, Equatable, Sendable {
  package let content: String
  package let byteSize: Int
  package let contentSHA256: String

  package init(content: String, byteSize: Int, contentSHA256: String) {
    self.content = content
    self.byteSize = byteSize
    self.contentSHA256 = contentSHA256
  }
}

package struct ImageAttachmentPayload: Codable, Equatable, Sendable {
  package let mimeType: String
  package let byteSize: Int
  package let contentSHA256: String

  package init(mimeType: String, byteSize: Int, contentSHA256: String) {
    self.mimeType = mimeType
    self.byteSize = byteSize
    self.contentSHA256 = contentSHA256
  }
}

package enum ChatAttachmentLimits {
  package static let maxTextFileBytes = 256 * 1024
  package static let maxImageFileBytes = 20 * 1024 * 1024
  package static let maxDocumentFileBytes = 8 * 1024 * 1024
  package static let maxConvertedDocumentBytes = 256 * 1024
  package static let maxAttachmentCount = 8

  package static let supportedTextFileExtensions: Set<String> = [
    "c", "cc", "cpp", "css", "csv", "go", "h", "hpp", "html", "java",
    "js", "json", "kt", "log", "md", "mjs", "py", "rb", "rs", "sh",
    "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml",
  ]

  package static let supportedImageFileExtensions: Set<String> = [
    "jpeg", "jpg", "png", "webp",
  ]

  package static let supportedDocumentFileExtensions: Set<String> = ["docx"]
}

package enum ChatAttachmentError: LocalizedError {
  case tooManyFiles(Int)
  case unsupportedFileType(String)
  case fileTooLarge(String, Int)
  case fileSizeUnavailable(String)
  case unreadableText(String)
  case documentConversionFailed(String)
  case convertedDocumentTooLarge(String, Int)
  case missingStoredAttachment(String)
  case changedStoredAttachment(String)

  package var errorDescription: String? {
    switch self {
    case .tooManyFiles(let limit):
      "Attach up to \(limit) files."
    case .unsupportedFileType(let name):
      "\(name) is not a supported attachment."
    case .fileTooLarge(let name, let limit):
      "\(name) is larger than \(limit / 1024) KB."
    case .fileSizeUnavailable(let name):
      "The size of \(name) could not be determined."
    case .unreadableText(let name):
      "\(name) is not valid UTF-8 text."
    case .documentConversionFailed(let name):
      "\(name) could not be converted to text."
    case .convertedDocumentTooLarge(let name, let limit):
      "The converted text for \(name) is larger than \(limit / 1024) KB."
    case .missingStoredAttachment(let name):
      "\(name) is no longer available."
    case .changedStoredAttachment(let name):
      "\(name) changed since it was attached."
    }
  }
}

package enum LocalAttachmentDirectory {
  package static var defaultBaseURL: URL {
    let applicationSupportURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]

    return
      applicationSupportURL
      .appending(path: "Sumika", directoryHint: .isDirectory)
      .appending(path: "Attachments", directoryHint: .isDirectory)
  }
}
