import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

enum BundledOptiQMTPDrafterLoaderError: LocalizedError {
  case invalidConfiguration(String)
  case unsafeMTPFile(String)
  case missingMTPFile(URL)
  case unsupportedQuantization(bits: Int, groupSize: Int, mode: String, prequantized: Bool)
  case incompatibleTarget(String)
  case invalidMTPFile(URL, String)
  case tensorCountMismatch(expected: Int, actual: Int)
  case invalidWeightNamespace(String)
  case weightLoadingFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let detail):
      "Invalid bundled OptiQ MTP configuration: \(detail)"
    case .unsafeMTPFile(let path):
      "Bundled OptiQ MTP file must remain inside the model directory: \(path)"
    case .missingMTPFile(let url):
      "Bundled OptiQ MTP file is missing: \(url.path)"
    case .unsupportedQuantization(let bits, let groupSize, let mode, let prequantized):
      "Unsupported bundled OptiQ MTP quantization: bits=\(bits), group_size=\(groupSize), "
        + "mode=\(mode), prequantized=\(prequantized)"
    case .incompatibleTarget(let type):
      "Bundled OptiQ MTP requires a Qwen 3.5 text or VLM target, got \(type)"
    case .invalidMTPFile(let url, let detail):
      "Invalid bundled OptiQ MTP file at \(url.path): \(detail)"
    case .tensorCountMismatch(let expected, let actual):
      "Bundled OptiQ MTP tensor count mismatch: expected \(expected), got \(actual)"
    case .invalidWeightNamespace(let key):
      "Bundled OptiQ MTP file contains a non-MTP tensor: \(key)"
    case .weightLoadingFailed(let detail):
      "Unable to load bundled OptiQ MTP weights: \(detail)"
    }
  }
}

enum BundledOptiQMTPDrafterLoader {
  static func load(for target: ModelContainer) async throws -> MTPDrafterContainer {
    try Task.checkCancellation()
    let modelDirectory = try await target.modelDirectory
    let configurationURL = modelDirectory.appendingPathComponent("config.json")
    let data = try await readConfiguration(at: configurationURL)
    let configuration = try decodeConfiguration(data)
    try Task.checkCancellation()
    try validateQuantization(configuration.quantization)
    let resolvedModelDirectory = modelDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedMTPURL = try resolveMTPFile(
      configuration.mtpFile,
      modelDirectory: modelDirectory,
      resolvedModelDirectory: resolvedModelDirectory
    )
    let model = try await makeDrafter(configurationData: data, target: target)
    try Task.checkCancellation()
    let (weights, metadata) = try loadMTPWeights(at: resolvedMTPURL)
    try Task.checkCancellation()
    try validateWeights(weights, expectedCount: configuration.mtpTensorCount)

    let sanitizedWeights = model.sanitize(weights: weights, metadata: metadata)
    quantize(model: model) { path, _ in
      sanitizedWeights["\(path).scales"] == nil
        ? nil
        : (groupSize: 64, bits: 4, mode: .affine)
    }

    do {
      try model.update(
        parameters: ModuleParameters.unflattened(sanitizedWeights),
        verify: [.all]
      )
    } catch {
      throw BundledOptiQMTPDrafterLoaderError.weightLoadingFailed(error.localizedDescription)
    }
    try Task.checkCancellation()
    eval(model)
    try Task.checkCancellation()

    return MTPDrafterContainer(
      context: MTPDrafterContext(
        configuration: ModelConfiguration(directory: resolvedModelDirectory),
        model: model
      )
    )
  }

  private static func readConfiguration(at url: URL) async throws -> Data {
    do {
      return try await Task.detached {
        try Data(contentsOf: url)
      }.value
    } catch {
      throw BundledOptiQMTPDrafterLoaderError.invalidConfiguration(
        "Unable to read \(url.lastPathComponent): \(error.localizedDescription)"
      )
    }
  }

  private static func decodeConfiguration(
    _ data: Data
  ) throws -> BundledOptiQMTPConfiguration {
    let configuration: BundledOptiQMTPConfiguration
    do {
      configuration = try JSONDecoder.json5().decode(
        BundledOptiQMTPConfiguration.self,
        from: data
      )
    } catch {
      throw BundledOptiQMTPDrafterLoaderError.invalidConfiguration(
        "Unable to decode config.json: \(error.localizedDescription)"
      )
    }
    guard
      configuration.modelType == "qwen3_5"
        || configuration.modelType == "qwen3_5_moe"
    else {
      throw BundledOptiQMTPDrafterLoaderError.invalidConfiguration(
        "Expected model_type qwen3_5 or qwen3_5_moe, got \(configuration.modelType)"
      )
    }
    return configuration
  }

  private static func validateQuantization(
    _ quantization: BundledOptiQMTPQuantization
  ) throws {
    guard
      quantization.prequantized,
      quantization.bits == 4,
      quantization.groupSize == 64,
      quantization.mode == "affine"
    else {
      throw BundledOptiQMTPDrafterLoaderError.unsupportedQuantization(
        bits: quantization.bits,
        groupSize: quantization.groupSize,
        mode: quantization.mode,
        prequantized: quantization.prequantized
      )
    }
  }

