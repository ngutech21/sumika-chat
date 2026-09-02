import Foundation
import SumikaTestSupport
import Synchronization
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-attachment-loader-tests"))
struct ChatAttachmentLoaderTests {
  @Test
  func loadAttachmentsConvertsDOCXToMarkdownAndStoresOriginalBytes() async throws {
    let documentData = Data("DOCX fixture bytes".utf8)
    let markdown = "# Converted document\n\nKnown body text."
    let converter = RecordingDocumentMarkdownConverter(markdown: markdown)
    let attachmentStore = ChatAttachmentStore(
      baseURL: try makeTemporaryDirectory().appending(path: "attachments")
    )
    let loader = ChatAttachmentLoader(
      attachmentStore: attachmentStore,
      documentMarkdownConverter: converter
    )
    let fileURL = try write(documentData, to: "Report.DOCX")

    let attachments = try await loader.loadAttachments(
      from: [fileURL],
      existingAttachments: []
    )

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.displayName == "Report.DOCX")
    #expect(attachment.kind == .text)
    #expect(attachment.content == markdown)
    #expect(attachment.byteSize == documentData.count)
    #expect(
      attachment.contentSHA256 == ChatAttachmentStore.contentSHA256(for: documentData)
    )
    #expect(try Data(contentsOf: attachmentStore.localURL(for: attachment.id)) == documentData)
    #expect(await converter.requests == [documentData])
  }

  @Test
  func loadAttachmentsRejectsDOCXWithoutDocumentConverter() async throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write(Data("DOCX fixture bytes".utf8), to: "Report.docx")

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected unsupported file type error")
    } catch ChatAttachmentError.unsupportedFileType(let name) {
      #expect(name == "Report.docx")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsRejectsDOCXOverTheSourceSizeLimitBeforeConversion() async throws {
    let converter = RecordingDocumentMarkdownConverter(markdown: "unused")
    let loader = ChatAttachmentLoader(documentMarkdownConverter: converter)
    let fileURL = try write(
      Data(repeating: 0x61, count: ChatAttachmentLimits.maxDocumentFileBytes + 1),
      to: "large.docx"
    )

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected document file too large error")
    } catch ChatAttachmentError.fileTooLarge(let name, let limit) {
      #expect(name == "large.docx")
      #expect(limit == ChatAttachmentLimits.maxDocumentFileBytes)
      #expect(await converter.requests.isEmpty)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsRejectsDocumentWhenSourceSizeIsUnavailableBeforeReading() async throws {
    let didReadData = LockedBoolean()
    let converter = RecordingDocumentMarkdownConverter(markdown: "unused")
    let loader = ChatAttachmentLoader(
      documentMarkdownConverter: converter,
      fileAccess: AttachmentFileAccess(
        startAccessingSecurityScopedResource: { _ in true },
        stopAccessingSecurityScopedResource: { _ in },
        fileSize: { _ in nil },
        readData: { _ in
          didReadData.setTrue()
          return Data("must not be read".utf8)
        }
      )
    )
    let fileURL = URL(filePath: "/tmp/unknown-size.docx")

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected unavailable file size error")
    } catch ChatAttachmentError.fileSizeUnavailable(let name) {
      #expect(name == "unknown-size.docx")
      #expect(!didReadData.value)
      #expect(await converter.requests.isEmpty)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsEndsSecurityScopeBeforeDocumentConversion() async throws {
    let documentData = Data("DOCX fixture bytes".utf8)
    let scopeRecorder = SecurityScopeRecorder()
    let loader = ChatAttachmentLoader(
      attachmentStore: ChatAttachmentStore(
        baseURL: try makeTemporaryDirectory().appending(path: "attachments")
      ),
      documentMarkdownConverter: ScopeCheckingDocumentConverter(
        recorder: scopeRecorder
      ),
      fileAccess: AttachmentFileAccess(
        startAccessingSecurityScopedResource: { _ in
          scopeRecorder.recordStart()
          return true
        },
        stopAccessingSecurityScopedResource: { _ in
          scopeRecorder.recordStop()
        },
        fileSize: { _ in
          scopeRecorder.recordFileSizeRead()
          return documentData.count
        },
        readData: { _ in
          scopeRecorder.recordDataRead()
          return documentData
        }
      )
    )

    let attachments = try await loader.loadAttachments(
      from: [URL(filePath: "/tmp/security-scoped.docx")],
      existingAttachments: []
    )

    #expect(attachments.first?.content == "Converted")
    #expect(
      scopeRecorder.events == [
        .started,
        .fileSizeRead,
        .dataRead,
        .stopped,
        .conversionStarted,
      ]
    )
    #expect(!scopeRecorder.wasActiveDuringConversion)
  }

  @Test
  func loadAttachmentsRejectsConvertedMarkdownOverTheOutputLimit() async throws {
    let markdown = String(
      repeating: "a",
      count: ChatAttachmentLimits.maxConvertedDocumentBytes + 1
    )
    let converter = RecordingDocumentMarkdownConverter(markdown: markdown)
    let attachmentStore = ChatAttachmentStore(
      baseURL: try makeTemporaryDirectory().appending(path: "attachments")
    )
    let loader = ChatAttachmentLoader(
      attachmentStore: attachmentStore,
      documentMarkdownConverter: converter
    )
    let fileURL = try write(Data("DOCX fixture bytes".utf8), to: "large-output.docx")

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected converted document too large error")
    } catch ChatAttachmentError.convertedDocumentTooLarge(let name, let limit) {
      #expect(name == "large-output.docx")
      #expect(limit == ChatAttachmentLimits.maxConvertedDocumentBytes)
      #expect(
        !FileManager.default.fileExists(
          atPath: attachmentStore.baseURL.path(percentEncoded: false)
        )
      )
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsMapsDocumentConversionFailureWithoutStoringAttachment() async throws {
    let converter = RecordingDocumentMarkdownConverter(behavior: .failure)
    let attachmentStore = ChatAttachmentStore(
      baseURL: try makeTemporaryDirectory().appending(path: "attachments")
    )
    let loader = ChatAttachmentLoader(
      attachmentStore: attachmentStore,
      documentMarkdownConverter: converter
    )
    let fileURL = try write(Data("not a DOCX".utf8), to: "broken.docx")

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected document conversion failure")
    } catch ChatAttachmentError.documentConversionFailed(let name) {
      #expect(name == "broken.docx")
      #expect(
        !FileManager.default.fileExists(
          atPath: attachmentStore.baseURL.path(percentEncoded: false)
        )
      )
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsPreservesDocumentConversionCancellation() async throws {
    let converter = RecordingDocumentMarkdownConverter(behavior: .cancellation)
    let loader = ChatAttachmentLoader(documentMarkdownConverter: converter)
    let fileURL = try write(Data("DOCX fixture bytes".utf8), to: "cancelled.docx")

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsDoesNotReturnDocumentCancelledDuringStorage() async throws {
    let writer = BlockingAttachmentFileWriter()
    let attachmentStore = ChatAttachmentStore(
      baseURL: try makeTemporaryDirectory().appending(path: "attachment storage"),
      writeFile: { data, destinationURL in
        try await writer.write(data, to: destinationURL)
      }
    )
    let loader = ChatAttachmentLoader(
      attachmentStore: attachmentStore,
      documentMarkdownConverter: RecordingDocumentMarkdownConverter(markdown: "Converted")
    )
    let fileURL = try write(Data("DOCX fixture bytes".utf8), to: "cancelled-store.docx")

    let loadTask = Task {
      try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
    }
    await writer.waitUntilStarted()
    loadTask.cancel()
    await writer.release()

    do {
      _ = try await loadTask.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      let storedEntries =
        (try? FileManager.default.contentsOfDirectory(
          at: attachmentStore.baseURL,
          includingPropertiesForKeys: nil
        )) ?? []
      #expect(storedEntries.isEmpty)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsReadsUTF8TextFiles() async throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("let value = 1", to: "Source.swift")

    let attachments = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.displayName == "Source.swift")
    #expect(attachment.kind == .text)
    #expect(attachment.content == "let value = 1")
  }

  @Test
  func loadAttachmentsRejectsUnsupportedExtensions() async throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("binary", to: "image.gif")

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected unsupported file type error")
    } catch ChatAttachmentError.unsupportedFileType(let name) {
      #expect(name == "image.gif")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsReadsSupportedImageFilesWithoutBinaryContent() async throws {
    let loader = ChatAttachmentLoader()
    let imageData = try tinyPNGData()
    let fileURL = try write(imageData, to: "screenshot.png")

    let attachments = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.displayName == "screenshot.png")
    #expect(attachment.kind == .image)
    #expect(attachment.content.contains("Image attachment: screenshot.png"))
    #expect(!attachment.content.contains("iVBOR"))
    #expect(attachment.mimeType == "image/png")
    #expect(attachment.byteSize == imageData.count)
    #expect(!attachment.contentSHA256.isEmpty)
    guard case .image(let payload) = attachment.payload else {
      Issue.record("Expected image payload.")
      return
    }
    #expect(payload.mimeType == "image/png")
    #expect(payload.byteSize == imageData.count)
    #expect(!payload.contentSHA256.isEmpty)
    let storedURL = try ChatAttachmentStore().localURL(for: attachment.id)
    #expect(try Data(contentsOf: storedURL) == imageData)
  }

  @Test
  func loadAttachmentsAcceptsJPEGAndWebPExtensionsWhenImageDataIsReadable() async throws {
    let loader = ChatAttachmentLoader()
    let jpegURL = try write(try tinyPNGData(), to: "mock.jpg")
    let webpURL = try write(try tinyPNGData(), to: "mock.webp")

    let attachments = try await loader.loadAttachments(
      from: [jpegURL, webpURL],
      existingAttachments: []
    )

    #expect(attachments.map(\.kind) == [.image, .image])
    #expect(attachments.map(\.mimeType) == ["image/jpeg", "image/webp"])
  }

  @Test
  func loadAttachmentsRejectsFilesOverTheSizeLimit() async throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write(
      Data(repeating: 0x61, count: ChatAttachmentLimits.maxTextFileBytes + 1),
      to: "large.txt"
    )

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected file too large error")
    } catch ChatAttachmentError.fileTooLarge(let name, let limit) {
      #expect(name == "large.txt")
      #expect(limit == ChatAttachmentLimits.maxTextFileBytes)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsRejectsImagesOverTheImageSizeLimit() async throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write(
      Data(repeating: 0x89, count: ChatAttachmentLimits.maxImageFileBytes + 1),
      to: "large.png"
    )

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected image file too large error")
    } catch ChatAttachmentError.fileTooLarge(let name, let limit) {
      #expect(name == "large.png")
      #expect(limit == ChatAttachmentLimits.maxImageFileBytes)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsRejectsInvalidUTF8() async throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write(Data([0xff, 0xfe, 0xfd]), to: "binary.txt")

    do {
      _ = try await loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected unreadable text error")
    } catch ChatAttachmentError.unreadableText(let name) {
      #expect(name == "binary.txt")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsSkipsExistingAttachmentPaths() async throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("first", to: "README.md")
    let existing = makeTextChatAttachment(
      displayName: "README.md",
      content: "already attached"
    )

    let attachments = try await loader.loadAttachments(
      from: [fileURL],
      existingAttachments: [existing]
    )

    #expect(attachments.isEmpty)
  }

  @Test
  func loadAttachmentsRejectsRequestsOverTheRemainingSlotLimit() async throws {
    let loader = ChatAttachmentLoader()
    let urls = (0...ChatAttachmentLimits.maxAttachmentCount).map {
      URL(filePath: "/tmp/file-\($0).swift")
    }

    do {
      _ = try await loader.loadAttachments(from: urls, existingAttachments: [])
      Issue.record("Expected too many files error")
    } catch ChatAttachmentError.tooManyFiles(let limit) {
      #expect(limit == ChatAttachmentLimits.maxAttachmentCount)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private func write(_ content: String, to fileName: String) throws -> URL {
    let data = try #require(content.data(using: .utf8))
    return try write(data, to: fileName)
  }

  private func write(_ data: Data, to fileName: String) throws -> URL {
    let directoryURL = try makeTemporaryDirectory()
    let fileURL = directoryURL.appending(path: fileName, directoryHint: .notDirectory)
    try data.write(to: fileURL)
    return fileURL
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(filePath: Workspace.normalizedPath(for: url))
  }

  private func tinyPNGData() throws -> Data {
    try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      )
    )
  }
}

