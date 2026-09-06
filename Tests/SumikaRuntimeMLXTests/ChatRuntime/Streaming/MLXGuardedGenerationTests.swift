import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MachO
import Synchronization
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

nonisolated final class MLXGuardedGenerationTests: XCTestCase {
  func testNativeFailureProbesInIsolatedProcesses() async throws {
    let library = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let library, FileManager.default.fileExists(atPath: library.path) else {
      throw XCTSkip("MLX default.metallib is unavailable in the test bundle.")
    }
    for probe in [
      "preparation", "decode", "late_sync", "checked_eval", "isolation", "cancellation",
    ] {
      try await runIsolatedProbe(probe)
    }
  }

  func testNativeFailureProbe() async throws {
    guard let probe = ProcessInfo.processInfo.environment["SUMIKA_MLX_FAILURE_PROBE"] else {
      throw XCTSkip("Native MLX faults run only in the isolated child process.")
    }
    try await Device.withDefaultDevice(.cpu) { @Sendable in
      try await Stream.withNewDefaultStream(device: .cpu) { @Sendable in
        switch probe {
        case "preparation": try await Self.verifyRuntimeRecovery(fault: .preparation)
        case "decode": try await Self.verifyRuntimeRecovery(fault: .decode)
        case "late_sync": try await Self.verifyLateSynchronizationFailure()
        case "checked_eval": try await Self.verifyCheckedErrorPrecedesSynchronizationError()
        case "isolation": try await Self.verifyHandlerIsolation()
        case "cancellation": try await Self.verifyCancellationDrains()
        default: XCTFail("Unknown probe: \(probe)")
        }
      }
    }
  }

  private func runIsolatedProbe(_ probe: String) async throws {
    let logURL = FileManager.default.temporaryDirectory.appending(path: "mlx-probe-\(UUID()).log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer {
      try? log.close()
      try? FileManager.default.removeItem(at: logURL)
    }
    let process = Process()
    // Reuse the test runner directly so xcrun does not strip sanitizer environment variables.
    process.executableURL = URL(filePath: CommandLine.arguments[0])
    process.arguments = [
      "-XCTest",
      "SumikaRuntimeMLXTests.MLXGuardedGenerationTests/testNativeFailureProbe",
      Bundle(for: Self.self).bundlePath,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["SUMIKA_MLX_FAILURE_PROBE"] = probe
    // XCTest loads this bundle dynamically; TSan must already be active in the child.
    if let sanitizer = (0..<_dyld_image_count()).compactMap({ index in
      _dyld_get_image_name(index).map { String(cString: $0) }
    }).first(where: { $0.contains("libclang_rt.tsan_") }) {
      let existing = environment["DYLD_INSERT_LIBRARIES"].map { ":" + $0 } ?? ""
      environment["DYLD_INSERT_LIBRARIES"] = sanitizer + existing
    }
    process.environment = environment
    process.standardOutput = log
    process.standardError = log
    try process.run()
    let deadline = Date().addingTimeInterval(45)
    while process.isRunning, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    if process.isRunning {
      process.terminate()
      XCTFail("MLX \(probe) probe did not drain within 45 seconds.")
      return
    }
    let output = try String(contentsOf: logURL, encoding: .utf8)
    XCTAssertEqual(process.terminationStatus, 0, "MLX \(probe) probe failed:\n\(output)")
    XCTAssertTrue(output.contains("Executed 1 test"), "Probe did not execute:\n\(output)")
  }

  private static func verifyRuntimeRecovery(fault: FailureProbeControl.Fault) async throws {
    let control = FailureProbeControl(fault: fault)
    let root = FileManager.default.temporaryDirectory.appending(path: "mlx-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let traceURL = root.appending(path: "trace.jsonl")
    let trace = MLXDebugTraceStore(fileURL: traceURL, isEnabled: { true })
    let runtime = MLXChatRuntime(
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        if reason == .runtimeError {
          XCTAssertEqual(control.liveCaches, 0, "Live KV arrays must be released before the pool.")
          XCTAssertTrue(control.events.contains("fault_returned"))
          control.record("memory_cleared")
        }
        Memory.clearCache()
      },
      debugTraceStore: trace,
      modelContainer: ModelContainer(context: makeContext(control: control))
    )
    let prompt = try ModelFacingPromptRenderer.userPromptEntry(prompt: "Reply briefly.")
    let plan = ChatRuntimePromptPlan(stableInstructions: "Test instructions.")
    let settings = ChatGenerationSettings(temperature: 0, topP: 1, topK: 0, maxTokens: 64)
    var partial = ""
    var completed = 0
    var failures = 0
    do {
      let stream = try await runtime.streamReply(
        for: ModelPromptProjection(entries: [prompt]), attachments: [], promptPlan: plan,
        settings: settings, interactionMode: .chat)
      for try await event in stream {
        switch event {
        case .chunk(let text):
          partial += text
          control.outputReceived.signal()
        case .completed, .outputLimitReached: completed += 1
        case .toolCall: XCTFail("A failed producer must not deliver pending tools.")
        case .thinkingChunk, .thinkingCompleted: break
        }
      }
      XCTFail("Expected the native MLX diagnostic.")
    } catch let error as MLXError {
      failures += 1
      XCTAssertEqual(error, firstDiagnostic())
    }
    XCTAssertEqual(failures, 1)
    XCTAssertEqual(completed, 0)
    XCTAssertEqual(partial.isEmpty, fault == .preparation)
    XCTAssertEqual(control.liveCaches, 0)
    XCTAssertEqual(control.events.filter { $0 == "memory_cleared" }.count, 1)
    let released = try XCTUnwrap(control.events.lastIndex(of: "cache_released"))
    let cleared = try XCTUnwrap(control.events.firstIndex(of: "memory_cleared"))
    XCTAssertLessThan(released, cleared)

    let previousCaches = control.createdCaches
    control.disableFault()
    let stream = try await runtime.streamReply(
      for: ModelPromptProjection(entries: [prompt]), attachments: [], promptPlan: plan,
      settings: settings, interactionMode: .chat)
    var recovered = ""
    for try await event in stream {
      if case .chunk(let text) = event { recovered += text }
      if case .completed = event { completed += 1 }
    }
    XCTAssertFalse(recovered.isEmpty)
    XCTAssertEqual(completed, 1)
    XCTAssertGreaterThan(control.createdCaches, previousCaches)
    XCTAssertEqual(control.liveCaches, 1)
    let fresh = await runtime.runtimeCacheDebugSnapshot()
    XCTAssertEqual(fresh?.cacheReason, "invalidated_generation_runtime_error")

    let warmCaches = control.usedCaches
    let followup = [
      prompt, try ModelFacingPromptRenderer.assistantOutputEntry(content: recovered),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "Again."),
    ]
    let warm = try await runtime.streamReply(
      for: ModelPromptProjection(entries: followup), attachments: [], promptPlan: plan,
      settings: settings, interactionMode: .agent)
    for try await _ in warm {}
    XCTAssertEqual(control.usedCaches, warmCaches, "Successful generation must reuse the cache.")
    await runtime.unload()
    XCTAssertEqual(control.liveCaches, 0)
    let rows = try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
    }
    let failedEnds = rows.filter {
      $0["phase"] as? String == "runtime_stream_end"
        && $0["runtimeStreamOutcome"] as? String == "failed"
    }
    XCTAssertEqual(failedEnds.count, 1)
  }

  private static func verifyLateSynchronizationFailure() async throws {
    let control = FailureProbeControl()
    nonisolated(unsafe) let session = ChatSession(
      makeContext(control: control), generateParameters: .init(maxTokens: 64, temperature: 0))
    let generation = MLXGuardedGeneration(
      makeStream: { session.streamDetails(to: [.user("Test")]) },
      synchronize: {
        await session.synchronize()
        StreamOrDevice.default.stream.synchronize()
        control.record("synchronized")
        triggerNativeFaults()
      }
    )
    let plan = MLXModelStreamProcessor.modelStreamPlan(
      from: generation, traceID: UUID(), traceMetadata: nil,
      cacheTrace: MLXSessionCacheTrace(
        cacheMode: .newSession, cacheReason: .newSessionNoCache, contextSignature: "probe",
        previousContextSignature: nil, appendOnly: false, reusedMessageCount: 0,
        appendedMessageCount: 1, mismatchReason: nil, firstMismatchIndex: nil,
        systemPromptChanged: nil),
      debugTraceStore: MLXDebugTraceStore(isEnabled: { false }),
      markCompleted: { _ in control.record("completed") },
      markCancelled: { reason in
        XCTAssertEqual(reason, .runtimeError)
        await session.clear()
        control.record("failed")
      },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in
        XCTAssertEqual(control.liveCaches, 0)
        control.record("memory_cleared")
      })
    var infos = 0
    do {
      for try await event in plan.stream {
        if case .completed = event { infos += 1 }
      }
      XCTFail("Late synchronization error was lost.")
    } catch let error as MLXError {
      XCTAssertEqual(error, firstDiagnostic())
    }
    await plan.task.value
    XCTAssertEqual(control.events.filter { $0 == "failed" }.count, 1)
    XCTAssertFalse(control.events.contains("completed"))
    XCTAssertEqual(control.events.last, "memory_cleared")
    XCTAssertEqual(infos, 0)
    XCTAssertTrue(control.events.contains("synchronized"))
    await session.clear()
    XCTAssertEqual(control.liveCaches, 0)
  }

  private static func verifyHandlerIsolation() async throws {
    async let failed: Void = verifyRuntimeRecovery(fault: .preparation)
    async let healthy: Void = verifyHealthyGeneration()
    _ = try await (failed, healthy)
  }

  private static func verifyCheckedErrorPrecedesSynchronizationError() async throws {
    let generation = MLXGuardedGeneration(
      makeStream: {
        AsyncThrowingStream { continuation in
          Task {
            do {
              try MLX.withError { _ = MLXArray([1, 2]).reshaped([3]) }
              continuation.finish()
            } catch { continuation.finish(throwing: error) }
          }
        }
      },
      synchronize: { _ = MLXArray([1, 2]).reshaped([5]) }
    )
    do {
      for try await _ in generation.stream {}
      XCTFail("Expected checked MLX error.")
    } catch let error as MLXError {
      XCTAssertEqual(error, firstDiagnostic())
    }
    await generation.drain()
  }

  private static func verifyHealthyGeneration() async throws {
    let control = FailureProbeControl()
    let session = ChatSession(
      makeContext(control: control), generateParameters: .init(maxTokens: 64, temperature: 0))
    let generation = MLXGuardedGeneration(session: session, messages: [.user("Test")])
    var completions = 0
    for try await event in generation.stream where event.info != nil {
      completions += 1
    }
    await generation.drain()
    XCTAssertEqual(completions, 1)
    XCTAssertNil(generation.capturedError)
    await session.clear()
  }

  private static func verifyCancellationDrains() async throws {
    let (source, producer) = AsyncThrowingStream<Generation, Error>.makeStream()
    let (cancelled, cancellation) = AsyncStream<Void>.makeStream()
    let gate = FailureProbeDrainGate()
    producer.onTermination = { _ in cancellation.yield(()) }
    let control = FailureProbeControl()
    let generation = MLXGuardedGeneration(
      makeStream: { source },
      synchronize: {
        await gate.wait()
        control.record("drained")
      }
    )
    let first = Task { await generation.cancelAndDrain() }
    var cancelledIterator = cancelled.makeAsyncIterator()
    _ = await cancelledIterator.next()
    let second = Task { await generation.cancelAndDrain() }
    XCTAssertTrue(control.events.isEmpty)
    await gate.release()
    await first.value
    await second.value
    XCTAssertEqual(control.events, ["drained"])
    XCTAssertNil(generation.capturedError)
  }

  private static func makeContext(control: FailureProbeControl) -> ModelContext {
    ModelContext(
      configuration: ModelConfiguration(id: "sumika-failure-probe"),
      model: FailureProbeModel(control: control), processor: FailureProbeProcessor(),
      tokenizer: FailureProbeTokenizer())
  }

  private static func firstDiagnostic() -> MLXError? {
    do {
      try MLX.withError { _ = MLXArray([1, 2]).reshaped([3]) }
      return nil
    } catch { return error as? MLXError }
  }

  fileprivate static func triggerNativeFaults() {
    // Invalid shapes fail in the native C bridge without allocating large buffers.
    // Do not consume either invalid result; the pinned iterator still receives valid logits.
    _ = MLXArray([1, 2]).reshaped([3])
    _ = MLXArray([1, 2]).reshaped([5])
  }
}

