import Foundation

package struct ChatModelConfiguration: Equatable, Sendable {
  package let localModelDirectory: URL
  package let contextTokenLimit: Int?
  package let supportsImageInput: Bool
  package let reasoningTraceFormat: ReasoningTraceFormat

  package init(
    localModelDirectory: URL,
    contextTokenLimit: Int? = nil,
    supportsImageInput: Bool = false,
    reasoningTraceFormat: ReasoningTraceFormat = .none
  ) {
    self.localModelDirectory = localModelDirectory
    self.contextTokenLimit = contextTokenLimit
    self.supportsImageInput = supportsImageInput
    self.reasoningTraceFormat = reasoningTraceFormat
  }
}

package struct ChatGenerationConfigPreset: Equatable, Sendable {
  package let temperature: Double?
  package let topP: Double?
  package let topK: Int?
  package let repetitionPenalty: Double?

  package init(
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    repetitionPenalty: Double? = nil
  ) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.repetitionPenalty = repetitionPenalty
  }

  package var hasValues: Bool {
    temperature != nil || topP != nil || topK != nil || repetitionPenalty != nil
  }

  package func applying(to settings: ChatGenerationSettings) -> ChatGenerationSettings {
    var updated = settings
    if let temperature {
      updated.temperature = temperature
    }
    if let topP {
      updated.topP = topP
    }
    if let topK {
      updated.topK = topK
    }
    if let repetitionPenalty {
      updated.repetitionPenalty = repetitionPenalty
    }
    return updated
  }
}

package enum LocalModelDirectory {
  package static var defaultBaseURL: URL {
    let applicationSupportURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]

    return
      applicationSupportURL
      .appending(path: "Sumika", directoryHint: .isDirectory)
      .appending(path: "Models", directoryHint: .isDirectory)
  }

  package static func ensureDefaultBaseDirectoryExists() throws -> URL {
    let url = defaultBaseURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  package static func readContextTokenLimit(from modelDirectory: URL) -> Int? {
    let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    guard
      let data = try? Data(contentsOf: configURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    return contextTokenLimit(in: object)
  }

  package static func readGenerationConfigPreset(
    from modelDirectory: URL
  ) -> ChatGenerationConfigPreset? {
    let configURL = modelDirectory.appending(
      path: "generation_config.json", directoryHint: .notDirectory)
    guard
      let data = try? Data(contentsOf: configURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    let preset = ChatGenerationConfigPreset(
      temperature: doubleValue(for: "temperature", in: object),
      topP: doubleValue(for: "top_p", in: object),
      topK: intValue(for: "top_k", in: object),
      repetitionPenalty: doubleValue(for: "repetition_penalty", in: object)
    )
    return preset.hasValues ? preset : nil
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

  private static func doubleValue(for key: String, in object: [String: Any]) -> Double? {
    if let value = object[key] as? Double {
      return value
    }
    if let value = object[key] as? Int {
      return Double(value)
    }
    return nil
  }

  private static func intValue(for key: String, in object: [String: Any]) -> Int? {
    if let value = object[key] as? Int {
      return value
    }
    if let value = object[key] as? Double {
      return Int(value)
    }
    return nil
  }
}
