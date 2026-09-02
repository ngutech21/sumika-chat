import AnyDocSwift
import Foundation
import SumikaCore

nonisolated struct AnyDocDocumentMarkdownConverter: DocumentMarkdownConverting, Sendable {
  private let converter: AnyDocConverter

  init(converter: AnyDocConverter = AnyDocConverter()) {
    self.converter = converter
  }

  func markdown(from data: Data) async throws -> String {
    try await converter.markdown(from: data)
  }
}
