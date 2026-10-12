import Foundation
import Testing

@testable import SumikaApp

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif

@MainActor
struct ComposerSpeechInputControllerTests {
  @Test
  func audioModelNotReadyRoutesToAudioModels() async throws {
    let service = FakeSpeechInputService(startError: ComposerSpeechInputError.audioModelNotReady)
    let controller = ComposerSpeechInputController(service: service)
    var didOpenAudioModels = false

    controller.start(
      onTranscript: { _ in },
      onNeedsAudioModel: {
        didOpenAudioModels = true
      }
    )

    try await waitForComposerSpeechCondition {
      didOpenAudioModels
    }

    #expect(service.startCount == 1)
    #expect(controller.phase == .idle)
  }

  @Test
  func installedAudioModelStartsRecording() async throws {
    let service = FakeSpeechInputService()
    let controller = ComposerSpeechInputController(service: service)

    controller.start(
      onTranscript: { _ in },
      onNeedsAudioModel: {}
    )

    try await waitForComposerSpeechCondition {
      controller.phase.isRecording && service.prepareModelCount == 1
    }

    #expect(service.startCount == 1)
    #expect(service.prepareModelCount == 1)
    controller.cancel()
  }

  @Test
  func recordingStartsWhileSpeechModelIsStillLoading() async throws {
    let service = FakeSpeechInputService(suspendsModelPreparation: true)
    let controller = ComposerSpeechInputController(service: service)

    controller.start(
      onTranscript: { _ in },
      onNeedsAudioModel: {}
    )

    try await waitForComposerSpeechCondition {
      guard case .recording(_, .loading) = controller.phase else {
        return false
      }
      return service.prepareModelCount == 1
    }

    #expect(controller.statusText?.hasPrefix("Loading model") == true)

    service.finishModelPreparation()

    try await waitForComposerSpeechCondition {
      guard case .recording(_, .ready) = controller.phase else {
        return false
      }
      return true
    }

    controller.cancel()
  }

  @Test
  func stoppingWhileModelLoadsShowsWhatFinalizationIsWaitingFor() async throws {
    let service = FakeSpeechInputService(
      stopText: "dictated text",
      suspendsModelPreparation: true,
      stopWaitsForModelPreparation: true
    )
    let controller = ComposerSpeechInputController(service: service)
    var transcript: String?

    controller.start(
      onTranscript: { transcript = $0 },
      onNeedsAudioModel: {}
    )

    try await waitForComposerSpeechCondition {
      guard case .recording(_, .loading) = controller.phase else {
        return false
      }
      return true
    }

    controller.stop { transcript = $0 }

    #expect(controller.phase == .finalizing(.waitingForModel))
    #expect(controller.statusText == "Waiting for model")

    service.finishModelPreparation()

    try await waitForComposerSpeechCondition {
      transcript == "dictated text" && controller.phase == .idle
    }
  }

  @Test
  func speechModelLoadFailureStopsCaptureAndShowsTheError() async throws {
    let service = FakeSpeechInputService(
      prepareModelError: TestComposerSpeechError.modelLoadFailed
    )
    let controller = ComposerSpeechInputController(service: service)

    controller.start(
      onTranscript: { _ in },
      onNeedsAudioModel: {}
    )

    try await waitForComposerSpeechCondition {
      controller.phase == .failed("Model load failed")
    }

    #expect(service.cancelCount == 1)
    #expect(controller.statusText == "Model load failed")
  }

  @Test
  func cancelWhileStartingDoesNotResumeRecording() async throws {
    let service = FakeSpeechInputService(suspendsStart: true)
    let controller = ComposerSpeechInputController(service: service)

    controller.start(
      onTranscript: { _ in },
      onNeedsAudioModel: {}
    )

    try await waitForComposerSpeechCondition {
      service.startCount == 1 && controller.phase == .startingMicrophone
    }

    controller.cancel()

    try await waitForComposerSpeechCondition {
      service.cancelCount == 1 && controller.phase == .idle
    }

    service.finishStart()

    try await waitForComposerSpeechCondition {
      service.cancelCount >= 2 || controller.phase.isRecording
    }

    #expect(service.cancelCount >= 2)
    #expect(controller.phase == .idle)
  }

