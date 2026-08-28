import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaApp
@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-anydoc-converter-tests"))
struct AnyDocDocumentMarkdownConverterTests {
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

  private func fixtureData() throws -> Data {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: "minimal", withExtension: "docx.base64")
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
