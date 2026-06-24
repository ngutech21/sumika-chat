# Minimal MTP Support In mlx-swift-lm ChatSession

## Goal

Expose Gemma 4 MTP drafter generation through `MLXLMCommon.ChatSession` so Sumika can keep using its existing `ChatSession.streamDetails(...)` path. Sumika should not need to reimplement `ChatSession` internals such as `UserInput` preparation, KV-cache lifecycle, history prefill, stream draining, or tool-call parsing.

The desired Sumika-side shape is:

```swift
let session = MLXLMCommon.ChatSession(
  modelContainer,
  instructions: systemPrompt,
  history: history,
  mtpSpeculativeDecoding: mtpConfig,
  generateParameters: generateParameters,
  additionalContext: additionalContext,
  tools: toolSpecs
)
```

Non-MTP callers should behave exactly as they do today.

## Current State

The local `mlx-swift-lm` main-branch dependency already contains the low-level pieces:

- `MTPDrafterModel`
- `MTPDrafterContainer`
- `MTPDrafterModelFactory`
- `MTPSpeculativeTokenIterator`
- generic `MLXLMCommon.generateTask(... iterator: tools:)`

`ChatSession` already has regular speculative decoding via `SpeculativeDecodingConfig`, but that path uses `SpeculativeTokenIterator` and expects the draft model to be a normal `LanguageModel` with its own draft KV cache.

Gemma 4 MTP drafters are different:

- They conform to `MTPDrafterModel`, not `LanguageModel`.
- They do not have a tokenizer.
- They do not use a separate draft KV cache.
- They draft from target-model hidden state and shared KV emitted by the main model.

Therefore the minimal change is to add a separate MTP-specific config to `ChatSession`, not to overload the existing `SpeculativeDecodingConfig`.

## Minimal Public API

Add a new public config next to `SpeculativeDecodingConfig` in `Libraries/MLXLMCommon/ChatSession.swift`.

```swift
public struct MTPSpeculativeDecodingConfig: Sendable {
  package enum DrafterSource: Sendable {
    case loaded(MTPDrafterContainer)
    case deferred(bytes: Int, @Sendable () async throws -> MTPDrafterContainer)
  }

  package let drafterSource: DrafterSource
  public let blockSize: Int
  public let memoryPolicy: SpeculativeDecodingMemoryPolicy?

  public var drafterModel: MTPDrafterContainer? {
    if case .loaded(let drafter) = drafterSource {
      return drafter
    }
    return nil
  }

  public init(
    drafterModel: MTPDrafterContainer,
    blockSize: Int = 4,
    memoryPolicy: SpeculativeDecodingMemoryPolicy? = nil
  ) {
    precondition(blockSize >= 2, "MTP blockSize must be >= 2")
    self.drafterSource = .loaded(drafterModel)
    self.blockSize = blockSize
    self.memoryPolicy = memoryPolicy
  }

  public init(
    drafterModelBytes: Int,
    blockSize: Int = 4,
    memoryPolicy: SpeculativeDecodingMemoryPolicy? = nil,
    loadDrafterModel: @escaping @Sendable () async throws -> MTPDrafterContainer
  ) {
    precondition(blockSize >= 2, "MTP blockSize must be >= 2")
    self.drafterSource = .deferred(bytes: max(0, drafterModelBytes), loadDrafterModel)
    self.blockSize = blockSize
    self.memoryPolicy = memoryPolicy
  }

  package var estimatedDrafterModelBytes: Int? {
    guard case .deferred(let bytes, _) = drafterSource else {
      return nil
    }
    return bytes
  }

  package func loadDrafterModel() async throws -> MTPDrafterContainer {
    switch drafterSource {
    case .loaded(let drafter):
      drafter
    case .deferred(_, let load):
      try await load()
    }
  }
}
```

The deferred initializer keeps parity with regular speculative decoding and lets callers avoid loading the drafter if a memory policy rejects it.

## ChatSession Changes

Add stored properties:

```swift
private let loadedMTPDrafterModel: SerialAccessContainer<MTPDrafterContainer?>
public let mtpSpeculativeDecoding: MTPSpeculativeDecodingConfig?
```

Add an optional parameter to every `ChatSession` initializer:

```swift
mtpSpeculativeDecoding: MTPSpeculativeDecodingConfig? = nil
```

Initialize:

```swift
self.loadedMTPDrafterModel = .init(mtpSpeculativeDecoding?.drafterModel)
self.mtpSpeculativeDecoding = mtpSpeculativeDecoding
```

Keep the existing `speculativeDecoding` parameter for normal draft models. MTP and regular speculative decoding should be mutually exclusive. The least surprising minimal behavior is to throw from generation if both are configured:

```swift
if speculativeDecoding != nil, mtpSpeculativeDecoding != nil {
  throw ChatSessionError.incompatibleSpeculativeDecodingConfiguration
}
```

If adding a new error is considered too broad, use `precondition` in the initializer. A typed error is preferable for app callers.

## streamMap Generation Branch

In `ChatSession.streamMap(...)`, preserve all existing logic before iterator selection:

- system instructions
- stored history or KV cache
- appending input messages
- `UserInput(chat:processing:tools:additionalContext:)`
- `processor.prepare(input:)`
- main model extraction
- main `kvCache`

Only change the iterator selection branch.

Current shape:

```swift
if let speculativeDecoding {
  // regular SpeculativeTokenIterator path
} else {
  (genStream, genTask) = try defaultGeneration()
}
```

Minimal target shape:

```swift
if let mtpSpeculativeDecoding {
  (genStream, genTask) = try await mtpGeneration(
    config: mtpSpeculativeDecoding,
    input: input,
    model: model,
    modelConfiguration: modelConfiguration,
    tokenizer: tokenizer,
    kvCache: kvCache,
    generateParameters: generateParameters,
    tools: tools
  )
} else if let speculativeDecoding {
  // existing regular SpeculativeTokenIterator path unchanged
} else {
  (genStream, genTask) = try defaultGeneration()
}
```

