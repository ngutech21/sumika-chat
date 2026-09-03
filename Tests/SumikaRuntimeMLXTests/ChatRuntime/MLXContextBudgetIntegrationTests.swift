import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Synchronization
import XCTest

@testable import SumikaRuntimeMLX

nonisolated final class MLXContextBudgetIntegrationTests: XCTestCase {
  override func setUpWithError() throws {
    let library = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let library, FileManager.default.fileExists(atPath: library.path(percentEncoded: false))
    else {
      throw XCTSkip("MLX default.metallib is unavailable in the SwiftPM test bundle.")
    }
  }

  func testColdClampRetriesPreparationOnceAndPreservesSettings() async throws {
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      let fixture = await Self.fixture()
      let session = ChatSession(
        fixture.container, instructions: "instructions",
        generateParameters: .init(maxTokens: 32_768, temperature: 0))
      let budget = MLXContextBudget(capacity: 16_384, configuredMaximum: 32_768)
      let info = try await Self.collect(
        budget.streamDetails(session: session, messages: [.user("document END")]))
      XCTAssertEqual(budget.trace.preparationAttempts, 2)
      XCTAssertEqual(info?.stopReason, .stop)
      XCTAssertEqual(budget.trace.promptTokens, info?.totalPromptTokenCount)
      XCTAssertEqual(
        budget.trace.effectiveResponseMaximum, 16_384 - (budget.trace.promptTokens ?? 0) - 64)
      XCTAssertEqual(fixture.log.snapshot.prefills.count, 1)
      XCTAssertEqual(fixture.log.snapshot.trims, 0)
      XCTAssertEqual(session.generateParameters.maxTokens, 32_768)
      XCTAssertNil(session.generateParameters.maxKVSize)
      XCTAssertFalse(budget.trace.rejected)
    }
  }

  func testWarmClampCountsFullHistoryAndPreservesReuse() async throws {
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      let fixture = await Self.fixture()
      let session = ChatSession(
        fixture.container, generateParameters: .init(maxTokens: 8, temperature: 0))
      _ = try await Self.collect(
        MLXContextBudget(capacity: 16_384, configuredMaximum: 8)
          .streamDetails(session: session, messages: [.user(String(repeating: "a", count: 500))]))
      session.generateParameters.maxTokens = 32_768
      let budget = MLXContextBudget(capacity: 16_384, configuredMaximum: 32_768)
      let result = try await Self.collect(
        budget.streamDetails(session: session, messages: [.user("follow up")]))
      let info = try XCTUnwrap(result)
      XCTAssertEqual(budget.trace.preparationAttempts, 2)
      XCTAssertEqual(budget.trace.promptTokens, info.totalPromptTokenCount)
      XCTAssertGreaterThan(info.cachedPromptTokenCount, 0)
      XCTAssertGreaterThan(budget.trace.promptTokens ?? 0, info.promptTokenCount)
      XCTAssertEqual(fixture.log.snapshot.prefills.count, 2)
      XCTAssertEqual(session.generateParameters.maxTokens, 32_768)
    }
  }

  func testWarmRejectionDoesNotTrimPrefillOrCommitPendingMessages() async throws {
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      let fixture = await Self.fixture()
      let session = ChatSession(
        fixture.container, generateParameters: .init(maxTokens: 8, temperature: 0))
      _ = try await Self.collect(
        MLXContextBudget(capacity: 16_384, configuredMaximum: 8)
          .streamDetails(session: session, messages: [.user("initial document")]))
      let before = fixture.log.snapshot
      session.generateParameters.maxTokens = 32_768
      let rejected = MLXContextBudget(capacity: 16_384, configuredMaximum: 32_768)
      do {
        _ = try await Self.collect(
          rejected.streamDetails(
            session: session, messages: [.user("REJECTED " + String(repeating: "a", count: 12_300))]
          ))
        XCTFail("Expected context rejection")
      } catch is MLXContextBudgetError {}
      XCTAssertTrue(rejected.trace.rejected)
      XCTAssertEqual(fixture.log.snapshot.prefills, before.prefills)
      XCTAssertEqual(fixture.log.snapshot.trims, before.trims)
      session.generateParameters.maxTokens = 8
      _ = try await Self.collect(
        MLXContextBudget(capacity: 16_384, configuredMaximum: 8)
          .streamDetails(session: session, messages: [.user("small follow up")]))
      XCTAssertFalse(fixture.log.snapshot.preparedContents.last?.contains("REJECTED") ?? true)
    }
  }

  func testToolContinuationIncludesInstructionsSchemasReasoningAndMedia() async throws {
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      let fixture = await Self.fixture()
      let session = ChatSession(
        fixture.container,
        instructions: "system instructions",
        history: [
          .user("question", images: [.url(URL(filePath: "/tmp/test-image.png"))]),
          .assistant("tool request"),
        ],
        generateParameters: .init(maxTokens: 32_768, temperature: 0),
        additionalContext: ["enable_thinking": true],
        tools: [["name": "test_tool"]]
      )
      let budget = MLXContextBudget(capacity: 16_384, configuredMaximum: 32_768)
      let info = try await Self.collect(
        budget.streamDetails(session: session, messages: [.tool("tool result")]))
      let snapshot = fixture.log.snapshot
      XCTAssertEqual(budget.trace.promptTokens, info?.totalPromptTokenCount)
      XCTAssertEqual(snapshot.imageCounts, [1, 1])
      XCTAssertTrue(
        snapshot.preparedContents.last?.contains(
          "system instructions|question|tool request|tool result") ?? false)
      XCTAssertEqual(budget.trace.promptTokens, 121)
      XCTAssertEqual(snapshot.prefills.count, 1)
    }
  }

  func testChangedRetryInputIsRevalidatedWithoutPrefill() async throws {
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      for retryPadding in [1, 13_000] {
        let fixture = await Self.fixture(retryPadding: retryPadding)
        let session = ChatSession(
          fixture.container, generateParameters: .init(maxTokens: 32_768, temperature: 0))
        let budget = MLXContextBudget(capacity: 16_384, configuredMaximum: 32_768)
        do {
          _ = try await Self.collect(
            budget.streamDetails(session: session, messages: [.user("document")]))
          XCTFail("Expected the second preparation to reject")
        } catch is MLXContextBudgetError {}
        XCTAssertEqual(budget.trace.preparationAttempts, 2)
        XCTAssertTrue(budget.trace.rejected)
        XCTAssertTrue(fixture.log.snapshot.prefills.isEmpty)
        XCTAssertEqual(fixture.log.snapshot.trims, 0)
        XCTAssertEqual(session.generateParameters.maxTokens, 32_768)
      }
    }
  }

  func testAdjustedMaximumMustPassComponentValidationBeforeRetry() async throws {
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      let fixture = await Self.fixture()
      let components = GenerationComponents(parameterValidator: { parameters in
        if (parameters.maxTokens ?? 0) < 20_000 { throw ValidationFailure() }
      })
      let session = ChatSession(
        fixture.container, generateParameters: .init(maxTokens: 32_768, temperature: 0),
        components: components)
      let budget = MLXContextBudget(capacity: 16_384, configuredMaximum: 32_768)
      do {
        _ = try await Self.collect(
          budget.streamDetails(session: session, messages: [.user("document")]))
        XCTFail("Expected incompatible thinking budget")
      } catch let error as MLXContextBudgetError {
        XCTAssertEqual(error, .incompatibleThinkingBudget)
      }
      XCTAssertEqual(budget.trace.preparationAttempts, 1)
      XCTAssertTrue(budget.trace.rejected)
      XCTAssertTrue(fixture.log.snapshot.prefills.isEmpty)
      XCTAssertEqual(session.generateParameters.maxTokens, 32_768)
    }
  }

  func testCancellationDuringPreparationDoesNotPrefill() async throws {
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      let gate = PreparationGate()
      let fixture = await Self.fixture(gate: gate)
      let session = ChatSession(
        fixture.container, generateParameters: .init(maxTokens: 32_768, temperature: 0))
      let budget = MLXContextBudget(capacity: 16_384, configuredMaximum: 32_768)
      let stream = budget.streamDetails(session: session, messages: [.user("document")])
      let task = Task { try await Self.collect(stream) }
      await gate.waitUntilStarted()
      task.cancel()
      await gate.release()
      do { _ = try await task.value } catch is CancellationError {}
      _ = try await session.cacheStatus()
      XCTAssertTrue(fixture.log.snapshot.prefills.isEmpty)
      XCTAssertEqual(fixture.log.snapshot.trims, 0)
      XCTAssertEqual(session.generateParameters.maxTokens, 32_768)
    }
  }

  private struct ValidationFailure: Error {}

  private static func collect(_ stream: AsyncThrowingStream<Generation, Error>) async throws
    -> GenerateCompletionInfo?
  {
    var info: GenerateCompletionInfo?
    for try await generation in stream {
      if case .info(let value) = generation { info = value }
    }
    return info
  }

  private static func fixture(retryPadding: Int = 0, gate: PreparationGate? = nil) async -> (
    container: ModelContainer, log: InputLog
  ) {
    let log = InputLog()
    let context = ModelContext(
      configuration: ModelConfiguration(id: "context-budget-test"),
      model: CountingModel(log: log),
      processor: InputProcessor(log: log, retryPadding: retryPadding, gate: gate),
      tokenizer: TestTokenizer()
    )
    let container = ModelContainer(context: context)
    await MLXContextBudget.install(on: container)
    return (container, log)
  }

  private struct InputSnapshot: Sendable {
    var prefills: [Int] = []
    var trims = 0
    var preparedContents: [String] = []
    var imageCounts: [Int] = []
  }

  private final class InputLog: Sendable {
    let storage = Mutex(InputSnapshot())
    var snapshot: InputSnapshot { storage.withLock { $0 } }
  }

  private struct InputProcessor: UserInputProcessor {
    let log: InputLog
    let retryPadding: Int
    let gate: PreparationGate?

    func prepare(input: UserInput) async throws -> LMInput {
      let messages = DefaultMessageGenerator().generate(from: input)
      var tokens = try TestTokenizer().applyChatTemplate(
        messages: messages, tools: input.tools, additionalContext: input.additionalContext
      )
      let attempt = log.storage.withLock { state in
        state.preparedContents.append(
          messages.map { $0["content"] as? String ?? "" }.joined(separator: "|"))
        state.imageCounts.append(input.images.count)
        return state.preparedContents.count
      }
      tokens += Array(
        repeating: 1, count: input.images.count * 40 + (attempt == 2 ? retryPadding : 0))
      await gate?.pause()
      return LMInput(
        text: .init(tokens: MLXArray(tokens)),
        image: input.images.isEmpty ? nil : .init(pixels: MLXArray.zeros([1, 1, 1, 1]))
      )
    }
  }

  private final class CountingModel: Module, LanguageModel {
    let log: InputLog
    private var nextToken = 2
    init(log: InputLog) {
      self.log = log
      super.init()
    }
    func newCache(parameters _: GenerateParameters?) -> [KVCache] { [CountingCache(log: log)] }
    func prepare(
      _ input: LMInput, cache _: [KVCache], state _: LMOutput.State?, prefill _: PrefillParameters
    ) -> PrepareResult {
      log.storage.withLock { $0.prefills.append(input.text.tokens.size) }
      nextToken = 2
      return .tokens(input.text)
    }
    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
      (cache?.first as? CountingCache)?.offset += inputs.size
      let token = nextToken
      nextToken = 7
      return MLXArray((0..<8).map { Float($0 == token ? 1 : 0) }).reshaped([1, 1, 8])
    }
  }

  private final class CountingCache: KVCache {
    let log: InputLog
    var offset = 0
    var maxSize: Int? { nil }
    var state: [MLXArray] = []
    var metaState: [String] = []
    var isTrimmable: Bool { true }
    init(log: InputLog) { self.log = log }
    func innerState() -> [MLXArray] { state }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
      offset += keys.dim(2)
      return (keys, values)
    }
    func makeMask(n _: Int, windowSize _: Int?, returnArray _: Bool)
      -> MLXFast.ScaledDotProductAttentionMaskMode
    { .none }
    func copy() -> any KVCache {
      let copy = CountingCache(log: log)
      copy.offset = offset
      return copy
    }
    func trim(_ count: Int) -> Int {
      log.storage.withLock { $0.trims += 1 }
      let removed = min(count, offset)
      offset -= removed
      return removed
    }
  }

  private struct TestTokenizer: Tokenizer {
    var bosToken: String? { nil }
    var eosToken: String? { "end" }
    var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens _: Bool) -> [Int] {
      text.utf8.map { $0 == 120 ? 2 : Int($0) + 20 }
    }
    func decode(tokenIds: [Int], skipSpecialTokens _: Bool) -> String {
      String(repeating: "x", count: tokenIds.filter { $0 == 2 }.count)
    }
    func convertTokenToId(_ token: String) -> Int? { token == "end" ? 7 : nil }
    func convertIdToToken(_: Int) -> String? { nil }
    func applyChatTemplate(
      messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
      additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
      var tokens: [Int] = []
      for message in messages {
        let role = message["role"] as? String ?? ""
        tokens += [role == "assistant" ? 10 : 11]
        tokens += encode(text: message["content"] as? String ?? "", addSpecialTokens: false)
        if role != "assistant" { tokens += [12] }
      }
      tokens += [10]
      if tools != nil { tokens += Array(repeating: 1, count: 20) }
      if additionalContext?["enable_thinking"] as? Bool == true { tokens += [13, 14, 15] }
      return tokens
    }
  }

  private actor PreparationGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
      started = true
      for waiter in startedWaiters { waiter.resume() }
      startedWaiters.removeAll()
      await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
      if started { return }
      await withCheckedContinuation { startedWaiters.append($0) }
    }
    func release() {
      continuation?.resume()
      continuation = nil
    }
  }
}
