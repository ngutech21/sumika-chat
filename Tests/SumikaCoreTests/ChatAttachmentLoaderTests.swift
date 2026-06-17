import Foundation
import Testing

@testable import SumikaCore

struct ChatAttachmentLoaderTests {
  @Test
  func loadAttachmentsReadsUTF8TextFiles() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("let value = 1", to: "Source.swift")

    let attachments = try loader.loadAttachments(from: [fileURL], existingAttachments: [])

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.displayName == "Source.swift")
    #expect(attachment.displayPath == "Source.swift")
    #expect(attachment.kind == .text)
    #expect(attachment.content == "let value = 1")
  }

  @Test
  func loadAttachmentsRejectsUnsupportedExtensions() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write("binary", to: "image.gif")

    do {
      _ = try loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected unsupported file type error")
    } catch ChatAttachmentError.unsupportedFileType(let name) {
      #expect(name == "image.gif")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func loadAttachmentsReadsSupportedImageFilesWithoutBinaryContent() throws {
    let loader = ChatAttachmentLoader()
    let imageData = try tinyPNGData()
    let fileURL = try write(imageData, to: "screenshot.png")

    let attachments = try loader.loadAttachments(from: [fileURL], existingAttachments: [])

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.displayName == "screenshot.png")
    #expect(attachment.kind == .image)
    #expect(attachment.content.contains("Image attachment: screenshot.png"))
    #expect(!attachment.content.contains("iVBOR"))
    #expect(attachment.metadata?.mimeType == "image/png")
    #expect(attachment.metadata?.byteCount == imageData.count)
    #expect(attachment.metadata?.contentSHA256 != nil)
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
  func loadAttachmentsAcceptsJPEGAndWebPExtensionsWhenImageDataIsReadable() throws {
    let loader = ChatAttachmentLoader()
    let jpegURL = try write(try tinyPNGData(), to: "mock.jpg")
    let webpURL = try write(try tinyPNGData(), to: "mock.webp")

    let attachments = try loader.loadAttachments(
      from: [jpegURL, webpURL],
      existingAttachments: []
    )

    #expect(attachments.map(\.kind) == [.image, .image])
    #expect(attachments.map { $0.metadata?.mimeType } == ["image/jpeg", "image/webp"])
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
  func loadAttachmentsRejectsImagesOverTheImageSizeLimit() throws {
    let loader = ChatAttachmentLoader()
    let fileURL = try write(
      Data(repeating: 0x89, count: ChatAttachmentLimits.maxImageFileBytes + 1),
      to: "large.png"
    )

    do {
      _ = try loader.loadAttachments(from: [fileURL], existingAttachments: [])
      Issue.record("Expected image file too large error")
    } catch ChatAttachmentError.fileTooLarge(let name, let limit) {
      #expect(name == "large.png")
      #expect(limit == ChatAttachmentLimits.maxImageFileBytes)
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
      .appending(path: "sumika-chat-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