nonisolated private final class FailureProbeControl: Sendable {
  enum Fault: Sendable { case preparation, decode }
  private struct State {
    var fault: Fault?
    var calls = 0
    var liveCaches = 0
    var createdCaches = 0
    var usedCaches: Set<UUID> = []
    var events: [String] = []
  }
  private let state: Mutex<State>
  let outputReceived = DispatchSemaphore(value: 0)
  init(fault: Fault? = nil) { state = Mutex(State(fault: fault)) }
  var fault: Fault? { state.withLock { $0.fault } }
  var liveCaches: Int { state.withLock { $0.liveCaches } }
  var createdCaches: Int { state.withLock { $0.createdCaches } }
  var usedCaches: Set<UUID> { state.withLock { $0.usedCaches } }
  var events: [String] { state.withLock { $0.events } }
  func record(_ event: String) { state.withLock { $0.events.append(event) } }
  func disableFault() { state.withLock { $0.fault = nil } }
  func begin() { state.withLock { $0.calls = 0 } }
  func next() -> Int {
    state.withLock {
      $0.calls += 1
      return $0.calls
    }
  }
  func created() {
    state.withLock {
      $0.liveCaches += 1
      $0.createdCaches += 1
    }
  }
  func used(_ id: UUID) { _ = state.withLock { $0.usedCaches.insert(id) } }
  func released() {
    state.withLock {
      $0.liveCaches -= 1
      $0.events.append("cache_released")
    }
  }
}

