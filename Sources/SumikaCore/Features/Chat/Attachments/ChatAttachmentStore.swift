// Crypto is used directly; the analyzer compiler log does not attribute it reliably.
// swiftlint:disable:next unused_import
import Crypto
import Foundation

package struct ChatAttachmentStore: Sendable {
  package let baseURL: URL
  private let writeFile: @Sendable (Data, URL) async throws -> Void

  package init(baseURL: URL = LocalAttachmentDirectory.defaultBaseURL) {
    self.baseURL = baseURL
    self.writeFile = { data, destinationURL in
      try await Self.writeAtomically(data, to: destinationURL)
    }
  }

  init(
    baseURL: URL,
    writeFile: @escaping @Sendable (Data, URL) async throws -> Void
  ) {
    self.baseURL = baseURL
    self.writeFile = writeFile
  }

  package func storeFile(
    data: Data,
    id: AttachmentID,
    displayName: String
  ) async throws -> URL {
    let directoryURL = directoryURL(for: id)
    let destinationURL = directoryURL.appending(
      path: storedFileName(for: displayName),
      directoryHint: .notDirectory
    )

    do {
      try Task.checkCancellation()
      try await writeFile(data, destinationURL)
      try Task.checkCancellation()
      return destinationURL
    } catch {
      await removeStoredFile(at: destinationURL, directoryURL: directoryURL)
      if error is CancellationError {
        throw CancellationError()
      }
      throw error
    }
  }

  package func localURL(for id: AttachmentID) throws -> URL {
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

  package func validateStoredFile(for attachment: ChatAttachment) throws -> URL {
    let localURL = try localURL(for: attachment.id)
    let data = try Data(contentsOf: localURL)
    guard Self.contentSHA256(for: data) == attachment.contentSHA256 else {
      throw ChatAttachmentError.changedStoredAttachment(attachment.displayName)
    }
    return localURL
  }

  package func directoryURL(for id: AttachmentID) -> URL {
    baseURL.appending(path: id.uuidString, directoryHint: .isDirectory)
  }

  package static func contentSHA256(for data: Data) -> String {
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

  private static func writeAtomically(_ data: Data, to destinationURL: URL) async throws {
    let storeTask = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      try FileManager.default.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: destinationURL, options: .atomic)
    }
    try await withTaskCancellationHandler {
      try await storeTask.value
    } onCancel: {
      storeTask.cancel()
    }
  }

  private func removeStoredFile(at destinationURL: URL, directoryURL: URL) async {
    let cleanupTask = Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
        try? fileManager.removeItem(at: destinationURL)
      }
      if let remainingFiles = try? fileManager.contentsOfDirectory(atPath: directoryURL.path()),
        remainingFiles.isEmpty
      {
        try? fileManager.removeItem(at: directoryURL)
      }
    }
    await cleanupTask.value
  }
}