  @Test
  func maxDurationStopsAndPublishesTranscript() async throws {
    let service = FakeSpeechInputService(stopText: " dictated text ")
    let controller = ComposerSpeechInputController(
      service: service,
      maxRecordingDurationSeconds: 0
    )
    var transcript: String?

    controller.start(
      onTranscript: { text in
        transcript = text
      },
      onNeedsAudioModel: {}
    )

    try await waitForComposerSpeechCondition {
      transcript == "dictated text"
    }

    #expect(service.startCount == 1)
    #expect(service.stopCount == 1)
    #expect(controller.phase == .idle)
  }
}

@MainActor
struct ComposerAudioModelControllerTests {
  @Test
  func unavailableSelectedModelIsNotReady() async throws {
    let service = FakeAudioModelService()
    let controller = ComposerAudioModelController(service: service)

    controller.refreshAvailability()

    try await waitForComposerSpeechCondition {
      controller.installState(for: .smallEnglish) == .notInstalled
    }

    #expect(controller.selectedModelID == .smallEnglish)
    #expect(!controller.isSelectedModelInstalled)
  }

  @Test
  func audioDownloadCanPauseResumeAndSurviveAvailabilityRefresh() async throws {
    let service = ControlledAudioModelService()
    let controller = ComposerAudioModelController(service: service)
    controller.download(.smallEnglish)
    try await waitForComposerSpeechCondition {
      controller.installState(for: .smallEnglish) == .downloading(progress: 0.5)
    }
    controller.pause(.smallEnglish)
    controller.resume(.smallEnglish)
    try await waitForComposerSpeechCondition {
      controller.installState(for: .smallEnglish) == .paused(progress: 0.5)
    }
    controller.refreshAvailability()
    try await Task.sleep(for: .milliseconds(30))
    #expect(controller.installState(for: .smallEnglish) == .paused(progress: 0.5))
    #expect(await service.attempts == 1)
    controller.resume(.smallEnglish)
    try await waitForComposerSpeechCondition {
      controller.installState(for: .smallEnglish) == .installed
    }
    await service.emitOldProgress()
    try await Task.sleep(for: .milliseconds(30))
    #expect(controller.installState(for: .smallEnglish) == .installed)
    #expect(await service.attempts == 2)
  }

  @Test(arguments: [false, true])
  func audioDownloadCancelDrainsBeforeDiscardAndRestart(paused: Bool) async throws {
    let service = ControlledAudioModelService()
    let controller = ComposerAudioModelController(service: service)
    controller.download(.smallEnglish)
    try await waitForComposerSpeechCondition {
      controller.installState(for: .smallEnglish) == .downloading(progress: 0.5)
    }
    if paused {
      controller.pause(.smallEnglish)
      try await waitForComposerSpeechCondition {
        controller.installState(for: .smallEnglish) == .paused(progress: 0.5)
      }
    }
    controller.cancelDownload(.smallEnglish)
    controller.download(.smallEnglish)
    try await waitForComposerSpeechCondition {
      controller.installState(for: .smallEnglish) == .notInstalled
    }
    #expect(await service.discards == 1)
    controller.download(.smallEnglish)
    try await waitForComposerSpeechCondition {
      controller.installState(for: .smallEnglish) == .installed
    }
  }

  @Test
  func downloadSuccessMarksModelInstalledAndSelected() async throws {
    let service = FakeAudioModelService()
    let controller = ComposerAudioModelController(service: service)
    var selectedModelID: ComposerAudioModelID?
    controller.onSelectionChanged = { modelID in
      selectedModelID = modelID
    }

    controller.download(.parakeetV3Multilingual)

    try await waitForComposerSpeechCondition {
      controller.installState(for: .parakeetV3Multilingual).isInstalled
    }

    #expect(controller.selectedModelID == .parakeetV3Multilingual)
    #expect(selectedModelID == .parakeetV3Multilingual)
    #expect(await service.downloadCount == 1)
  }

  @Test
  func downloadFailurePublishesErrorState() async throws {
    let service = FakeAudioModelService(downloadError: TestComposerSpeechError.downloadFailed)
    let controller = ComposerAudioModelController(service: service)

    controller.download(.smallEnglish)

    try await waitForComposerSpeechCondition {
      if case .failed = controller.installState(for: .smallEnglish) {
        return true
      }
      return false
    }

    #expect(controller.selectedModelID == .smallEnglish)
  }
}