nonisolated private final class FailureProbeModel: Module, LanguageModel {
  let control: FailureProbeControl
  init(control: FailureProbeControl) { self.control = control }
  func newCache(parameters _: GenerateParameters?) -> [KVCache] {
    [FailureProbeCache(control: control)]
  }
  func prepare(
    _ input: LMInput, cache _: [KVCache], state _: LMOutput.State?, prefill _: PrefillParameters
  ) throws -> PrepareResult {
    control.begin()
    if control.fault == .preparation {
      MLXGuardedGenerationTests.triggerNativeFaults()
      control.record("fault_returned")
    }
    return .tokens(input.text)
  }
  func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
    let count = control.next()
    if control.fault == .decode, count == 8 {
      XCTAssertEqual(control.outputReceived.wait(timeout: .now() + 5), .success)
      MLXGuardedGenerationTests.triggerNativeFaults()
      control.record("fault_returned")
    }
    let values = MLXArray.zeros([1, 1, inputs.dim(-1), 1])
    _ = cache?.first?.update(keys: values, values: values)
    return MLXArray(count >= 20 ? [10.0, 0.0, 0.0] : [0.0, 10.0, 0.0])
      .reshaped([1, 1, 3])
  }
}

nonisolated private final class FailureProbeCache: KVCache {
  let control: FailureProbeControl
  private let storage = KVCacheSimple()
  private let id = UUID()
  var offset: Int { storage.offset }
  var maxSize: Int? { nil }
  func innerState() -> [MLXArray] { storage.innerState() }
  func copy() -> any KVCache {
    let copied = FailureProbeCache(control: control)
    copied.state = storage.state
    copied.metaState = storage.metaState
    return copied
  }
  func makeMask(n count: Int, windowSize: Int?, returnArray: Bool)
    -> MLXFast.ScaledDotProductAttentionMaskMode
  {
    storage.makeMask(n: count, windowSize: windowSize, returnArray: returnArray)
  }
  init(control: FailureProbeControl) {
    self.control = control
    control.created()
  }
  deinit { control.released() }
  var state: [MLXArray] {
    get { storage.state }
    set { storage.state = newValue }
  }
  var metaState: [String] {
    get { storage.metaState }
    set { storage.metaState = newValue }
  }
  var isTrimmable: Bool { true }
  func trim(_ count: Int) -> Int {
    let trimmed = storage.trim(count)
    return trimmed
  }
  func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
    control.used(id)
    let result = storage.update(keys: keys, values: values)
    return result
  }
}

