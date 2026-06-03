import Foundation
import Testing

@testable import LocalCoderCore

struct ChatAttachmentLoaderTests {
  @Test
  func loadAttachmentsReadsUTF8TextFiles() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("let value = 1", to: "Source.swift")

    let attachments = try loader.loadAttachments(from: [fileURL], existingAttachments: [])

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.displayName == "Source.swift")
    #expect(attachment.displayPath == fileURL.path(percentEncoded: false))
    #expect(attachment.kind == .text)
    #expect(attachment.content == "let value = 1")
  }

  @Test
  func loadAttachmentsRejectsUnsupportedExtensions() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("binary", to: "image.png")

    do {
      _ = try loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected unsupported file type error")
    } catch ChatAttachmentError.unsupportedFileType(let name) {
      #expect(name == "image.png")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsRejectsFilesOverTheSizeLimit() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write(
      Data(repeating: 0x61, count: ChatAttachmentLimits.maxTextFileBytes + 1),
      to: "large.txt"
    )

    do {
      _ = try loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected file too large error")
    } catch ChatAttachmentError.fileTooLarge(let name, let limit) {
      #expect(name == "large.txt")
      #expect(limit == ChatAttachmentLimits.maxTextFileBytes)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsRejectsInvalidUTF8() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write(Data([0xff, 0xfe, 0xfd]), to: "binary.txt")

    do {
      _ = try loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected unreadable text error")
    } catch ChatAttachmentError.unreadableText(let name) {
      #expect(name == "binary.txt")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsSkipsExistingAttachmentPaths() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("first", to: "README.md")
    let existing = ChatAttachment(
      url: fileURL,
      displayName: "README.md",
      kind: .text,
      content: "already attached"
    )

    let attachments = try loader.loadAttachments(from: [fileURL], existingAttachments: [existing])

    #expect(attachments.isEmpty)
  }

  @Test
  func loadAttachmentsRejectsRequestsOverTheRemainingSlotLimit() throws {
    let loader = ChatAttachmentLoader()
    let urls = (0...ChatAttachmentLimits.maxAttachmentCount).map {
      URL(filePath: "/tmp/file-\($0).swift")
    }

    do {
      _ = try loader.loadAttachments(from: urls, existingAttachments: [])
      Issue.record("Expected too many files error")
    } catch ChatAttachmentError.tooManyFiles(let limit) {
      #expect(limit == ChatAttachmentLimits.maxAttachmentCount)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func extractDroppedAttachmentsFindsAbsoluteAndFileURLPaths() throws {
    let loader = ChatAttachmentLoader()
    let absoluteURL = try write("absolute", to: "Absolute.swift")
    let fileURL = try write("file url", to: "README.md")
    let draft = """
      Please inspect \(absoluteURL.path(percentEncoded: false)) and \(fileURL.absoluteString)
      before answering.
      """

    let extraction = loader.extractDroppedAttachments(from: draft)
    let extractedPaths = extraction.urls.map { $0.path(percentEncoded: false) }

    #expect(
      extractedPaths == [
        absoluteURL.path(percentEncoded: false),
        fileURL.path(percentEncoded: false),
      ])
    #expect(extraction.cleanedDraft == "Please inspect and\nbefore answering.")
  }

  @Test
  func extractDroppedAttachmentsNormalizesDraftAfterRemovingPaths() throws {
    let loader = ChatAttachmentLoader()
    let firstURL = try write("first", to: "First.swift")
    let secondURL = try write("second", to: "Second.swift")
    let draft =
      "  Use \(firstURL.path(percentEncoded: false))  \n \(secondURL.path(percentEncoded: false)) please  "

    let extraction = loader.extractDroppedAttachments(from: draft)

    #expect(extraction.urls.count == 2)
    #expect(extraction.cleanedDraft == "Use \n please")
  }

  @Test
  func extractDroppedAttachmentsKeepsMissingAndUnsupportedPathsInDraft() throws {
    let loader = ChatAttachmentLoader()
    let rootURL = try makeTemporaryDirectory()
    let missingSupportedPath = rootURL.appending(path: "Missing.swift").path(percentEncoded: false)
    let unsupportedURL = try write("not supported", to: "image.png")
    let draft = "Review \(missingSupportedPath) and \(unsupportedURL.path(percentEncoded: false))"

    let extraction = loader.extractDroppedAttachments(from: draft)

    #expect(extraction.urls.isEmpty)
    #expect(extraction.cleanedDraft == draft)
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
    let url = FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(filePath: Workspace.normalizedPath(for: url))
  }
}
