import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MLXVLM
import XCTest

@testable import SumikaRuntimeMLX

nonisolated final class Swift15ModelLoaderTests: XCTestCase {
  func testUnrelatedExportsDoNotLoadATokenizer() async throws {
    let directory = try temporaryDirectory()
    let missing = try await Swift15ModelLoader.loadIfSupported(
      from: directory, using: UnexpectedTokenizerLoader())
    XCTAssertNil(missing)
    try Data(#"{"source_repository":"another/model"}"#.utf8).write(
      to: directory.appending(path: "QUANTIZATION_MANIFEST.json"))
    let unrelated = try await Swift15ModelLoader.loadIfSupported(
      from: directory, using: UnexpectedTokenizerLoader())
    XCTAssertNil(unrelated)
  }

  func testRecognizedExportRejectsChangedFingerprintAndConfiguration() async throws {
    let directory = try temporaryDirectory()
    let manifestURL = directory.appending(path: "QUANTIZATION_MANIFEST.json")
    for manifest in [
      Self.manifest.replacingOccurrences(of: "00ccd14e", with: "00000000"),
      Self.manifest.replacingOccurrences(of: "f6f1d0bd", with: "00000000"),
      Self.manifest,
    ] {
      try Data(manifest.utf8).write(to: manifestURL)
      try Data(Self.smallConfiguration.utf8).write(to: directory.appending(path: "config.json"))
      do {
        _ = try await Swift15ModelLoader.loadIfSupported(
          from: directory, using: UnexpectedTokenizerLoader())
        XCTFail("An incompatible recognized export must fail before tokenizer or weight loading.")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("Swift 1.5 compatibility"), "\(error)")
      }
    }
  }

  func testCheckpointMappingPreservesMetadataAndPrecision() throws {
    let adapter = try makeAdapter()
    var checkpoint = try makeCheckpoint(adapter)
    let source = "visual.blocks.0.attn.proj.weight"
    checkpoint = ModelCheckpoint(
      weights: checkpoint.weights, metadata: ["format": "mlx"],
      weightMetadata: [source: ["format": "mlx", "origin": "vision-shard"]],
      perLayerQuantization: .init(
        quantization: .init(groupSize: 64, bits: 4),
        perLayerQuantization: ["visual.blocks.0.attn.proj": .skip]))
    let prepared = try adapter.prepareCheckpoint(checkpoint)
    let target = "qwen.vision_tower.blocks.0.attn.proj"
    XCTAssertEqual(prepared.metadata(forWeight: target + ".weight")["origin"], "vision-shard")
    XCTAssertNil(prepared.perLayerQuantization?.quantization(layer: target))
    XCTAssertEqual(
      prepared.perLayerQuantization?.quantization(layer: "qwen.language_model.lm_head")?.bits, 4)
    XCTAssertFalse(prepared.weights.keys.contains { $0.hasPrefix("mtp.") || $0.contains(".mtp.") })
    XCTAssertTrue(prepared.weights.keys.allSatisfy { $0.hasPrefix("qwen.") })

    let path = "qwen.vision_tower.pos_embed"
    let table = try XCTUnwrap(prepared.weights[path + ".weight"])
    XCTAssertEqual(table.dtype, .bfloat16)
    XCTAssertEqual(table.shape, [16, 64])
    XCTAssertNil(prepared.weights[path + ".scales"])
    XCTAssertNil(prepared.weights[path + ".biases"])
    XCTAssertNil(prepared.perLayerQuantization?.quantization(layer: path))
    // Packed nibbles 0...7, scale 0.5, bias -1: check real decoded values.
    XCTAssertEqual(
      Array(table.asType(.float32).asArray(Float.self).prefix(8)),
      [-1, -0.5, 0, 0.5, 1, 1.5, 2, 2.5])

    var collision = checkpoint
    collision.weights["vision_tower.pos_embed.weight"] =
      checkpoint.weights["visual.pos_embed.weight"]
    XCTAssertThrowsError(try adapter.prepareCheckpoint(collision))
    var missing = checkpoint
    missing.weights.removeValue(forKey: "visual.pos_embed.scales")
    XCTAssertThrowsError(try adapter.prepareCheckpoint(missing))
  }

  func testRawNormOffsetsUseFloat32MathAndKeepInputDtype() throws {
    let adapter = try makeAdapter()
    let modules = Dictionary(uniqueKeysWithValues: adapter.qwen.leafModules().flattened())
    let norm = try XCTUnwrap(modules["language_model.model.norm"] as? RMSNorm)
    let raw = MLXArray((0..<64).map { Float($0 - 32) / 10_000 }).asType(.bfloat16)
    try norm.update(parameters: ModuleParameters.unflattened(["weight": raw]), verify: [.all])
    let input = MLXArray((0..<128).map { Float($0 % 17 - 8) / 7 }).reshaped([2, 64])
      .asType(.bfloat16)
    let values = input.asType(.float32).asArray(Float.self)
    let offsets = raw.asType(.float32).asArray(Float.self)
    var expected = [Float]()
    for row in 0..<2 {
      let slice = Array(values[(row * 64)..<((row + 1) * 64)])
      let inverseRMS = 1 / sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 } / 64 + norm.eps)
      expected += zip(slice, offsets).map { $0 * inverseRMS * (1 + $1) }
    }
    let result = norm(input)
    XCTAssertEqual(result.dtype, .bfloat16)
    XCTAssertEqual(
      result.asType(.float32).asArray(Float.self),
      MLXArray(expected).asType(.bfloat16).asType(.float32).asArray(Float.self))
    XCTAssertEqual(norm.weight.asType(.float32).asArray(Float.self), offsets)
    XCTAssertFalse(type(of: norm) == RMSNorm.self)
    for (path, module) in modules where path.hasPrefix("language_model.") && module is RMSNorm {
      XCTAssertTrue(type(of: module) == type(of: norm), "Unadapted norm: \(path)")
    }
    XCTAssertTrue(modules["vision_tower.blocks.0.norm1"] is LayerNorm)
    XCTAssertFalse(modules["language_model.model.layers.0.linear_attn.norm"] is RMSNorm)
  }

  func testStrictLoadingAndPreparationKeepNativeQwenBehavior() throws {
    let directory = try temporaryDirectory()
    let adapter = try makeAdapter()
    let checkpoint = try makeCheckpoint(adapter)
    let url = directory.appending(path: "model.safetensors")
    try MLX.save(arrays: checkpoint.weights, metadata: ["format": "mlx"], url: url)
    try loadWeights(
      modelDirectory: directory, model: adapter,
      perLayerQuantization: checkpoint.perLayerQuantization)
    XCTAssertEqual(adapter.toolCallFormat, .qwen35)
    XCTAssertEqual(adapter.reasoningConfig, adapter.qwen.reasoningConfig)
    let modules = Dictionary(uniqueKeysWithValues: adapter.qwen.leafModules().flattened())
    XCTAssertTrue(modules["vision_tower.pos_embed"] is Embedding)
    XCTAssertFalse(modules["vision_tower.pos_embed"] is QuantizedEmbedding)
    let input = LMInput(tokens: MLXArray([1, 2, 3]).reshaped([1, 3]))
    let cache = try adapter.newCache(parameters: nil)
    let prepared = try adapter.prepare(input, cache: cache, state: nil, prefill: .init())
    guard case .logits(let prefillOutput) = prepared else {
      return XCTFail("Expected prefill logits.")
    }
    let output = adapter.nextTokenLogits(
      .init(tokens: MLXArray([4]).reshaped([1, 1])), cache: cache, state: prefillOutput.state)
    XCTAssertEqual(output.logits.shape, [1, 1, 64])
    XCTAssertTrue(all(isFinite(output.logits)).item(Bool.self))

    var missing = checkpoint.weights
    missing.removeValue(forKey: "visual.patch_embed.proj.weight")
    try MLX.save(arrays: missing, metadata: ["format": "mlx"], url: url)
    XCTAssertThrowsError(try loadWeights(modelDirectory: directory, model: makeAdapter()))
  }

  func testInstalledExportPublishesConcreteQwen() async throws {
    guard
      ProcessInfo.processInfo.environment["SUMIKA_DOCUMENT_SMOKE_MODEL_ID"]
        == "Swift-1.5-4bit-MLX"
    else { throw XCTSkip("Set SUMIKA_DOCUMENT_SMOKE_MODEL_ID=Swift-1.5-4bit-MLX.") }
    let root =
      ProcessInfo.processInfo.environment["SUMIKA_DOCUMENT_SMOKE_MODELS_PATH"]
      .map { URL(filePath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Library/Application Support/Sumika/Models")
    let directory = root.appending(path: "ukisai/Swift-1.5-4bit-MLX")
    guard FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path)
    else {
      throw XCTSkip("Swift 1.5 is not installed.")
    }
    let loaded = try await Swift15ModelLoader.loadIfSupported(
      from: directory, using: makeHuggingFaceTokenizerLoader())
    let container = try XCTUnwrap(loaded)
    let native = await container.perform { context in
      context.model is Qwen35 && context.configuration.toolCallFormat == .qwen35
        && context.configuration.reasoningConfig != nil
    }
    XCTAssertTrue(native)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swift15-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func makeAdapter() throws -> Swift15ModelLoader.CheckpointAdapter {
    try Swift15ModelLoader.CheckpointAdapter(
      JSONDecoder().decode(Qwen35Configuration.self, from: Data(Self.smallConfiguration.utf8)))
  }

  private func makeCheckpoint(_ adapter: Swift15ModelLoader.CheckpointAdapter) throws
    -> ModelCheckpoint
  {
    var weights = Dictionary(
      uniqueKeysWithValues: adapter.qwen.parameters().flattened().map { path, value in
        (path.replacingOccurrences(of: "vision_tower.", with: "visual."), value)
      })
    weights["visual.pos_embed.weight"] = MLXArray.full(
      [16, 8], values: MLXArray(UInt32(0x7654_3210)))
    weights["visual.pos_embed.scales"] = MLXArray.full([16, 1], values: MLXArray(0.5)).asType(
      .bfloat16)
    weights["visual.pos_embed.biases"] = MLXArray.full([16, 1], values: MLXArray(-1)).asType(
      .bfloat16)
    weights["mtp.norm.weight"] = MLXArray.ones([64])
    return ModelCheckpoint(
      weights: weights, metadata: ["format": "mlx"],
      perLayerQuantization: .init(
        quantization: .init(groupSize: 64, bits: 4), perLayerQuantization: [:]))
  }

  private static let manifest = #"""
    {"source_repository":"ukisai/Swift-1.5-Qwen3.8-27b",
     "source_revision":"00ccd14e006897d28cb0ed5bf26390e60d274251",
     "architecture_patch_sha256":"f6f1d0bdafa45863bfbf93dac0398c481c993ea04fdf38b9bae98c643f89eaec"}
    """#

  private static let smallConfiguration = #"""
    {"model_type":"qwen3_5","architectures":["Qwen3_5ForConditionalGeneration"],
     "language_model_only":false,"quantization":{"bits":4,"group_size":64,"mode":"affine"},
     "quantization_config":{"bits":4,"group_size":64,"mode":"affine"},
     "text_config":{"model_type":"qwen3_5_text","hidden_size":64,"num_hidden_layers":2,
       "intermediate_size":128,"num_attention_heads":4,"num_key_value_heads":2,"head_dim":16,
       "linear_num_value_heads":2,"linear_num_key_heads":1,"linear_key_head_dim":16,
       "linear_value_head_dim":16,"linear_conv_kernel_dim":4,"full_attention_interval":2,
       "vocab_size":64,"rope_parameters":{"mrope_section":[1,1,0],"partial_rotary_factor":0.25}},
     "vision_config":{"model_type":"qwen3_5","depth":1,"hidden_size":64,
       "intermediate_size":128,"out_hidden_size":64,"num_heads":4,"patch_size":2,
       "spatial_merge_size":2,"temporal_patch_size":2,"num_position_embeddings":16}}
    """#

  private struct UnexpectedTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any Tokenizer {
      XCTFail("Tokenizer loading must not be reached.")
      throw CocoaError(.fileReadUnknown)
    }
  }
}
