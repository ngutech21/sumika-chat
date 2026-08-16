import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-model-lifecycle-tests"))
struct ModelLifecycleCoordinatorTests {
  @Test
  func deletingInactiveModelRemovesCompleteDirectoryAndPreservesSiblings() async throws {
    let baseURL = try makeModelsBaseURL()
    let model = makeModel(localDirectoryName: "target-model")
    let modelDirectory = baseURL.appending(
      path: model.localDirectoryName,
      directoryHint: .isDirectory
    )
    let nestedDirectory = modelDirectory.appending(path: "nested", directoryHint: .isDirectory)
    let siblingDirectory = baseURL.appending(path: "sibling-model", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: siblingDirectory, withIntermediateDirectories: true)
    try "weights".write(
      to: nestedDirectory.appending(path: "weights.bin", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let runtime = LifecycleDeletionRecordingRuntime()
    let coordinator = makeCoordinator(runtime: runtime, baseURL: baseURL)

    try await coordinator.deleteDownloadedModel(
      model,
      unloadOperationID: nil,
      runtimeUnloadWillBegin: {}
    )

    #expect(!FileManager.default.fileExists(atPath: modelDirectory.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: siblingDirectory.path(percentEncoded: false)))
    #expect(await runtime.unloadCount == 0)
  }

  @Test
  func deletingActiveModelFinishesRuntimeUnloadBeforeRemovingFiles() async throws {
    let baseURL = try makeModelsBaseURL()
    let model = makeModel(localDirectoryName: "active-model")
    let modelDirectory = baseURL.appending(
      path: model.localDirectoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    let events = LockedLifecycleDeletionEvents()
    let runtime = LifecycleDeletionRecordingRuntime(events: events)
    let operationID = UUID()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: operationID
    )
    let coordinator = ModelLifecycleCoordinator(
      modelDownloader: UnavailableModelDownloader(),
      runtimeOperations: runtimeOperations,
      modelAvailability: { _ in false },
      modelDirectoryBaseURL: baseURL,
      modelDirectoryRemover: { url in
        events.append("remove")
        try FileManager.default.removeItem(at: url)
      }
    )

    try await coordinator.deleteDownloadedModel(
      model,
      unloadOperationID: operationID,
      runtimeUnloadWillBegin: {
        events.append("will-unload")
      }
    )

    #expect(events.snapshot == ["will-unload", "unload", "remove"])
    #expect(!FileManager.default.fileExists(atPath: modelDirectory.path(percentEncoded: false)))
  }

  @Test
  func deletionRejectsDirectoriesThatAreNotDirectChildrenOfManagedBase() async throws {
    let baseURL = try makeModelsBaseURL()
    let outsideDirectory = baseURL.deletingLastPathComponent().appending(
      path: "outside-model",
      directoryHint: .isDirectory
    )
    let nestedDirectory = baseURL.appending(
      path: "nested/model",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    let coordinator = makeCoordinator(
      runtime: LifecycleDeletionRecordingRuntime(),
      baseURL: baseURL
    )

    for localDirectoryName in ["../outside-model", "nested/model"] {
      await #expect(throws: LocalModelDirectoryError.self) {
        try await coordinator.deleteDownloadedModel(
          makeModel(localDirectoryName: localDirectoryName),
          unloadOperationID: nil,
          runtimeUnloadWillBegin: {}
        )
      }
    }

    #expect(FileManager.default.fileExists(atPath: outsideDirectory.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: nestedDirectory.path(percentEncoded: false)))
  }

  @Test
  func deletionReportsRemovalFailureWithoutRemovingDirectory() async throws {
    let baseURL = try makeModelsBaseURL()
    let model = makeModel(localDirectoryName: "failed-model")
    let modelDirectory = baseURL.appending(
      path: model.localDirectoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: LifecycleDeletionRecordingRuntime()
    )
    let coordinator = ModelLifecycleCoordinator(
      modelDownloader: UnavailableModelDownloader(),
      runtimeOperations: runtimeOperations,
      modelAvailability: { _ in false },
      modelDirectoryBaseURL: baseURL,
      modelDirectoryRemover: { _ in
        throw LifecycleDeletionTestError.removalFailed
      }
    )

    await #expect(throws: LifecycleDeletionTestError.removalFailed) {
      try await coordinator.deleteDownloadedModel(
        model,
        unloadOperationID: nil,
        runtimeUnloadWillBegin: {}
      )
    }

    #expect(FileManager.default.fileExists(atPath: modelDirectory.path(percentEncoded: false)))
  }

  private func makeCoordinator(
    runtime: any ChatModelRuntime,
    baseURL: URL
  ) -> ModelLifecycleCoordinator {
    ModelLifecycleCoordinator(
      modelDownloader: UnavailableModelDownloader(),
      runtimeOperations: RuntimeOperationCoordinator(runtime: runtime),
      modelAvailability: { _ in false },
      modelDirectoryBaseURL: baseURL
    )
  }

  private func makeModelsBaseURL() throws -> URL {
    let baseURL = try scopedTemporaryDirectory().appending(
      path: "Models",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    return baseURL
  }

  private func makeModel(localDirectoryName: String) -> ManagedModel {
    ManagedModel(
      id: "model-\(localDirectoryName)",
      displayName: "Test model",
      detail: "Model deletion fixture",
      huggingFaceRepoID: "example/model",
      localDirectoryName: localDirectoryName,
      estimatedDownloadSize: "1 MB",
      group: .specialized,
      requiresLargeMemory: false,
      stability: .stable,
      supportsImageInput: false,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: 1024
    )
  }
}

private enum LifecycleDeletionTestError: Error {
  case removalFailed
}

private final class LockedLifecycleDeletionEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []

  var snapshot: [String] {
    lock.withLock { events }
  }

  func append(_ event: String) {
    lock.withLock {
      events.append(event)
    }
  }
}

private actor LifecycleDeletionRecordingRuntime: ChatModelRuntime {
  private let events: LockedLifecycleDeletionEvents?
  private(set) var unloadCount = 0

  init(events: LockedLifecycleDeletionEvents? = nil) {
    self.events = events
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {
    unloadCount += 1
    events?.append("unload")
  }

  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    _ = interactionMode
    return AsyncThrowingStream { $0.finish() }
  }
}
