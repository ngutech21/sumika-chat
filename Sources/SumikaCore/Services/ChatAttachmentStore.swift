import Crypto
import Foundation

public struct ChatAttachmentStore: Sendable {
  public let baseURL: URL

  public init(baseURL: URL = LocalAttachmentDirectory.defaultBaseURL) {
    self.baseURL = baseURL
  }

  public func storeFile(
    from sourceURL: URL,
    id: AttachmentID,
    displayName: String
  ) throws -> URL {
    let fileManager = FileManager.default
    let directoryURL = directoryURL(for: id)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let destinationURL = directoryURL.appending(
      path: storedFileName(for: displayName),
      directoryHint: .notDirectory
    )
    if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  public func localURL(for id: AttachmentID) throws -> URL {
    let fileManager = FileManager.default
    let directoryURL = directoryURL(for: id)
    let fileURLs = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    let storedFileURL = try fileURLs.first { url in
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      return values.isRegularFile == true
    }
    guard let storedFileURL else {
      throw ChatAttachmentError.missingStoredAttachment(id.uuidString)
    }
    return storedFileURL
  }

  public func validateStoredFile(for attachment: ChatAttachment) throws -> URL {
    let localURL = try localURL(for: attachment.id)
    let data = try Data(contentsOf: localURL)
    guard Self.contentSHA256(for: data) == attachment.contentSHA256 else {
      throw ChatAttachmentError.changedStoredAttachment(attachment.displayName)
    }
    return localURL
  }

  public func directoryURL(for id: AttachmentID) -> URL {
    baseURL.appending(path: id.uuidString, directoryHint: .isDirectory)
  }

  public static func contentSHA256(for data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func storedFileName(for displayName: String) -> String {
    let sanitized =
      displayName
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "attachment" : sanitized
  }
}
