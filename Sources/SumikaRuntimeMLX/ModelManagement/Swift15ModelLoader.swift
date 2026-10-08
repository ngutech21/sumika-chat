import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MLXVLM

enum Swift15ModelLoader {
  static func loadIfSupported(
    from directory: URL, using tokenizerLoader: any TokenizerLoader
  ) async throws -> ModelContainer? {
    try Task.checkCancellation()
    let supported = try await Task.detached {
      let url = directory.appending(path: "QUANTIZATION_MANIFEST.json")
      guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        return false
      }
      let data = try Data(contentsOf: url)
      guard let manifest = try? JSONDecoder().decode(Swift15Manifest.self, from: data),
        manifest.sourceRepository == "ukisai/Swift-1.5-Qwen3.8-27b"
      else {
        return false
      }
      guard
        manifest.sourceRevision == "00ccd14e006897d28cb0ed5bf26390e60d274251",
        manifest.architecturePatchSHA256
          == "f6f1d0bdafa45863bfbf93dac0398c481c993ea04fdf38b9bae98c643f89eaec"
      else {
        throw CompatibilityError("Unrecognized source revision or architecture patch.")
      }
      return true
    }.value
    try Task.checkCancellation()
    guard supported else { return nil }

    let registry = ModelTypeRegistry<LanguageModel>(creators: [
      "qwen3_5": { data in
        do {
          let config = try JSONDecoder().decode(Qwen35Configuration.self, from: data)
          try validate(config, data: data)
          return try CheckpointAdapter(config)
        } catch let error as CompatibilityError {
          throw error
        } catch {
          throw CompatibilityError("Invalid configuration: \(error.localizedDescription)")
        }
      }
    ])
    let factory = VLMModelFactory(
      typeRegistry: registry, processorRegistry: VLMProcessorTypeRegistry.shared,
      modelRegistry: VLMRegistry.shared)
    var context = try await factory.load(from: directory, using: tokenizerLoader)
    try Task.checkCancellation()
    guard let adapter = context.model as? CheckpointAdapter else {
      throw CompatibilityError("The checkpoint adapter was not used during loading.")
    }
    context.model = adapter.qwen
    return ModelContainer(context: context)
  }

  private static func validate(_ config: Qwen35Configuration, data: Data) throws {
    let flags = try JSONDecoder().decode(Swift15ExportConfiguration.self, from: data)
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
    let quantization = base.perLayerQuantization?.quantization
    guard
      config.modelType == "qwen3_5", flags.languageModelOnly == false,
      flags.architectures == ["Qwen3_5ForConditionalGeneration"],
      quantization?.mode == .affine, quantization?.bits == 4, quantization?.groupSize == 64,
      base.perLayerQuantization?.perLayerQuantization.isEmpty == true,
      flags.quantizationConfig == quantization
    else {
      throw CompatibilityError(
        "Expected a complete Qwen3.5 export with affine 4-bit/group-64 weights.")
    }
    let text = config.textConfiguration
    let vision = config.visionConfiguration
    guard
      text.modelType == "qwen3_5_text", text.hiddenSize == 5120, text.hiddenLayers == 64,
      text.intermediateSize == 17_408, text.attentionHeads == 24, text.kvHeads == 4,
      text.headDim == 256, text.fullAttentionInterval == 4, text.numExperts == 0,
      text.linearConvKernelDim == 4, text.linearKeyHeadDim == 128,
      text.linearValueHeadDim == 128, text.linearNumKeyHeads == 16,
      text.linearNumValueHeads == 48, text.vocabularySize == 248_320,
      !text.tieWordEmbeddings, !text.attentionBias, text.rmsNormEps == 1e-6,
      text.ropeTheta == 10_000_000, text.partialRotaryFactor == 0.25,
      text.ropeParameters?["mrope_section"]?.asInts() == [11, 11, 10],
      text.ropeParameters?["mrope_interleaved"] == .bool(true),
      vision.modelType == "qwen3_5", vision.depth == 27, vision.hiddenSize == 1152,
      vision.intermediateSize == 4304, vision.outHiddenSize == text.hiddenSize,
      vision.numHeads == 16, vision.patchSize == 16, vision.temporalPatchSize == 2,
      vision.spatialMergeSize == 2, vision.numPositionEmbeddings == 2304,
      vision.inChannels == 3, vision.deepstackVisualIndexes.isEmpty,
      vision.hiddenAct == "gelu_pytorch_tanh",
      config.imageTokenId == 248_056, config.imageTokenIndex == 248_056,
      config.videoTokenId == 248_057, config.videoTokenIndex == 248_057,
      config.visionStartTokenId == 248_053, config.visionEndTokenId == 248_054
    else {
      throw CompatibilityError(
        "The text or vision configuration differs from the supported Swift 1.5 export.")
    }
  }

  // Internal for small checkpoint tests; inference always receives the unwrapped Qwen35.
  final class CheckpointAdapter: Module, LanguageModel {
    @ModuleInfo private(set) var qwen: Qwen35

    init(_ configuration: Qwen35Configuration) throws {
      let model = Qwen35(configuration)
      let norms: [(String, Module)] = model.leafModules().flattened().compactMap { path, module in
        guard path.hasPrefix("language_model."), let norm = module as? RMSNorm else { return nil }
        return (path, OffsetRMSNorm(dimensions: norm.weight.dim(0), eps: norm.eps))
      }
      try model.update(modules: ModuleChildren.unflattened(norms), verify: [.noUnusedKeys])
      _qwen.wrappedValue = model
      super.init()
    }

    func prepareCheckpoint(_ checkpoint: ModelCheckpoint) throws -> ModelCheckpoint {
      guard checkpoint.metadata["format"]?.lowercased() == "mlx",
        checkpoint.weights.keys.allSatisfy({
          checkpoint.metadata(forWeight: $0)["format"]?.lowercased() == "mlx"
        })
      else {
        throw CompatibilityError("Expected MLX-converted weights with raw normalization offsets.")
      }
      var prepared = try checkpoint.mapNames { name in
        if name == "visual" { return "vision_tower" }
        if name.hasPrefix("visual.") {
          return "vision_tower." + name.dropFirst("visual.".count)
        }
        return name
      }
      let vision = qwen.config.visionConfiguration
      let path = "vision_tower.pos_embed"
      guard
        let weight = prepared.weights[path + ".weight"], weight.dtype == .uint32,
        weight.shape == [vision.numPositionEmbeddings, vision.hiddenSize / 8],
        let scales = prepared.weights[path + ".scales"], scales.dtype == .bfloat16,
        scales.shape == [vision.numPositionEmbeddings, vision.hiddenSize / 64],
        let biases = prepared.weights[path + ".biases"], biases.dtype == .bfloat16,
        biases.shape == scales.shape
      else {
        throw CompatibilityError("Missing or incompatible quantized vision positional embeddings.")
      }
      prepared.weights[path + ".weight"] = dequantized(
        weight, scales: scales, biases: biases, groupSize: 64, bits: 4, mode: .affine)
      prepared = try prepared.mapNames { name in
        name == path + ".scales" || name == path + ".biases" ? nil : name
      }
      prepared.perLayerQuantization?.perLayerQuantization[path] = .skip
      prepared = try qwen.prepareCheckpoint(prepared)
      return try prepared.mapNames { "qwen." + $0 }
    }

    var toolCallFormat: ToolCallFormat? { qwen.toolCallFormat }
    var reasoningConfig: ReasoningConfig? { qwen.reasoningConfig }

    func prepare() throws {
      try qwen.prepare()
    }

    func prepare(
      _ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters
    ) throws -> PrepareResult {
      try qwen.prepare(input, cache: cache, state: state, prefill: prefill)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?)
      -> LMOutput
    {
      qwen(input, cache: cache, state: state)
    }

    func nextTokenLogits(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?)
      -> LMOutput
    {
      qwen.nextTokenLogits(input, cache: cache, state: state)
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
      try qwen.newCache(parameters: parameters)
    }
  }

  private final class OffsetRMSNorm: RMSNorm {
    override func callAsFunction(_ inputs: MLXArray) -> MLXArray {
      // Adding one in BF16 would round away small learned offsets in this export.
      let input = inputs.asType(.float32)
      let normalized = input * rsqrt(mean(input * input, axis: -1, keepDims: true) + eps)
      return (normalized * (1 + weight.asType(.float32))).asType(inputs.dtype)
    }
  }

  private struct CompatibilityError: LocalizedError {
    let detail: String

    init(_ detail: String) { self.detail = detail }

    var errorDescription: String? { "Swift 1.5 compatibility: \(detail)" }
  }
}

private struct Swift15Manifest: Decodable {
  let sourceRepository: String?
  let sourceRevision: String?
  let architecturePatchSHA256: String?

  enum CodingKeys: String, CodingKey {
    case sourceRepository = "source_repository"
    case sourceRevision = "source_revision"
    case architecturePatchSHA256 = "architecture_patch_sha256"
  }
}

private struct Swift15ExportConfiguration: Decodable {
  let architectures: [String]
  let languageModelOnly: Bool
  let quantizationConfig: BaseConfiguration.Quantization

  enum CodingKeys: String, CodingKey {
    case architectures
    case languageModelOnly = "language_model_only"
    case quantizationConfig = "quantization_config"
  }
}
