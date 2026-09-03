import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaApp
@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-anydoc-converter-tests"))
struct AnyDocDocumentMarkdownConverterTests {
  @Test(arguments: [
    ("text.doc", "Fixture Document"), ("text.odt", "Fixture Document"),
    ("text.pdf", "Fixture Document"), ("pres.ppt", "Deck Title Slide"),
    ("pres.pptx", "Deck Title Slide"), ("text.rtf", "Fixture Document"),
    ("book.epub", "Chapter One"), ("sheet.xlsx", "fifteen and a half"),
    ("handmade-sheet.xlsb", "wide merge"), ("sheet.xls", "fifteen and a half"),
    ("sheet.ods", "fifteen and a half"), ("pres.odp", "Deck Title Slide"),
  ])
  func documentFamiliesConvertLocally(fileName: String, expected: String) async throws {
    let data = try fixtureData(named: fileName)
    let url = try temporaryURL(fileName: fileName)
    try data.write(to: url)
    let store = ChatAttachmentStore(baseURL: try temporaryURL(fileName: "stored"))
    let loader = ChatAttachmentLoader(
      attachmentStore: store, documentMarkdownConverter: AnyDocDocumentMarkdownConverter()
    )
    let attachments = try await loader.loadAttachments(from: [url], existingAttachments: [])
    let attachment = try #require(attachments.first)
    #expect(attachment.content.contains(expected))
    #expect(try Data(contentsOf: store.validateStoredFile(for: attachment)) == data)
  }

  @Test(arguments: ["handmade-scanned.pdf", "handmade-mixed.pdf"])
  func pdfsRequiringOCRRejectTheWholeDocument(fileName: String) async throws {
    let url = try temporaryURL(fileName: fileName)
    try fixtureData(named: fileName).write(to: url)
    let store = ChatAttachmentStore(baseURL: try temporaryURL(fileName: "stored"))
    let loader = ChatAttachmentLoader(
      attachmentStore: store, documentMarkdownConverter: AnyDocDocumentMarkdownConverter()
    )
    do {
      _ = try await loader.loadAttachments(from: [url], existingAttachments: [])
      Issue.record("Expected OCR-required error without partial content")
    } catch ChatAttachmentError.documentNeedsOCR(let name) {
      #expect(name == fileName)
      #expect(
        ChatAttachmentError.documentNeedsOCR(name).localizedDescription.contains("text-based PDF"))
    }
    #expect(!FileManager.default.fileExists(atPath: store.baseURL.path(percentEncoded: false)))
  }

  @Test
  func supportedFilenameDoesNotOverrideContentDetection() async throws {
    let url = try temporaryURL(fileName: "renamed.docx")
    try fixtureData(named: "text.pdf").write(to: url)
    let loader = ChatAttachmentLoader(
      attachmentStore: ChatAttachmentStore(baseURL: try temporaryURL(fileName: "stored")),
      documentMarkdownConverter: AnyDocDocumentMarkdownConverter()
    )
    let attachments = try await loader.loadAttachments(from: [url], existingAttachments: [])
    #expect(attachments.first?.content.contains("Fixture Document") == true)
  }

  @Test
  func docxFixtureConvertsThroughAttachmentLoaderAndStoresOriginalBytes() async throws {
    let documentData = try fixtureData()
    let sourceURL = try temporaryURL(fileName: "minimal.docx")
    try documentData.write(to: sourceURL)
    let attachmentStore = ChatAttachmentStore(
      baseURL: try temporaryURL(fileName: "attachments")
    )
    let loader = ChatAttachmentLoader(
      attachmentStore: attachmentStore,
      documentMarkdownConverter: AnyDocDocumentMarkdownConverter()
    )

    let attachments = try await loader.loadAttachments(
      from: [sourceURL],
      existingAttachments: []
    )

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.content.contains("Sumika document conversion"))
    #expect(attachment.content.contains("Known DOCX body text."))
    #expect(attachment.byteSize == documentData.count)
    #expect(
      attachment.contentSHA256 == ChatAttachmentStore.contentSHA256(for: documentData)
    )
    #expect(try Data(contentsOf: attachmentStore.localURL(for: attachment.id)) == documentData)
  }

  private func fixtureData(named name: String = "minimal.docx") throws -> Data {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: name, withExtension: "base64")
    )
    let encoded = try String(contentsOf: fixtureURL, encoding: .utf8)
    return try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
  }

  private func temporaryURL(fileName: String) throws -> URL {
    let directoryURL = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL.appending(path: fileName, directoryHint: .notDirectory)
  }
}