private enum DocumentConversionBehavior: Sendable {
  case success(String)
  case failure
  case cancellation
}

private actor RecordingDocumentMarkdownConverter: DocumentMarkdownConverting {
  let behavior: DocumentConversionBehavior
  private(set) var requests: [Data] = []

  init(markdown: String) {
    self.behavior = .success(markdown)
  }

  init(behavior: DocumentConversionBehavior) {
    self.behavior = behavior
  }

  func markdown(from data: Data) async throws -> String {
    requests.append(data)
    switch behavior {
    case .success(let markdown):
      return markdown
    case .failure:
      throw DocumentConversionTestError()
    case .cancellation:
      throw CancellationError()
    }
  }
}

private struct DocumentConversionTestError: Error {}

private actor BlockingAttachmentFileWriter {
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func write(_ data: Data, to destinationURL: URL) async throws {
    didStart = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters.removeAll()

    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destinationURL, options: .atomic)
  }

  func waitUntilStarted() async {
    guard !didStart else {
      return
    }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private final class LockedBoolean: Sendable {
  private let storage = Mutex(false)

  var value: Bool {
    storage.withLock { $0 }
  }

  func setTrue() {
    storage.withLock { $0 = true }
  }
}

private enum SecurityScopeEvent: Equatable, Sendable {
  case started
  case fileSizeRead
  case dataRead
  case stopped
  case conversionStarted
}

private final class SecurityScopeRecorder: Sendable {
  private struct State: Sendable {
    var isActive = false
    var events: [SecurityScopeEvent] = []
    var wasActiveDuringConversion = false
  }

  private let storage = Mutex(State())

  var events: [SecurityScopeEvent] {
    storage.withLock { $0.events }
  }

  var wasActiveDuringConversion: Bool {
    storage.withLock { $0.wasActiveDuringConversion }
  }

  func recordStart() {
    storage.withLock {
      $0.isActive = true
      $0.events.append(.started)
    }
  }

  func recordFileSizeRead() {
    storage.withLock { $0.events.append(.fileSizeRead) }
  }

  func recordDataRead() {
    storage.withLock { $0.events.append(.dataRead) }
  }

  func recordStop() {
    storage.withLock {
      $0.isActive = false
      $0.events.append(.stopped)
    }
  }

  func recordConversionStart() {
    storage.withLock {
      $0.wasActiveDuringConversion = $0.isActive
      $0.events.append(.conversionStarted)
    }
  }
}

private struct ScopeCheckingDocumentConverter: DocumentMarkdownConverting {
  let recorder: SecurityScopeRecorder

  func markdown(from data: Data) async throws -> String {
    _ = data
    recorder.recordConversionStart()
    return "Converted"
  }
}
