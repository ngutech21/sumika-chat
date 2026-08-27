import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
import Testing

@testable import SumikaRuntimeMLX

@Suite(.serialized)
nonisolated struct BundledOptiQMTPDrafterLoaderTests {
  @Test("missing target configuration fails closed")
  func missingTargetConfigurationFailsClosed() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject a missing config.json")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .invalidConfiguration = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test("sidecar path cannot escape the model directory")
  func sidecarPathCannotEscapeModelDirectory() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try bundledConfiguration(mtpFile: "../mtp.safetensors").write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject an escaping sidecar path")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .unsafeMTPFile = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test(
    "unsupported sidecar quantization fails closed",
    arguments: [
      BundledMTPQuantizationVariation(bits: 8),
      BundledMTPQuantizationVariation(groupSize: 32),
      BundledMTPQuantizationVariation(mode: "mxfp4"),
      BundledMTPQuantizationVariation(prequantized: false),
    ]
  )
  func unsupportedSidecarQuantizationFailsClosed(
    variation: BundledMTPQuantizationVariation
  ) async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try bundledConfiguration(
        mtpFile: "optiq/mtp.safetensors",
        bits: variation.bits,
        groupSize: variation.groupSize,
        mode: variation.mode,
        prequantized: variation.prequantized
      ).write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      let sidecar = modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
      try FileManager.default.createDirectory(
        at: sidecar.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data().write(to: sidecar)
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject 8-bit weights")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .unsupportedQuantization = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test("absolute sidecar path fails closed")
  func absoluteSidecarPathFailsClosed() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try bundledConfiguration(mtpFile: "/tmp/mtp.safetensors").write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      await expectUnsafeMTPFile(from: target)
    }
  }

  @Test("sidecar symlink cannot escape the model directory")
  func sidecarSymlinkCannotEscapeModelDirectory() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      let externalFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("sumika-mtp-external-\(UUID().uuidString).safetensors")
      try Data().write(to: externalFile)
      defer { try? FileManager.default.removeItem(at: externalFile) }

      try bundledConfiguration(mtpFile: "optiq/mtp.safetensors").write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      let sidecar = modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
      try FileManager.default.createDirectory(
        at: sidecar.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: externalFile)
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      await expectUnsafeMTPFile(from: target)
    }
  }

  @Test("missing sidecar fails closed")
  func missingSidecarFailsClosed() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try bundledConfiguration(mtpFile: "optiq/mtp.safetensors").write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject a missing sidecar")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .missingMTPFile = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test("sidecar must be a regular safetensors file")
  func sidecarMustBeARegularSafetensorsFile() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try bundledConfiguration(mtpFile: "optiq/mtp.safetensors").write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      try FileManager.default.createDirectory(
        at: modelDirectory.appendingPathComponent("optiq/mtp.safetensors"),
        withIntermediateDirectories: true
      )
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject a directory")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .invalidMTPFile = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test("sidecar must use the safetensors extension")
  func sidecarMustUseTheSafetensorsExtension() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try bundledConfiguration(mtpFile: "optiq/mtp.bin").write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      let sidecar = modelDirectory.appendingPathComponent("optiq/mtp.bin")
      try FileManager.default.createDirectory(
        at: sidecar.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data().write(to: sidecar)
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject a non-safetensors file")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .invalidMTPFile = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test("sidecar accepts the Qwen 3.5 MoE model type")
  func sidecarAcceptsQwen35MoEModelType() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try bundledConfiguration(
        mtpFile: "optiq/mtp.safetensors",
        modelType: "qwen3_5_moe"
      ).write(
        to: modelDirectory.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      let sidecar = modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
      try FileManager.default.createDirectory(
        at: sidecar.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data().write(to: sidecar)
      let target = makeValidationTarget(modelDirectory: modelDirectory)

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject the non-Qwen target")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .incompatibleTarget = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test("cancellation is preserved")
  func cancellationIsPreserved() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      let target = makeValidationTarget(modelDirectory: modelDirectory)
      let task = Task {
        await Task.yield()
        return try await BundledOptiQMTPDrafterLoader.load(for: target)
      }
      task.cancel()

      do {
        _ = try await task.value
        Issue.record("Expected loader cancellation")
      } catch is CancellationError {
        // Expected: cancellation must not be rewritten as a loader error.
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
  }

  @Test("non-Qwen target fails closed")
  func nonQwenTargetFailsClosed() async throws {
    try await withTemporaryModelDirectory { modelDirectory in
      try writeValidConfigurationAndEmptySidecar(to: modelDirectory)
      let target = makeTargetContainer(
        modelDirectory: modelDirectory,
        model: BundledMTPNonQwenModel()
      )

      do {
        _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
        Issue.record("Expected the bundled MTP loader to reject a non-Qwen target")
      } catch let error as BundledOptiQMTPDrafterLoaderError {
        guard case .incompatibleTarget = error else {
          Issue.record("Unexpected loader error: \(error)")
          return
        }
      }
    }
  }

  @Test(
    "sidecar accepts only MTP tensor names",
    .enabled(if: bundledMTPHasBundledMetalLibrary)
  )
  func sidecarAcceptsOnlyMTPTensorNames() async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        try await withTemporaryModelDirectory { modelDirectory in
          try bundledConfiguration(mtpFile: "optiq/mtp.safetensors").write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
          )
          let sidecar = modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
          try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try save(
            arrays: ["language_model.model.embed_tokens.weight": MLXArray([0])],
            url: sidecar,
            stream: .cpu
          )
          let target = try makeTarget(modelDirectory: modelDirectory)

          do {
            _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
            Issue.record("Expected the bundled MTP loader to reject target tensor names")
          } catch let error as BundledOptiQMTPDrafterLoaderError {
            guard case .invalidWeightNamespace = error else {
              Issue.record("Unexpected loader error: \(error)")
              return
            }
          }
        }
      }
    }
  }

  @Test(
    "configured sidecar loads without consulting the target index",
    .enabled(if: bundledMTPHasBundledMetalLibrary)
  )
  func configuredSidecarLoadsWithoutConsultingTargetIndex() async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        try await withTemporaryModelDirectory { modelDirectory in
          let configuration = bundledConfiguration(
            mtpFile: "optiq/mtp.safetensors",
            tensorCount: 29
          )
          try configuration.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
          )
          try writeSyntheticSidecar(
            configuration: configuration,
            to: modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
          )

          let targetShard = modelDirectory.appendingPathComponent(
            "model-00001-of-00001.safetensors")
          try Data("not a safetensors file".utf8).write(to: targetShard)
          try """
          {
            "weight_map": {
              "language_model.model.embed_tokens.weight": "model-00001-of-00001.safetensors"
            }
          }
          """.write(
            to: modelDirectory.appendingPathComponent("model.safetensors.index.json"),
            atomically: true,
            encoding: .utf8
          )

          let target = try makeTarget(modelDirectory: modelDirectory)
          let container = try await BundledOptiQMTPDrafterLoader.load(for: target)
          let inspection = await container.perform { context in
            guard let model = context.model as? Qwen35MTPDraftModel else {
              return BundledMTPLoadInspection.unexpectedModel
            }
            let modules = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
            let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
            let qProjection = modules["mtp.layers.0.self_attn.q_proj"] as? QuantizedLinear
            let preFCNorm = parameters["mtp.pre_fc_norm_embedding.weight"]
            return BundledMTPLoadInspection(
              isQwenMTPModel: true,
              fcIsDense: modules["mtp.fc"] is Linear
                && !(modules["mtp.fc"] is QuantizedLinear),
              qProjectionGroupSize: qProjection?.groupSize,
              qProjectionBits: qProjection?.bits,
              qProjectionMode: qProjection?.mode,
              preFCNormFirstValue: preFCNorm?[0].item(Float.self)
            )
          }

          #expect(inspection.isQwenMTPModel)
          #expect(inspection.fcIsDense)
          #expect(inspection.qProjectionGroupSize == 64)
          #expect(inspection.qProjectionBits == 4)
          #expect(inspection.qProjectionMode == .affine)
          #expect(inspection.preFCNormFirstValue == 1)
        }
      }
    }
  }

  @Test(
    "configured MoE sidecar loads for a VLM target",
    .enabled(if: bundledMTPHasBundledMetalLibrary)
  )
  func configuredMoESidecarLoadsForVLMTarget() async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        try await withTemporaryModelDirectory { modelDirectory in
          let configuration = bundledConfiguration(
            mtpFile: "optiq/mtp.safetensors",
            modelType: "qwen3_5_moe",
            includesVisionConfiguration: true
          )
          try configuration.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
          )
          try writeSyntheticSidecar(
            configuration: configuration,
            to: modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
          )

          let target = try makeVLMTarget(modelDirectory: modelDirectory)
          let container = try await BundledOptiQMTPDrafterLoader.load(for: target)
          let isVLMDrafter = await container.perform { context in
            context.model is MLXVLM.Qwen35VLMNextNDraftModel
          }

          #expect(isVLMDrafter)
        }
      }
    }
  }

  @Test(
    "declared tensor count must match the sidecar",
    .enabled(if: bundledMTPHasBundledMetalLibrary)
  )
  func declaredTensorCountMustMatchSidecar() async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        try await withTemporaryModelDirectory { modelDirectory in
          try bundledConfiguration(
            mtpFile: "optiq/mtp.safetensors",
            tensorCount: 2
          ).write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
          )
          let sidecar = modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
          try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try save(arrays: ["mtp.placeholder": MLXArray([0])], url: sidecar, stream: .cpu)
          let target = try makeTarget(modelDirectory: modelDirectory)

          do {
            _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
            Issue.record("Expected the bundled MTP loader to reject the tensor-count mismatch")
          } catch let error as BundledOptiQMTPDrafterLoaderError {
            guard case .tensorCountMismatch(expected: 2, actual: 1) = error else {
              Issue.record("Unexpected loader error: \(error)")
              return
            }
          }
        }
      }
    }
  }

  @Test(
    "missing required weight fails the strict update",
    .enabled(if: bundledMTPHasBundledMetalLibrary)
  )
  func missingRequiredWeightFailsStrictUpdate() async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        try await withTemporaryModelDirectory { modelDirectory in
          let configuration = bundledConfiguration(mtpFile: "optiq/mtp.safetensors")
          try configuration.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
          )
          try writeSyntheticSidecar(
            configuration: configuration,
            to: modelDirectory.appendingPathComponent("optiq/mtp.safetensors"),
            omitting: "mtp.fc.weight"
          )
          let target = try makeTarget(modelDirectory: modelDirectory)

          do {
            _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
            Issue.record("Expected the strict update to reject a missing fc weight")
          } catch let error as BundledOptiQMTPDrafterLoaderError {
            guard case .weightLoadingFailed = error else {
              Issue.record("Unexpected loader error: \(error)")
              return
            }
          }
        }
      }
    }
  }
}