private final class FakeSpeechInputService: ComposerSpeechInputServicing {
  var startCount = 0
  var prepareModelCount = 0
  var stopCount = 0
  var cancelCount = 0
  let startError: Error?
  let prepareModelError: Error?
  let stopText: String
  let suspendsStart: Bool
  let suspendsModelPreparation: Bool
  let stopWaitsForModelPreparation: Bool
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var modelPreparationContinuations: [CheckedContinuation<Void, Never>] = []
  private var isModelPreparationFinished = false

  init(
    startError: Error? = nil,
    prepareModelError: Error? = nil,
    stopText: String = "",
    suspendsStart: Bool = false,
    suspendsModelPreparation: Bool = false,
    stopWaitsForModelPreparation: Bool = false
  ) {
    self.startError = startError
    self.prepareModelError = prepareModelError
    self.stopText = stopText
    self.suspendsStart = suspendsStart
    self.suspendsModelPreparation = suspendsModelPreparation
    self.stopWaitsForModelPreparation = stopWaitsForModelPreparation
  }

  func start() async throws {
    startCount += 1
    if suspendsStart {
      await withCheckedContinuation { continuation in
        startContinuation = continuation
      }
    }
    if let startError {
      throw startError
    }
  }

  func prepareModel() async throws {
    prepareModelCount += 1
    if suspendsModelPreparation && !isModelPreparationFinished {
      await withCheckedContinuation { continuation in
        modelPreparationContinuations.append(continuation)
      }
    }
    if let prepareModelError {
      throw prepareModelError
    }
  }

  func stop() async throws -> String {
    stopCount += 1
    if stopWaitsForModelPreparation {
      try await prepareModel()
    }
    return stopText
  }

  func cancel() async {
    cancelCount += 1
  }

  func finishStart() {
    startContinuation?.resume()
    startContinuation = nil
  }

  func finishModelPreparation() {
    isModelPreparationFinished = true
    let continuations = modelPreparationContinuations
    modelPreparationContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }
}

private actor FakeAudioModelService: ComposerAudioModelServicing {
  private var installedModelIDs: Set<ComposerAudioModelID>
  private let downloadError: Error?
  private(set) var downloadCount = 0

  init(
    installedModelIDs: Set<ComposerAudioModelID> = [],
    downloadError: Error? = nil
  ) {
    self.installedModelIDs = installedModelIDs
    self.downloadError = downloadError
  }

  func isInstalled(_ modelID: ComposerAudioModelID) async -> Bool {
    installedModelIDs.contains(modelID)
  }

  func discardDownload(_ modelID: ComposerAudioModelID) async throws {}

  func download(
    _ modelID: ComposerAudioModelID,
    progressHandler: @escaping @Sendable (Double?) -> Void
  ) async throws {
    downloadCount += 1
    progressHandler(0.5)
    if let downloadError {
      throw downloadError
    }
    installedModelIDs.insert(modelID)
    progressHandler(1.0)
  }
}

private enum TestComposerSpeechError: LocalizedError {
  case downloadFailed
  case modelLoadFailed

  var errorDescription: String? {
    switch self {
    case .downloadFailed:
      "Download failed"
    case .modelLoadFailed:
      "Model load failed"
    }
  }
}

private func waitForComposerSpeechCondition(
  timeout: Duration = .seconds(2),
  condition: @escaping @MainActor () async -> Bool
) async throws {
  try await withTestTimeout(timeout) {
    while !(await condition()) {
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

private actor ControlledAudioModelService: ComposerAudioModelServicing {
  private(set) var attempts = 0
  private(set) var discards = 0
  private var firstProgressHandler: (@Sendable (Double?) -> Void)?
  private var active = false

  func isInstalled(_ modelID: ComposerAudioModelID) async -> Bool { false }

  func download(
    _ modelID: ComposerAudioModelID,
    progressHandler: @escaping @Sendable (Double?) -> Void
  ) async throws {
    #expect(!active)
    active = true
    defer { active = false }
    attempts += 1
    if attempts == 1 {
      firstProgressHandler = progressHandler
      progressHandler(0.5)
      try await Task.sleep(for: .seconds(30))
    }
  }

  func discardDownload(_ modelID: ComposerAudioModelID) async throws {
    #expect(!active)
    discards += 1
  }

  func emitOldProgress() { firstProgressHandler?(0.1) }
}
