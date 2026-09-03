import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-attachment-budget-tests"))
struct ChatAttachmentContentBudgetTests {
  @Test(arguments: ["a", "e\u{301}", "界"])
  func countsSwiftCharactersAcrossMultipleAdditions(character: String) async throws {
    let store = ChatAttachmentStore(
      baseURL: try scopedTemporaryDirectory().appending(path: "stored"))
    let loader = ChatAttachmentLoader(attachmentStore: store)
    let first = try await loader.loadAttachments(
      from: [try write(String(repeating: character, count: 30_000), name: "first.txt")],
      existingAttachments: []
    )
    let second = try await loader.loadAttachments(
      from: [try write(String(repeating: character, count: 2_000), name: "second.txt")],
      existingAttachments: first
    )
    #expect((first + second).map(\.content).reduce(0) { $0 + $1.count } == 32_000)
    let extraURL = try write(character, name: "extra.txt")
    do {
      _ = try await loader.loadAttachments(from: [extraURL], existingAttachments: first + second)
      Issue.record("Expected character limit rejection")
    } catch ChatAttachmentError.contentTooLarge(let actual, let limit) {
      #expect(actual == 32_001)
      #expect(limit == 32_000)
    }
    let afterRemoval = try await loader.loadAttachments(
      from: [extraURL], existingAttachments: first)
    #expect(afterRemoval.count == 1)
    #expect(try store.validateStoredFile(for: first[0]).lastPathComponent == "first.txt")
  }

  @Test(arguments: [32_000, 32_001])
  func actualMarkdownIncludingTableSyntaxDeterminesAdmission(count: Int) async throws {
    let table = "| Item | Value |\n| --- | --- |\n| Final | ORCHID |\n"
    let markdown = String(repeating: "a", count: count - table.count) + table
    let store = ChatAttachmentStore(
      baseURL: try scopedTemporaryDirectory().appending(path: "stored"))
    let loader = ChatAttachmentLoader(
      attachmentStore: store, documentMarkdownConverter: FixedDocument(markdown: markdown)
    )
    let source = try write("tiny source", name: "table.xlsx")
    do {
      let attachments = try await loader.loadAttachments(from: [source], existingAttachments: [])
      #expect(count == 32_000)
      #expect(attachments.first?.content == markdown)
    } catch ChatAttachmentError.contentTooLarge(let actual, let limit) {
      #expect(count == 32_001)
      #expect(actual == 32_001)
      #expect(limit == 32_000)
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: store.baseURL.path(percentEncoded: false)
        ).isEmpty)
    }
  }

  @Test(arguments: [
    "doc", "DOCX", "docm", "odt", "pdf", "ppt", "pps", "pot", "pptx", "pptm",
    "ppsx", "ppsm", "rtf", "epub", "xlsx", "xlsm", "xlsb", "xls", "ods", "odp",
  ])
  func routesEveryPinnedDocumentAliasThroughTheConverter(fileExtension: String) async throws {
    let store = ChatAttachmentStore(
      baseURL: try scopedTemporaryDirectory().appending(path: "stored"))
    let loader = ChatAttachmentLoader(
      attachmentStore: store, documentMarkdownConverter: FixedDocument(markdown: "converted END")
    )
    let files = try await loader.loadAttachments(
      from: [try write("source bytes", name: "document.\(fileExtension)")], existingAttachments: []
    )
    #expect(files.first?.content == "converted END")
  }

  @Test
  func csvKeepsItsUTF8RouteAndImagesDoNotSpendCharacters() async throws {
    let store = ChatAttachmentStore(
      baseURL: try scopedTemporaryDirectory().appending(path: "stored"))
    let loader = ChatAttachmentLoader(
      attachmentStore: store, documentMarkdownConverter: FixedDocument(markdown: "must not convert")
    )
    let csv = "name,value\nlast,ORCHID\n"
    let contents = csv + String(repeating: " ", count: 32_000 - csv.count)
    let files = try await loader.loadAttachments(
      from: [try write(contents, name: "table.csv"), try write("image bytes", name: "image.png")],
      existingAttachments: []
    )
    #expect(files[0].content == contents)
    #expect(files[1].kind == .image)
  }

  @Test
  func sourceDocumentLargerThanEightMiBFitsWithSmallExtractedText() async throws {
    let store = ChatAttachmentStore(
      baseURL: try scopedTemporaryDirectory().appending(path: "stored"))
    let loader = ChatAttachmentLoader(
      attachmentStore: store, documentMarkdownConverter: FixedDocument(markdown: "small END")
    )
    let source = try scopedTemporaryDirectory().appending(path: "large.pdf")
    try Data(repeating: 0, count: 8 * 1024 * 1024 + 1).write(to: source)
    let files = try await loader.loadAttachments(from: [source], existingAttachments: [])
    #expect(files[0].byteSize == 8 * 1024 * 1024 + 1)
    #expect(files[0].content == "small END")
    #expect(ChatAttachmentLimits.maxDocumentFileBytes == 64 * 1024 * 1024)
  }

  @Test(arguments: [false, true])
  func laterConversionFailureRollsBackEarlierFiles(cancelled: Bool) async throws {
    let store = ChatAttachmentStore(
      baseURL: try scopedTemporaryDirectory().appending(path: "stored"))
    let loader = ChatAttachmentLoader(
      attachmentStore: store, documentMarkdownConverter: FailingDocument(cancelled: cancelled)
    )
    do {
      _ = try await loader.loadAttachments(
        from: [try write("text", name: "first.txt"), try write("scan", name: "scan.pdf")],
        existingAttachments: []
      )
      Issue.record("Expected conversion failure")
    } catch is CancellationError {
      #expect(cancelled)
    } catch ChatAttachmentError.documentNeedsOCR(let name) {
      #expect(!cancelled)
      #expect(name == "scan.pdf")
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: store.baseURL.path(percentEncoded: false))
        .isEmpty)
  }

  private func write(_ text: String, name: String) throws -> URL {
    let url = try scopedTemporaryDirectory().appending(path: name)
    try Data(text.utf8).write(to: url)
    return url
  }
}

private struct FixedDocument: DocumentMarkdownConverting {
  let markdown: String
  func markdown(from _: Data) async throws -> String { markdown }
}

private struct FailingDocument: DocumentMarkdownConverting {
  let cancelled: Bool
  func markdown(from _: Data) async throws -> String {
    if cancelled { throw CancellationError() }
    throw DocumentMarkdownConversionError.needsOCR
  }
}
