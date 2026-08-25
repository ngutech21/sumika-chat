import Foundation
import MLXLMCommon
import SumikaCore
import Synchronization
import Testing

@testable import SumikaRuntimeMLX

struct MLXGenerationActivityTests {
  @Test
  func activityStartsBeforeUpstreamStreamAndEndsOnce() {
    let recorder = ActivityLifecycleRecorder()
    let activity = testActivity(recorder: recorder)

    let started = activity.start {
      recorder.record("source")
      return "stream"
    }

    #expect(started.stream == "stream")
    #expect(recorder.events == ["begin", "source"])

    started.activityLease.end()
    started.activityLease.end()

    #expect(recorder.events == ["begin", "source", "end"])
  }

  @Test
  func activityCanBeDisabledForControlledComparison() {
    let started = MLXGenerationActivity.configured(
      environment: ["SUMIKA_GENERATION_ACTIVITY": "disabled"]
    ).start {
      "stream"
    }

    #expect(started.stream == "stream")
    #expect(started.activityLease.request == .none)
  }

  @Test(arguments: StreamScenario.allCases)
  func processorEndsActivityAfterTerminalTrace(scenario: StreamScenario) async throws {
    let activityRecorder = ActivityLifecycleRecorder()
    let activity = testActivity(recorder: activityRecorder)
    let source = source(for: scenario)
    let started = activity.start {
      activityRecorder.record("source")
      return source
    }
    let traceRecorder = TerminalTraceRecorder(activityRecorder: activityRecorder)
    let traceID = UUID()
    let plan = MLXModelStreamProcessor.modelStreamPlan(
      from: started.stream,
      traceID: traceID,
      traceMetadata: TurnTraceMetadata(
        turnID: nil,
        generationID: traceID,
        tracer: traceRecorder
      ),
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      generationStartedAt: started.startedAt,
      generationActivityLease: started.activityLease,
      applicationStateSnapshotProvider: {
        RuntimeApplicationStateSnapshot(
          applicationActivation: .inactive,
          applicationVisibility: .shown,
          applicationOcclusion: .occluded,
          mainWindowVisibility: .notVisible
        )
      },
      markCompleted: { _ in },
      markNativeToolCallBoundary: { _, _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    do {
      for try await _ in plan.stream {}
      #expect(!scenario.throwsToConsumer)
    } catch {
      #expect(scenario.throwsToConsumer)
    }
    await plan.task.value

    let terminal = try #require(await traceRecorder.terminalEvent)
    #expect(terminal.runtimeStreamOutcome == scenario.outcome)
    #expect(terminal.applicationActivation == .inactive)
    #expect(terminal.applicationVisibility == .shown)
    #expect(terminal.applicationOcclusion == .occluded)
    #expect(terminal.mainWindowVisibility == .notVisible)
    #expect(
      terminal.generationActivityRequest == .userInitiatedAllowingIdleSystemSleep
    )
    #expect(activityRecorder.events == ["begin", "source", "terminal", "end"])
  }

  private func testActivity(
    recorder: ActivityLifecycleRecorder
  ) -> MLXGenerationActivity {
    MLXGenerationActivity(
      begin: {
        recorder.record("begin")
        return MLXGenerationActivityLease(
          request: .userInitiatedAllowingIdleSystemSleep,
          end: {
            recorder.record("end")
          }
        )
      }
    )
  }

  private func source(
    for scenario: StreamScenario
  ) -> AsyncThrowingStream<Generation, Error> {
    AsyncThrowingStream { continuation in
      switch scenario {
      case .completed:
        continuation.yield(.chunk("done"))
        continuation.yield(.info(completionInfo()))
        continuation.finish()
      case .cancelled:
        continuation.yield(
          .info(
            GenerateCompletionInfo(
              promptTokenCount: 8,
              generationTokenCount: 1,
              promptTime: 0.1,
              generationTime: 0.1,
              stopReason: .cancelled
            )))
        continuation.finish()
      case .failed:
        continuation.finish(throwing: ExpectedStreamError())
      case .toolCallBoundary:
        continuation.yield(
          .toolCall(
            ToolCall(
              function: .init(name: "read_file", arguments: ["path": "README.md"])
            )))
        continuation.finish()
      }
    }
  }

  private func completionInfo() -> GenerateCompletionInfo {
    GenerateCompletionInfo(
      promptTokenCount: 8,
      generationTokenCount: 1,
      promptTime: 0.1,
      generationTime: 0.1
    )
  }

  private func defaultCacheTrace() -> MLXSessionCacheTrace {
    MLXSessionCacheTrace(
      cacheMode: .newSession,
      cacheReason: .newSessionNoCache,
      contextSignature: "context",
      previousContextSignature: nil,
      appendOnly: false,
      reusedMessageCount: 0,
      appendedMessageCount: 0,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil
    )
  }

  private func temporaryDebugTraceStore() -> MLXDebugTraceStore {
    MLXDebugTraceStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory),
      isEnabled: { false }
    )
  }
}

enum StreamScenario: CaseIterable, Sendable {
  case completed
  case cancelled
  case failed
  case toolCallBoundary

  var outcome: RuntimeStreamOutcome {
    switch self {
    case .completed:
      .completed
    case .cancelled:
      .cancelled
    case .failed:
      .failed
    case .toolCallBoundary:
      .toolCallBoundary
    }
  }

  var throwsToConsumer: Bool {
    switch self {
    case .cancelled, .failed:
      true
    case .completed, .toolCallBoundary:
      false
    }
  }
}

nonisolated private final class ActivityLifecycleRecorder: Sendable {
  private let storage = Mutex<[String]>([])

  var events: [String] {
    storage.withLock { $0 }
  }

  func record(_ event: String) {
    storage.withLock { $0.append(event) }
  }
}

private actor TerminalTraceRecorder: TurnTracing {
  private let activityRecorder: ActivityLifecycleRecorder
  private var events: [TurnTraceEvent] = []

  init(activityRecorder: ActivityLifecycleRecorder) {
    self.activityRecorder = activityRecorder
  }

  var terminalEvent: TurnTraceEvent? {
    events.first { $0.phase == .runtimeStreamEnd }
  }

  func recordTurnTraceEvent(_ event: TurnTraceEvent) {
    events.append(event)
    if event.phase == .runtimeStreamEnd {
      activityRecorder.record("terminal")
    }
  }
}

private struct ExpectedStreamError: Error {}
