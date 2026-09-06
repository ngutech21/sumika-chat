import Foundation

@testable import SumikaCore

struct DocumentMarkdownConverterStub: DocumentMarkdownConverting {
  var text = "Converted document"

  func markdown(from _: Data) async throws -> String { text }
}
