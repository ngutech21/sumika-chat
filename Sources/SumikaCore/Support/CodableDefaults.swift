// Foundation types are used directly; the analyzer compiler log does not attribute them reliably.
// swiftlint:disable:next unused_import
import Foundation
import Synchronization

/// Collects elements that lenient decoding had to drop so callers can surface
/// the loss (log, UI, backups) instead of discarding persisted data silently.
///
/// Install an instance under `CodingUserInfoKey.decodeDiagnostics` in
/// `JSONDecoder.userInfo` before decoding. Decoders without an installed
/// collector behave as before.
public final class DecodeDiagnostics: Sendable {
  public struct DroppedElement: Equatable, Sendable {
    public let typeName: String
    public let codingPath: String
    public let message: String
  }

  private let storage = Mutex<[DroppedElement]>([])

  public init() {}

  public var droppedElements: [DroppedElement] {
    storage.withLock { $0 }
  }

  public var summaries: [String] {
    droppedElements.map { element in
      "\(element.typeName) at \(element.codingPath): \(element.message)"
    }
  }

  static func installed(in decoder: Decoder) -> DecodeDiagnostics? {
    decoder.userInfo[.decodeDiagnostics] as? DecodeDiagnostics
  }

  func recordDrop(elementType: Any.Type, codingPath: [any CodingKey], error: Error) {
    let element = DroppedElement(
      typeName: String(describing: elementType),
      codingPath: codingPath.isEmpty
        ? "<root>" : codingPath.map(\.stringValue).joined(separator: "."),
      message: String(reflecting: error)
    )
    storage.withLock { $0.append(element) }
  }
}

extension CodingUserInfoKey {
  public static var decodeDiagnostics: CodingUserInfoKey {
    guard let key = CodingUserInfoKey(rawValue: "chat.sumika.decode-diagnostics") else {
      preconditionFailure("Static coding user info key must be representable.")
    }
    return key
  }
}

struct LossyDecodable<Element: Decodable>: Decodable {
  let value: Element?

  init(from decoder: Decoder) throws {
    do {
      value = try Element(from: decoder)
    } catch {
      value = nil
      DecodeDiagnostics.installed(in: decoder)?.recordDrop(
        elementType: Element.self,
        codingPath: decoder.codingPath,
        error: error
      )
    }
  }
}

extension KeyedDecodingContainer {
  func decodeIfPresent<T: Decodable>(
    _ type: T.Type,
    forKey key: Key,
    default defaultValue: @autoclosure () -> T
  ) throws -> T {
    try decodeIfPresent(type, forKey: key) ?? defaultValue()
  }

  func decodeLossyArray<Element: Decodable>(
    _: [Element].Type,
    forKey key: Key,
    default defaultValue: @autoclosure () -> [Element] = []
  ) throws -> [Element] {
    guard contains(key) else {
      return defaultValue()
    }
    return try decode([LossyDecodable<Element>].self, forKey: key).compactMap(\.value)
  }
}