nonisolated private struct FailureProbeProcessor: UserInputProcessor {
  func prepare(input: UserInput) throws -> LMInput {
    let messages = DefaultMessageGenerator().generate(from: input)
    let tokens = FailureProbeTokenizer().applyChatTemplate(
      messages: messages, tools: input.tools, additionalContext: input.additionalContext)
    return LMInput(tokens: MLXArray(tokens))
  }
}

nonisolated private struct FailureProbeTokenizer: Tokenizer {
  var bosToken: String? { nil }
  var eosToken: String? { "<eos>" }
  var unknownToken: String? { nil }
  func encode(text: String, addSpecialTokens _: Bool) -> [Int] {
    text.split(separator: " ").map { $0 == "word" ? 1 : 2 }
  }
  func decode(tokenIds: [Int], skipSpecialTokens _: Bool) -> String {
    String(repeating: "word ", count: tokenIds.count)
  }
  func convertTokenToId(_ token: String) -> Int? { token == "<eos>" ? 0 : nil }
  func convertIdToToken(_ id: Int) -> String? { id == 0 ? "<eos>" : "word " }
  func applyChatTemplate(
    messages: [[String: any Sendable]], tools _: [[String: any Sendable]]?,
    additionalContext _: [String: any Sendable]?
  ) -> [Int] {
    var tokens: [Int] = []
    for message in messages {
      tokens.append(2)
      tokens += encode(text: message["content"] as? String ?? "", addSpecialTokens: false)
      if message["role"] as? String != "assistant" { tokens.append(2) }
    }
    return tokens + [2]
  }
}

private actor FailureProbeDrainGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func wait() async {
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
