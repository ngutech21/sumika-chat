import Foundation

struct LossyDecodable<Element: Decodable>: Decodable {
  let value: Element?

  init(from decoder: Decoder) throws {
    value = try? Element(from: decoder)
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
    _ type: [Element].Type,
    forKey key: Key,
    default defaultValue: @autoclosure () -> [Element] = []
  ) throws -> [Element] {
    guard contains(key) else {
      return defaultValue()
    }
    return try decode([LossyDecodable<Element>].self, forKey: key).compactMap(\.value)
  }
}
