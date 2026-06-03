import Foundation

public struct ChatModelConfiguration: Equatable, Sendable {
  public let localModelDirectory: URL
  public let contextTokenLimit: Int?

  public init(localModelDirectory: URL, contextTokenLimit: Int? = nil) {
    self.localModelDirectory = localModelDirectory
    self.contextTokenLimit = contextTokenLimit
  }

  public var displayPath: String {
    localModelDirectory.path(percentEncoded: false)
  }
}

public enum LocalModelDirectory {
  public static let defaultModelName = ManagedModelCatalog.defaultModel.localDirectoryName

  public static var defaultBaseURL: URL {
    let applicationSupportURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]

    return
      applicationSupportURL
      .appending(path: "local-coder", directoryHint: .isDirectory)
      .appending(path: "Models", directoryHint: .isDirectory)
  }

  public static var defaultModelURL: URL {
    defaultBaseURL.appending(path: defaultModelName, directoryHint: .isDirectory)
  }

  public static func ensureDefaultBaseDirectoryExists() throws -> URL {
    let url = defaultBaseURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  public static func readContextTokenLimit(from modelDirectory: URL) -> Int? {
    let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    guard
      let data = try? Data(contentsOf: configURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    return contextTokenLimit(in: object)
  }

  private static func contextTokenLimit(in object: [String: Any]) -> Int? {
    for key in ["max_position_embeddings", "max_seq_len", "seq_length", "n_ctx"] {
      if let value = object[key] as? Int {
        return value
      }

      if let value = object[key] as? Double {
        return Int(value)
      }
    }

    for value in object.values {
      if let nestedObject = value as? [String: Any],
        let nestedLimit = contextTokenLimit(in: nestedObject)
      {
        return nestedLimit
      }
    }

    return nil
  }
}