nonisolated private func expectUnsafeMTPFile(from target: ModelContainer) async {
  do {
    _ = try await BundledOptiQMTPDrafterLoader.load(for: target)
    Issue.record("Expected the bundled MTP loader to reject an unsafe sidecar path")
  } catch let error as BundledOptiQMTPDrafterLoaderError {
    guard case .unsafeMTPFile = error else {
      Issue.record("Unexpected loader error: \(error)")
      return
    }
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}

nonisolated private func withTemporaryModelDirectory(
  _ body: (URL) async throws -> Void
) async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("sumika-mtp-loader-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(directory)
}

nonisolated private func makeTarget(modelDirectory: URL) throws -> ModelContainer {
  try Device.withDefaultDevice(.cpu) {
    try Stream.withNewDefaultStream(device: .cpu) {
      let configuration = try JSONDecoder().decode(
        MLXLLM.Qwen35Configuration.self,
        from: Data(tinyQwenConfiguration.utf8)
      )
      return makeTargetContainer(
        modelDirectory: modelDirectory,
        model: MLXLLM.Qwen35Model(configuration)
      )
    }
  }
}

nonisolated private func makeVLMTarget(modelDirectory: URL) throws -> ModelContainer {
  try Device.withDefaultDevice(.cpu) {
    try Stream.withNewDefaultStream(device: .cpu) {
      let data = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
      let configuration = try JSONDecoder().decode(
        MLXVLM.Qwen35Configuration.self,
        from: data
      )
      return makeTargetContainer(
        modelDirectory: modelDirectory,
        model: MLXVLM.Qwen35MoE(configuration)
      )
    }
  }
}

nonisolated private func makeValidationTarget(modelDirectory: URL) -> ModelContainer {
  makeTargetContainer(
    modelDirectory: modelDirectory,
    model: BundledMTPNonQwenModel()
  )
}

nonisolated private func makeTargetContainer(
  modelDirectory: URL,
  model: any LanguageModel
) -> ModelContainer {
  let tokenizer = BundledMTPTestTokenizer()
  return ModelContainer(
    context: ModelContext(
      configuration: ModelConfiguration(directory: modelDirectory),
      model: model,
      processor: BundledMTPTestProcessor(),
      tokenizer: tokenizer
    )
  )
}

nonisolated private func writeValidConfigurationAndEmptySidecar(to modelDirectory: URL) throws {
  try bundledConfiguration(mtpFile: "optiq/mtp.safetensors").write(
    to: modelDirectory.appendingPathComponent("config.json"),
    atomically: true,
    encoding: .utf8
  )
  let sidecar = modelDirectory.appendingPathComponent("optiq/mtp.safetensors")
  try FileManager.default.createDirectory(
    at: sidecar.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data().write(to: sidecar)
}

nonisolated private func writeSyntheticSidecar(
  configuration: String,
  to url: URL,
  omitting omittedKey: String? = nil
) throws {
  let qwenConfiguration = try JSONDecoder().decode(
    MLXLLM.Qwen35Configuration.self,
    from: Data(configuration.utf8)
  )
  let model = MLXLLM.Qwen35MTPDraftModel(qwenConfiguration, preconvertedNorms: false)
  quantize(model: model) { path, _ in
    path.contains(".self_attn.") || path.contains(".mlp.")
      ? (groupSize: 64, bits: 4, mode: .affine)
      : nil
  }
  var weights = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
  let preFCNormKey = "mtp.pre_fc_norm_embedding.weight"
  if let preFCNorm = weights[preFCNormKey] {
    weights[preFCNormKey] = MLXArray.zeros(preFCNorm.shape, dtype: preFCNorm.dtype)
  }
  if let omittedKey {
    weights[omittedKey] = nil
  }
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try save(arrays: weights, url: url, stream: .cpu)
}

nonisolated struct BundledMTPQuantizationVariation: Sendable {
  let bits: Int
  let groupSize: Int
  let mode: String
  let prequantized: Bool

  init(
    bits: Int = 4,
    groupSize: Int = 64,
    mode: String = "affine",
    prequantized: Bool = true
  ) {
    self.bits = bits
    self.groupSize = groupSize
    self.mode = mode
    self.prequantized = prequantized
  }
}

nonisolated private struct BundledMTPLoadInspection: Sendable {
  let isQwenMTPModel: Bool
  let fcIsDense: Bool
  let qProjectionGroupSize: Int?
  let qProjectionBits: Int?
  let qProjectionMode: QuantizationMode?
  let preFCNormFirstValue: Float?

  static let unexpectedModel = BundledMTPLoadInspection(
    isQwenMTPModel: false,
    fcIsDense: false,
    qProjectionGroupSize: nil,
    qProjectionBits: nil,
    qProjectionMode: nil,
    preFCNormFirstValue: nil
  )
}

nonisolated private final class BundledMTPTestBundleToken {}

nonisolated private let bundledMTPHasBundledMetalLibrary: Bool = {
  let testBundle = Bundle(for: BundledMTPTestBundleToken.self)
  let libraryURL = testBundle.resourceURL?
    .appending(path: "mlx-swift_Cmlx.bundle", directoryHint: .isDirectory)
    .appending(path: "Contents/Resources/default.metallib", directoryHint: .notDirectory)
  guard let libraryURL else {
    return false
  }
  return (try? libraryURL.checkResourceIsReachable()) == true
}()

nonisolated private let tinyQwenConfiguration = """
  {
    "model_type": "qwen3_5",
    "text_config": {
      "model_type": "qwen3_5",
      "hidden_size": 64,
      "num_hidden_layers": 1,
      "intermediate_size": 64,
      "num_attention_heads": 1,
      "num_key_value_heads": 1,
      "linear_num_value_heads": 1,
      "linear_num_key_heads": 1,
      "linear_key_head_dim": 8,
      "linear_value_head_dim": 8,
      "linear_conv_kernel_dim": 2,
      "vocab_size": 64,
      "head_dim": 64,
      "full_attention_interval": 1,
      "mtp_num_hidden_layers": 1,
      "mtp_use_dedicated_embeddings": false
    }
  }
  """

nonisolated private func bundledConfiguration(
  mtpFile: String,
  modelType: String = "qwen3_5",
  bits: Int = 4,
  groupSize: Int = 64,
  mode: String = "affine",
  prequantized: Bool = true,
  tensorCount: Int? = nil,
  includesVisionConfiguration: Bool = false
) -> String {
  let tensorCountEntry = tensorCount.map { "\"mtp_tensor_count\": \($0)," } ?? ""
  let textModelType = modelType == "qwen3_5_moe" ? "qwen3_5_moe_text" : "qwen3_5"
  let moeConfiguration =
    modelType == "qwen3_5_moe"
    ? """
    ,
    "num_experts": 2,
    "num_experts_per_tok": 1,
    "decoder_sparse_step": 1,
    "shared_expert_intermediate_size": 64,
    "moe_intermediate_size": 64,
    "norm_topk_prob": true
    """
    : ""
  let visionConfiguration =
    includesVisionConfiguration
    ? """
    ,
    "vision_config": {
      "model_type": "qwen3_5_moe",
      "depth": 1,
      "hidden_size": 64,
      "intermediate_size": 64,
      "out_hidden_size": 64,
      "num_heads": 1,
      "patch_size": 2,
      "spatial_merge_size": 1,
      "temporal_patch_size": 1,
      "num_position_embeddings": 16
    }
    """
    : ""
  return """
    {
      "model_type": "\(modelType)",
      "mtp_file": "\(mtpFile)",
      \(tensorCountEntry)
      "mtplx_mtp_quantization": {
        "bits": \(bits),
        "group_size": \(groupSize),
        "mode": "\(mode)",
        "prequantized": \(prequantized)
      },
      "text_config": {
        "model_type": "\(textModelType)",
        "hidden_size": 64,
        "num_hidden_layers": 1,
        "intermediate_size": 64,
        "num_attention_heads": 1,
        "num_key_value_heads": 1,
        "linear_num_value_heads": 1,
        "linear_num_key_heads": 1,
        "linear_key_head_dim": 8,
        "linear_value_head_dim": 8,
        "linear_conv_kernel_dim": 2,
        "vocab_size": 64,
        "head_dim": 64,
        "full_attention_interval": 1,
        "mtp_num_hidden_layers": 1,
        "mtp_use_dedicated_embeddings": false\(moeConfiguration)
      }\(visionConfiguration)
    }
    """
}

nonisolated private struct BundledMTPTestProcessor: UserInputProcessor {
  func prepare(input _: UserInput) async throws -> LMInput {
    LMInput(tokens: MLXArray([0]))
  }
}

nonisolated private struct BundledMTPTestTokenizer: Tokenizer {
  func encode(text _: String, addSpecialTokens _: Bool) -> [Int] { [0] }
  func decode(tokenIds _: [Int], skipSpecialTokens _: Bool) -> String { "" }
  func convertTokenToId(_: String) -> Int? { nil }
  func convertIdToToken(_: Int) -> String? { nil }
  var bosToken: String? { nil }
  var eosToken: String? { nil }
  var unknownToken: String? { nil }

  func applyChatTemplate(
    messages _: [[String: any Sendable]],
    tools _: [[String: any Sendable]]?,
    additionalContext _: [String: any Sendable]?
  ) throws -> [Int] {
    [0]
  }
}

nonisolated private final class BundledMTPNonQwenModel: Module, LanguageModel,
  KVCacheDimensionProvider
{
  nonisolated override init() {
    super.init()
  }

  var kvHeads: [Int] { [] }

  func prepare(
    _ input: LMInput,
    cache _: [KVCache],
    state _: LMOutput.State?,
    prefill _: PrefillParameters
  ) throws -> PrepareResult {
    .tokens(input.text)
  }

  func callAsFunction(_ inputs: MLXArray, cache _: [KVCache]?) -> MLXArray {
    MLXArray.zeros([1, inputs.size, 1])
  }
}
