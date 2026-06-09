import Foundation

public typealias AttachmentID = UUID

public struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
  public let id: AttachmentID
  public let displayName: String
  public let payload: ChatAttachmentPayload
  public let createdAt: Date

  public init(
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

  public var displayPath: String {
    displayName
  }

  public var kind: ChatAttachmentKind {
    payload.kind
  }

  public var content: String {
    switch payload {
    case .text(let textPayload):
      textPayload.content
    case .image(let imagePayload):
      "[Image attachment: \(displayName), \(imagePayload.mimeType), \(imagePayload.byteSize) bytes]"
    }
  }

  public var byteSize: Int {
    payload.byteSize
  }

  public var contentSHA256: String {
    payload.contentSHA256
  }

  public var mimeType: String? {
    payload.mimeType
  }

  public var metadata: ChatAttachmentMetadata? {
    switch payload {
    case .text(let payload):
      ChatAttachmentMetadata(
        mimeType: nil,
        byteCount: payload.byteSize,
        contentSHA256: payload.contentSHA256
      )
    case .image(let payload):
      ChatAttachmentMetadata(
        mimeType: payload.mimeType,
        byteCount: payload.byteSize,
        contentSHA256: payload.contentSHA256
      )
    }
  }

  public init(
    id: AttachmentID = AttachmentID(),
    url _: URL,
    displayName: String,
    kind: ChatAttachmentKind,
    content: String,
    metadata: ChatAttachmentMetadata? = nil
  ) {
    let payload: ChatAttachmentPayload
    switch kind {
    case .text:
      payload = .text(
        TextAttachmentPayload(
          content: content,
          byteSize: metadata?.byteCount ?? content.utf8.count,
          contentSHA256: metadata?.contentSHA256 ?? ""
        )
      )
    case .image:
      payload = .image(
        ImageAttachmentPayload(
          mimeType: metadata?.mimeType ?? "image",
          byteSize: metadata?.byteCount ?? content.utf8.count,
          contentSHA256: metadata?.contentSHA256 ?? ""
        )
      )
    }
    self.init(id: id, displayName: displayName, payload: payload)
  }
}

public enum ChatAttachmentKind: String, Codable, Equatable, Sendable {
  case text
  case image
}

public enum ChatAttachmentPayload: Codable, Equatable, Sendable {
  case text(TextAttachmentPayload)
  case image(ImageAttachmentPayload)

  public var kind: ChatAttachmentKind {
    switch self {
    case .text:
      .text
    case .image:
      .image
    }
  }

  public var byteSize: Int {
    switch self {
    case .text(let payload):
      payload.byteSize
    case .image(let payload):
      payload.byteSize
    }
  }

  public var contentSHA256: String {
    switch self {
    case .text(let payload):
      payload.contentSHA256
    case .image(let payload):
      payload.contentSHA256
    }
  }

  public var mimeType: String? {
    switch self {
    case .text:
      nil
    case .image(let payload):
      payload.mimeType
    }
  }
}

public struct TextAttachmentPayload: Codable, Equatable, Sendable {
  public let content: String
  public let byteSize: Int
  public let contentSHA256: String

  public init(content: String, byteSize: Int, contentSHA256: String) {
    self.content = content
    self.byteSize = byteSize
    self.contentSHA256 = contentSHA256
  }
}

public struct ImageAttachmentPayload: Codable, Equatable, Sendable {
  public let mimeType: String
  public let byteSize: Int
  public let contentSHA256: String

  public init(mimeType: String, byteSize: Int, contentSHA256: String) {
    self.mimeType = mimeType
    self.byteSize = byteSize
    self.contentSHA256 = contentSHA256
  }
}

public struct ChatAttachmentMetadata: Codable, Equatable, Sendable {
  public let mimeType: String?
  public let byteCount: Int
  public let contentSHA256: String?

  public init(
    mimeType: String?,
    byteCount: Int,
    contentSHA256: String? = nil
  ) {
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.contentSHA256 = contentSHA256
  }

  public var imageSummary: String {
    let type = mimeType ?? "image"
    return "\(type), \(byteCount) bytes"
  }
}

public enum ChatAttachmentLimits {
  public static let maxTextFileBytes = 256 * 1024
  public static let maxImageFileBytes = 10 * 1024 * 1024
  public static let maxAttachmentCount = 8

  public static let supportedTextFileExtensions: Set<String> = [
    "c", "cc", "cpp", "css", "csv", "go", "h", "hpp", "html", "java",
    "js", "json", "kt", "log", "md", "mjs", "py", "rb", "rs", "sh",
    "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml",
  ]

  public static let supportedImageFileExtensions: Set<String> = [
    "jpeg", "jpg", "png", "webp",
  ]

  public static var supportedFileExtensions: Set<String> {
    supportedTextFileExtensions.union(supportedImageFileExtensions)
  }
}

public enum ChatAttachmentError: LocalizedError {
  case tooManyFiles(Int)
  case unsupportedFileType(String)
  case fileTooLarge(String, Int)
  case unreadableText(String)
  case missingStoredAttachment(String)
  case changedStoredAttachment(String)

  public var errorDescription: String? {
    switch self {
    case .tooManyFiles(let limit):
      "Attach up to \(limit) files."
    case .unsupportedFileType(let name):
      "\(name) is not a supported attachment."
    case .fileTooLarge(let name, let limit):
      "\(name) is larger than \(limit / 1024) KB."
    case .unreadableText(let name):
      "\(name) is not valid UTF-8 text."
    case .missingStoredAttachment(let name):
      "\(name) is no longer available."
    case .changedStoredAttachment(let name):
      "\(name) changed since it was attached."
    }
  }
}

public enum LocalAttachmentDirectory {
  public static var defaultBaseURL: URL {
    let applicationSupportURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]

    return
      applicationSupportURL
      .appending(path: "local-coder", directoryHint: .isDirectory)
      .appending(path: "Attachments", directoryHint: .isDirectory)
  }
}

public struct ActiveAttachmentContext: Codable, Equatable, Sendable {
  public var attachmentIDs: [AttachmentID]

  public init(attachmentIDs: [AttachmentID] = []) {
    self.attachmentIDs = attachmentIDs
  }

  public static let empty = ActiveAttachmentContext()

  public mutating func activate(_ attachments: [ChatAttachment]) {
    for attachment in attachments where attachment.kind == .image {
      guard !attachmentIDs.contains(attachment.id) else {
        continue
      }
      attachmentIDs.append(attachment.id)
    }
  }

  public mutating func remove(_ id: AttachmentID) {
    attachmentIDs.removeAll { $0 == id }
  }
}
