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
      .attachments
    let attachment = try #require(attachments.first)
    #expect(attachment.content.contains(expected))
    try await verifyWorkspaceDocument(url: url, expected: attachment.content)
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
      _ = try await loader.loadAttachments(from: [url], existingAttachments: []).attachments
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
      .attachments
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
    ).attachments

    let attachment = try #require(attachments.first)
    #expect(attachments.count == 1)
    #expect(attachment.content.contains("Sumika document conversion"))
    #expect(attachment.content.contains("Known DOCX body text."))
    try await verifyWorkspaceDocument(url: sourceURL, expected: attachment.content)
    #expect(attachment.byteSize == documentData.count)
    #expect(
      attachment.contentSHA256 == ChatAttachmentStore.contentSHA256(for: documentData)
    )
    #expect(try Data(contentsOf: attachmentStore.localURL(for: attachment.id)) == documentData)
  }

  @Test
  func workspaceOCRFailuresReturnNoContent() async throws {
    for name in ["handmade-scanned.pdf", "handmade-mixed.pdf"] {
      let url = try temporaryURL(fileName: name)
      try fixtureData(named: name).write(to: url)
      let workspace = Workspace(name: "Documents", rootURL: url.deletingLastPathComponent())
      let result = await ReadDocumentToolExecutor(converter: AnyDocDocumentMarkdownConverter())
        .run(.init(path: name), context: ToolContext(workspace: workspace))
      #expect(result == .readDocument(.failed(path: .init(rawValue: name), reason: .needsOCR)))
    }
  }

  @Test
  func nativeDocumentDetailsKeepAllConvertedMarkdown() throws {
    let text =
      "BEGIN" + String(repeating: "x", count: 15_990) + "MIDDLE"
      + String(repeating: "y", count: 15_996) + "END"
    let content = try ReadDocumentContent(path: .init(rawValue: "report.pdf"), markdown: text)
    let display = ToolDisplayPayload.documentContent(content)
    #expect(display.nativeOutputTitle == "Converted Markdown")
    #expect(display.nativeOutputText == text)
    #expect(display.nativeAffectedPaths == ["report.pdf"])
    #expect(display.nativeFlags.isEmpty)
    let request = ToolCallRequest.validated(
      raw: .init(
        workspaceID: UUID(), sessionID: UUID(), toolName: .readDocument,
        arguments: ["path": .string("report.pdf")]),
      payload: .readDocument(.init(path: "report.pdf"))
    )
    let record = ToolCallRecord(
      request: request,
      evaluation: .init(decision: .allowed, reason: "test", riskLevel: .low),
      state: .completed(.readDocument(.success(content))))
    let details = NativeToolDetailContent(record: record)
    #expect(details.outputTitle == "Converted Markdown")
    #expect(details.outputText == text)
    #expect(details.affectedPaths == ["report.pdf"])
    #expect(record.transcriptToolCall.nativeHeaderPreview?.text == "report.pdf")
  }

  @Test(arguments: [Data(), Data("malformed document".utf8)])
  func malformedWorkspaceDocumentsReturnOnlyConversionFailure(data: Data) async throws {
    let url = try temporaryURL(fileName: "malformed.pdf")
    try data.write(to: url)
    let workspace = Workspace(name: "Documents", rootURL: url.deletingLastPathComponent())
    let result = await ReadDocumentToolExecutor(converter: AnyDocDocumentMarkdownConverter())
      .run(.init(path: url.lastPathComponent), context: ToolContext(workspace: workspace))
    #expect(
      result
        == .readDocument(
          .failed(path: .init(rawValue: url.lastPathComponent), reason: .conversionFailed)))
  }

  private func verifyWorkspaceDocument(url: URL, expected: String) async throws {
    let workspace = Workspace(name: "Documents", rootURL: url.deletingLastPathComponent())
    let result = await ReadDocumentToolExecutor(converter: AnyDocDocumentMarkdownConverter())
      .run(.init(path: url.lastPathComponent), context: ToolContext(workspace: workspace))
    guard case .readDocument(.success(let content)) = result else {
      Issue.record("Expected successful workspace document conversion: \(result.preview.text)")
      return
    }
    #expect(content.markdown == expected)
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
