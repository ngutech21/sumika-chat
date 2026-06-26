import Foundation
import Testing

@testable import Sumika

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
      controller.phase.isRecording
    }

    #expect(service.startCount == 1)
    controller.cancel()
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
      service.startCount == 1 && controller.phase == .preparing
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
  var stopCount = 0
  var cancelCount = 0
  let startError: Error?
  let stopText: String
  let suspendsStart: Bool
  private var startContinuation: CheckedContinuation<Void, Never>?

  init(startError: Error? = nil, stopText: String = "", suspendsStart: Bool = false) {
    self.startError = startError
    self.stopText = stopText
    self.suspendsStart = suspendsStart
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

  func stop() async throws -> String {
    stopCount += 1
    return stopText
  }

  func cancel() async {
    cancelCount += 1
  }

  func finishStart() {
    startContinuation?.resume()
    startContinuation = nil
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

  var errorDescription: String? {
    "Download failed"
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
