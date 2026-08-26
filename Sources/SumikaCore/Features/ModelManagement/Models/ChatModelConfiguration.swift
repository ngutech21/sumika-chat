import CoreFoundation
import Foundation

package struct ChatModelConfiguration: Equatable, Sendable {
  package let localModelDirectory: URL
  package let contextTokenLimit: Int?
  package let supportsImageInput: Bool
  package let reasoningTraceFormat: ReasoningTraceFormat
  package let supportsHistoricalReasoningPreservation: Bool
  package let reasoningCapability: ModelReasoningCapability
  package let thinkingBudgetPolicy: ThinkingBudgetPolicy

  package init(
    localModelDirectory: URL,
    contextTokenLimit: Int? = nil,
    supportsImageInput: Bool = false,
    reasoningTraceFormat: ReasoningTraceFormat = .none,
    supportsHistoricalReasoningPreservation: Bool = false,
    reasoningCapability: ModelReasoningCapability = .toggle,
    thinkingBudgetPolicy: ThinkingBudgetPolicy = .unmanaged
  ) {
    self.localModelDirectory = localModelDirectory
    self.contextTokenLimit = contextTokenLimit
    self.supportsImageInput = supportsImageInput
    self.reasoningTraceFormat = reasoningTraceFormat
    self.supportsHistoricalReasoningPreservation = supportsHistoricalReasoningPreservation
    self.reasoningCapability = reasoningCapability
    self.thinkingBudgetPolicy = thinkingBudgetPolicy
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

  static func readGenerationConfigPreset(
    from modelDirectory: URL
  ) -> GenerationSettingsOverride? {
    let configURL = modelDirectory.appending(
      path: "generation_config.json", directoryHint: .notDirectory)
    guard
      let data = try? Data(contentsOf: configURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    let preset = GenerationSettingsOverride(
      temperature: doubleValue(for: "temperature", in: object) { $0 >= 0 },
      topP: doubleValue(for: "top_p", in: object) { (0...1).contains($0) },
      topK: intValue(for: "top_k", in: object) { $0 >= 0 },
      minP: doubleValue(for: "min_p", in: object) { (0...1).contains($0) },
      repetitionPenalty: doubleValue(for: "repetition_penalty", in: object) { $0 > 0 },
      presencePenalty: doubleValue(for: "presence_penalty", in: object) {
        (-2...2).contains($0)
      }
    )
    return preset.hasValues ? preset : nil
  }

  private static func contextTokenLimit(in object: [String: Any]) -> Int? {
    for key in ["max_position_embeddings", "max_seq_len", "seq_length", "n_ctx"] {
      guard let rawValue = object[key], !isBoolean(rawValue) else {
        continue
      }

      if let value = rawValue as? Int {
        return value
      }

      if let value = rawValue as? Double {
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

  private static func doubleValue(
    for key: String,
    in object: [String: Any],
    validating isValid: (Double) -> Bool
  ) -> Double? {
    guard let rawValue = object[key], !isBoolean(rawValue) else {
      return nil
    }
    let value: Double?
    if let double = rawValue as? Double {
      value = double
    } else if let integer = rawValue as? Int {
      value = Double(integer)
    } else {
      value = nil
    }
    guard let value, value.isFinite, isValid(value) else {
      return nil
    }
    return value
  }

  private static func intValue(
    for key: String,
    in object: [String: Any],
    validating isValid: (Int) -> Bool
  ) -> Int? {
    guard let rawValue = object[key], !isBoolean(rawValue) else {
      return nil
    }
    let value: Int?
    if let integer = rawValue as? Int {
      value = integer
    } else if let double = rawValue as? Double, double.isFinite {
      value = Int(exactly: double)
    } else {
      value = nil
    }
    guard let value, isValid(value) else {
      return nil
    }
    return value
  }

  private static func isBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else {
      return false
    }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }
}