The MTP helper should:

1. Optionally evaluate memory policy before loading a deferred drafter.
2. Load/cache `MTPDrafterContainer` through `loadedMTPDrafterModel`.
3. Extract `any MTPDrafterModel` via `drafterContainer.perform`.
4. Build `MTPSpeculativeTokenIterator`.
5. Call generic `MLXLMCommon.generateTask(... iterator: tools:)`.

Sketch:

```swift
let cachedDrafterContainer = await loadedMTPDrafterModel.read { $0 }
let drafterContainer: MTPDrafterContainer
if let cachedDrafterContainer {
  drafterContainer = cachedDrafterContainer
} else {
  drafterContainer = try await mtpSpeculativeDecoding.loadDrafterModel()
  await loadedMTPDrafterModel.update { stored in
    if stored == nil {
      stored = drafterContainer
    }
  }
}

let drafterModel = await drafterContainer.perform { context in
  SendableBox(context.model)
}.consume()

let iterator = try MTPSpeculativeTokenIterator(
  input: input,
  mainModel: model,
  drafter: drafterModel,
  mainCache: kvCache,
  parameters: generateParameters,
  blockSize: mtpSpeculativeDecoding.blockSize
)

(genStream, genTask) = MLXLMCommon.generateTask(
  promptTokenCount: input.text.tokens.size,
  modelConfiguration: modelConfiguration,
  tokenizer: tokenizer,
  iterator: iterator,
  tools: tools
)
```

The important part is using the generic `generateTask(... iterator: tools:)`, not the existing MTP convenience `generate(input:context:mtpDrafter:)`, because Sumika needs native Gemma tool-call parsing with typed tool schemas.

## Memory Policy

Reuse `SpeculativeDecodingMemoryPolicy` rather than inventing a second policy type.

For deferred MTP loading:

```swift
if let memoryPolicy = mtpSpeculativeDecoding.memoryPolicy,
  let drafterBytes = mtpSpeculativeDecoding.estimatedDrafterModelBytes
{
  let evaluation = memoryPolicy.evaluate(
    mainModelBytes: SpeculativeDecodingMemoryPolicy.modelWeightBytes(model),
    draftModelBytes: drafterBytes
  )
  if !evaluation.shouldUseSpeculativeDecoding {
    if evaluation.action == .fail {
      throw SpeculativeDecodingMemoryError(evaluation: evaluation)
    }
    return try defaultGeneration()
  }
}
```

After loading the drafter, there is no direct `LanguageModel`-based byte helper because `MTPDrafterModel` is not a `LanguageModel`. Keep the first version minimal: use deferred byte estimates for admission and skip a second model-object memory evaluation. This avoids broadening `SpeculativeDecodingMemoryPolicy` in the first change.

## Factory And Registration Notes

Sumika should load drafters from local directories, using:

```swift
let config = ModelConfiguration(directory: drafterDirectory)
let drafter = try await MTPDrafterModelFactory.shared.loadContainer(
  from: LocalDownloader(),
  using: LocalTokenizerLoader(),
  configuration: config
)
```

The tokenizer loader is part of the generic factory shape; MTP drafters do not use a tokenizer.

`MLXVLM.Gemma4AssistantRegistration.register()` must run before loading Gemma 4 assistant drafters, because `MTPDrafterTypeRegistry` starts empty and the `gemma4_assistant` model type lives in MLXVLM.

QAT drafter repos should not require new `MTPDrafterRegistry` entries if Sumika passes a local directory `ModelConfiguration`. Add registry IDs only if the fork also wants Hub-ID based loading for:

- `mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit`
- `mlx-community/gemma-4-31B-it-qat-assistant-4bit`

## Tests In mlx-swift-lm Fork

Add focused `ChatSession` tests, not broad integration tests first:

1. `ChatSession` rejects or traps when both `speculativeDecoding` and `mtpSpeculativeDecoding` are set.
2. `ChatSession` with MTP uses `MTPSpeculativeTokenIterator` and emits a normal `.info` event.
3. `ChatSession` with MTP passes `tools` into `generateTask`, preserving typed tool-call parsing.
4. Deferred MTP loader is not called when memory policy falls back before loading.
5. Deferred MTP loader is cached and only called once across turns.
6. Existing non-MTP `ChatSession` tests remain unchanged.

If feasible, mirror the existing regular speculative decoding tests in `ChatSessionTests` and use lightweight fake models where possible. Keep model-download integration tests separate and skip when checkpoints are missing.

## Non-Goals

Do not change Sumika generation in this fork change.

Do not add a second public chat API next to `ChatSession`.

Do not move Sumika's tool loop into `mlx-swift-lm`.

Do not require MTP for normal `ChatSession` callers.

Do not change the existing regular `SpeculativeDecodingConfig` behavior.

## Expected Sumika Follow-Up

After the fork exposes `ChatSession(... mtpSpeculativeDecoding:)`, Sumika only needs a small runtime integration:

1. Extend `ChatModelConfiguration` with optional drafter config.
2. On model load, pass the downloaded drafter directory and block size into `GemmaMLXRuntime`.
3. `GemmaMLXRuntime.prepareSession(...)` creates `ChatSession` with `mtpSpeculativeDecoding` when enabled.
4. Extend Sumika's cache signature with drafter ID and block size so toggling MTP cannot reuse an incompatible runtime session.
5. Keep the existing non-drafter `ChatSession` path unchanged.

This keeps the MTP-specific MLX details in `mlx-swift-lm` and avoids duplicating `ChatSession` internals inside Sumika.