  private static func resolveMTPFile(
    _ mtpFile: String,
    modelDirectory: URL,
    resolvedModelDirectory: URL
  ) throws -> URL {
    guard
      !mtpFile.isEmpty,
      !(mtpFile as NSString).isAbsolutePath,
      !(mtpFile as NSString).pathComponents.contains("..")
    else {
      throw BundledOptiQMTPDrafterLoaderError.unsafeMTPFile(mtpFile)
    }
    let resolvedMTPURL =
      modelDirectory
      .appendingPathComponent(mtpFile)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let modelDirectoryPrefix =
      resolvedModelDirectory.path.hasSuffix("/")
      ? resolvedModelDirectory.path
      : resolvedModelDirectory.path + "/"
    guard resolvedMTPURL.path.hasPrefix(modelDirectoryPrefix) else {
      throw BundledOptiQMTPDrafterLoaderError.unsafeMTPFile(mtpFile)
    }
    guard FileManager.default.fileExists(atPath: resolvedMTPURL.path) else {
      throw BundledOptiQMTPDrafterLoaderError.missingMTPFile(resolvedMTPURL)
    }
    guard resolvedMTPURL.pathExtension == "safetensors" else {
      throw BundledOptiQMTPDrafterLoaderError.invalidMTPFile(
        resolvedMTPURL, "Expected a .safetensors file"
      )
    }
    do {
      guard
        try resolvedMTPURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      else {
        throw BundledOptiQMTPDrafterLoaderError.invalidMTPFile(
          resolvedMTPURL, "Expected a regular file"
        )
      }
    } catch let error as BundledOptiQMTPDrafterLoaderError {
      throw error
    } catch {
      throw BundledOptiQMTPDrafterLoaderError.invalidMTPFile(
        resolvedMTPURL, error.localizedDescription
      )
    }
    return resolvedMTPURL
  }

  private static func makeDrafter(
    configurationData: Data,
    target: ModelContainer
  ) async throws -> any MTPDrafterModel {
    let targetKind = await target.perform { context -> BundledOptiQMTPDrafterTarget in
      switch context.model {
      case is MLXLLM.Qwen35Model:
        .text
      case is MLXVLM.Qwen35:
        .vlm
      default:
        .incompatible(String(reflecting: type(of: context.model)))
      }
    }

    do {
      switch targetKind {
      case .text:
        let configuration = try JSONDecoder.json5().decode(
          MLXLLM.Qwen35Configuration.self,
          from: configurationData
        )
        return MLXLLM.Qwen35MTPDraftModel(configuration, preconvertedNorms: false)
      case .vlm:
        let configuration = try JSONDecoder.json5().decode(
          MLXVLM.Qwen35Configuration.self,
          from: configurationData
        )
        return MLXVLM.Qwen35VLMNextNDraftModel(configuration, preconvertedNorms: false)
      case .incompatible(let type):
        throw BundledOptiQMTPDrafterLoaderError.incompatibleTarget(type)
      }
    } catch let error as BundledOptiQMTPDrafterLoaderError {
      throw error
    } catch {
      throw BundledOptiQMTPDrafterLoaderError.invalidConfiguration(
        "Unable to decode Qwen configuration: \(error.localizedDescription)"
      )
    }
  }

  private static func loadMTPWeights(
    at url: URL
  ) throws -> ([String: MLXArray], [String: String]) {
    do {
      return try loadArraysAndMetadata(url: url)
    } catch {
      throw BundledOptiQMTPDrafterLoaderError.weightLoadingFailed(error.localizedDescription)
    }
  }

  private static func validateWeights(
    _ weights: [String: MLXArray],
    expectedCount: Int?
  ) throws {
    guard !weights.isEmpty else {
      throw BundledOptiQMTPDrafterLoaderError.invalidWeightNamespace("<empty>")
    }
    if let invalidKey = weights.keys.sorted().first(where: { !$0.hasPrefix("mtp.") }) {
      throw BundledOptiQMTPDrafterLoaderError.invalidWeightNamespace(invalidKey)
    }
    if let expectedCount, expectedCount != weights.count {
      throw BundledOptiQMTPDrafterLoaderError.tensorCountMismatch(
        expected: expectedCount,
        actual: weights.count
      )
    }
  }
}

private enum BundledOptiQMTPDrafterTarget: Sendable {
  case text
  case vlm
  case incompatible(String)
}

private struct BundledOptiQMTPConfiguration: Decodable {
  let modelType: String
  let mtpFile: String
  let mtpTensorCount: Int?
  let quantization: BundledOptiQMTPQuantization

  enum CodingKeys: String, CodingKey {
    case modelType = "model_type"
    case mtpFile = "mtp_file"
    case mtpTensorCount = "mtp_tensor_count"
    case quantization = "mtplx_mtp_quantization"
  }
}

private struct BundledOptiQMTPQuantization: Decodable {
  let bits: Int
  let groupSize: Int
  let mode: String
  let prequantized: Bool

  enum CodingKeys: String, CodingKey {
    case bits
    case groupSize = "group_size"
    case mode
    case prequantized
  }
}
