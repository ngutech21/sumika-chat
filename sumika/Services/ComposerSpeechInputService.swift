@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Observation
import os

enum ComposerAudioModelID: String, Codable, CaseIterable, Identifiable, Sendable {
  case smallEnglish
  case parakeetV3Multilingual

  var id: Self { self }
}

struct ComposerAudioModelDescriptor: Identifiable, Equatable, Sendable {
  let id: ComposerAudioModelID
  let title: String
  let subtitle: String
  let detail: String
  let storageEstimate: String
  let isRecommended: Bool

  static let catalog: [ComposerAudioModelDescriptor] = [
    ComposerAudioModelDescriptor(
      id: .smallEnglish,
      title: "Small English",
      subtitle: "Parakeet TDT-CTC 110M",
      detail: "Fast local dictation for English. Recommended default.",
      storageEstimate: "About 230 MB",
      isRecommended: true
    ),
    ComposerAudioModelDescriptor(
      id: .parakeetV3Multilingual,
      title: "Parakeet v3 Multilingual",
      subtitle: "Parakeet TDT 0.6B v3",
      detail: "Larger multilingual model for German and other European languages.",
      storageEstimate: "About 500 MB",
      isRecommended: false
    ),
  ]
}

enum ComposerAudioModelInstallState: Equatable, Sendable {
  case notInstalled
  case downloading(progress: Double?)
  case installed
  case failed(String)

  var isInstalled: Bool {
    if case .installed = self {
      return true
    }
    return false
  }

  var isDownloading: Bool {
    if case .downloading = self {
      return true
    }
    return false
  }
}

protocol ComposerAudioModelServicing: Sendable {
  func isInstalled(_ modelID: ComposerAudioModelID) async -> Bool
  func download(
    _ modelID: ComposerAudioModelID,
    progressHandler: @escaping @Sendable (Double?) -> Void
  ) async throws
}

@MainActor
@Observable
final class ComposerAudioModelController {
  let models = ComposerAudioModelDescriptor.catalog

  var selectedModelID: ComposerAudioModelID = .smallEnglish
  var installStates: [ComposerAudioModelID: ComposerAudioModelInstallState] =
    Dictionary(
      uniqueKeysWithValues: ComposerAudioModelID.allCases.map { ($0, .notInstalled) }
    )

  @ObservationIgnored var onSelectionChanged: (@MainActor (ComposerAudioModelID) -> Void)?
  @ObservationIgnored private let service: any ComposerAudioModelServicing
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var downloadTasks: [ComposerAudioModelID: Task<Void, Never>] = [:]

  init(service: any ComposerAudioModelServicing = FluidAudioModelService()) {
    self.service = service
  }

  deinit {
    refreshTask?.cancel()
    for task in downloadTasks.values {
      task.cancel()
    }
  }

  var isSelectedModelInstalled: Bool {
    installState(for: selectedModelID).isInstalled
  }

  var needsMultilingualModel: Bool {
    let languageCode = Locale.current.language.languageCode?.identifier.lowercased()
    return languageCode != nil && languageCode != "en"
      && selectedModelID == .smallEnglish
  }

  func applyPersistedSelection(_ rawModelID: String?) {
    guard let rawModelID,
      let modelID = ComposerAudioModelID(rawValue: rawModelID)
    else {
      selectedModelID = .smallEnglish
      return
    }

    selectedModelID = modelID
  }

  func installState(for modelID: ComposerAudioModelID) -> ComposerAudioModelInstallState {
    installStates[modelID] ?? .notInstalled
  }

  func select(_ modelID: ComposerAudioModelID) {
    guard selectedModelID != modelID else {
      return
    }

    selectedModelID = modelID
    onSelectionChanged?(modelID)
  }

  func refreshAvailability() {
    refreshTask?.cancel()
    let service = service
    refreshTask = Task {
      var snapshot: [ComposerAudioModelID: ComposerAudioModelInstallState] = [:]
      for modelID in ComposerAudioModelID.allCases {
        if Task.isCancelled {
          return
        }
        snapshot[modelID] = await service.isInstalled(modelID) ? .installed : .notInstalled
      }
      installStates = snapshot
    }
  }

  func download(_ modelID: ComposerAudioModelID) {
    guard !installState(for: modelID).isDownloading else {
      return
    }

    installStates[modelID] = .downloading(progress: nil)
    let service = service
    downloadTasks[modelID]?.cancel()
    downloadTasks[modelID] = Task {
      do {
        try await service.download(modelID) { [weak self] progress in
          Task { @MainActor in
            guard let self, self.installState(for: modelID).isDownloading else {
              return
            }
            self.installStates[modelID] = .downloading(progress: progress)
          }
        }
        try Task.checkCancellation()
        installStates[modelID] = .installed
        select(modelID)
      } catch is CancellationError {
        installStates[modelID] = .notInstalled
      } catch {
        installStates[modelID] = .failed(Self.errorMessage(for: error))
      }
      downloadTasks[modelID] = nil
    }
  }

  private static func errorMessage(for error: Error) -> String {
    if let localizedError = error as? LocalizedError,
      let errorDescription = localizedError.errorDescription
    {
      return errorDescription
    }
    return error.localizedDescription
  }
}

private struct FluidAudioModelService: ComposerAudioModelServicing {
  func isInstalled(_ modelID: ComposerAudioModelID) async -> Bool {
    AsrModels.modelsExist(
      at: AsrModels.defaultCacheDirectory(for: modelID.asrModelVersion),
      version: modelID.asrModelVersion
    )
  }

  func download(
    _ modelID: ComposerAudioModelID,
    progressHandler: @escaping @Sendable (Double?) -> Void
  ) async throws {
    _ = try await AsrModels.download(
      version: modelID.asrModelVersion,
      progressHandler: { progress in
        progressHandler(progress.fractionCompleted)
      }
    )
  }
}

enum ComposerSpeechInputPhase: Equatable, Sendable {
  case idle
  case preparing
  case recording(elapsedSeconds: Int)
  case finalizing
  case failed(String)

  var isRecording: Bool {
    if case .recording = self {
      return true
    }
    return false
  }

  var isBusy: Bool {
    switch self {
    case .preparing, .recording, .finalizing:
      true
    case .idle, .failed:
      false
    }
  }
}

protocol ComposerSpeechInputServicing: AnyObject {
  func start() async throws
  func stop() async throws -> String
  func cancel() async
}

@MainActor
@Observable
final class ComposerSpeechInputController {
  static let defaultMaxRecordingDurationSeconds = 300

  private let service: any ComposerSpeechInputServicing
  private let maxRecordingDurationSeconds: Int
  private var operationTask: Task<Void, Never>?
  private var timerTask: Task<Void, Never>?
  private var autoStopTask: Task<Void, Never>?

  private(set) var phase: ComposerSpeechInputPhase = .idle

  init(
    service: any ComposerSpeechInputServicing,
    maxRecordingDurationSeconds: Int = ComposerSpeechInputController
      .defaultMaxRecordingDurationSeconds
  ) {
    self.service = service
    self.maxRecordingDurationSeconds = maxRecordingDurationSeconds
  }

  convenience init(audioModelController: ComposerAudioModelController) {
    self.init(service: ComposerSpeechInputService(audioModelController: audioModelController))
  }

  var isRecording: Bool {
    phase.isRecording
  }

  var statusText: String? {
    switch phase {
    case .idle:
      nil
    case .preparing:
      "Preparing"
    case .recording(let elapsedSeconds):
      Self.durationFormatter.string(from: TimeInterval(elapsedSeconds)) ?? "Recording"
    case .finalizing:
      "Finalizing"
    case .failed(let message):
      message
    }
  }

  func toggle(
    onTranscript: @escaping (String) -> Void,
    onNeedsAudioModel: @escaping () -> Void
  ) {
    if isRecording {
      stop(onTranscript: onTranscript)
      return
    }

    start(onTranscript: onTranscript, onNeedsAudioModel: onNeedsAudioModel)
  }

  func start(
    onTranscript: @escaping (String) -> Void,
    onNeedsAudioModel: @escaping () -> Void
  ) {
    guard !phase.isBusy, operationTask == nil else {
      return
    }

    phase = .preparing
    operationTask = Task { [weak self] in
      guard let self else {
        return
      }
      defer {
        operationTask = nil
      }

      do {
        try await service.start()
        try Task.checkCancellation()
        startTimer()
        startAutoStop(onTranscript: onTranscript)
        phase = .recording(elapsedSeconds: 0)
      } catch is CancellationError {
        await service.cancel()
        phase = .idle
      } catch ComposerSpeechInputError.audioModelNotReady where !Task.isCancelled {
        phase = .idle
        onNeedsAudioModel()
      } catch {
        if Task.isCancelled {
          await service.cancel()
          phase = .idle
        } else {
          await service.cancel()
          phase = .failed(Self.errorMessage(for: error))
        }
      }
    }
  }

  func stop(onTranscript: @escaping (String) -> Void) {
    guard isRecording else {
      return
    }

    timerTask?.cancel()
    autoStopTask?.cancel()
    phase = .finalizing

    operationTask = Task { [weak self] in
      guard let self else {
        return
      }
      defer {
        operationTask = nil
      }

      do {
        let transcript = try await service.stop()
        try Task.checkCancellation()
        phase = .idle
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
          onTranscript(trimmedTranscript)
        }
      } catch is CancellationError {
        await service.cancel()
        phase = .idle
      } catch {
        if Task.isCancelled {
          await service.cancel()
          phase = .idle
        } else {
          await service.cancel()
          phase = .failed(Self.errorMessage(for: error))
        }
      }
    }
  }

  func cancel() {
    operationTask?.cancel()
    timerTask?.cancel()
    autoStopTask?.cancel()
    Task {
      await service.cancel()
      phase = .idle
    }
  }

  private func startTimer() {
    timerTask?.cancel()
    timerTask = Task { [weak self] in
      var elapsedSeconds = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else {
          return
        }
        elapsedSeconds += 1
        await MainActor.run {
          guard let self, self.phase.isRecording else {
            return
          }
          self.phase = .recording(elapsedSeconds: elapsedSeconds)
        }
      }
    }
  }

  private func startAutoStop(onTranscript: @escaping (String) -> Void) {
    autoStopTask?.cancel()
    autoStopTask = Task { [weak self, maxRecordingDurationSeconds] in
      try? await Task.sleep(for: .seconds(maxRecordingDurationSeconds))
      guard !Task.isCancelled else {
        return
      }
      await MainActor.run {
        self?.stop(onTranscript: onTranscript)
      }
    }
  }

  private static func errorMessage(for error: Error) -> String {
    if let localizedError = error as? LocalizedError,
      let errorDescription = localizedError.errorDescription
    {
      return errorDescription
    }
    return error.localizedDescription
  }

  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter
  }()
}

@MainActor
final class ComposerSpeechInputService: ComposerSpeechInputServicing {
  private let audioModelController: ComposerAudioModelController
  private var recordingSession: ComposerSpeechRecordingSession?
  private var loadedModelID: ComposerAudioModelID?
  private var asrManager: AsrManager?

  init(audioModelController: ComposerAudioModelController) {
    self.audioModelController = audioModelController
  }

  func start() async throws {
    guard recordingSession == nil else {
      throw ComposerSpeechInputError.alreadyRecording
    }
    guard audioModelController.isSelectedModelInstalled else {
      audioModelController.refreshAvailability()
      throw ComposerSpeechInputError.audioModelNotReady
    }

    try await Self.requestMicrophonePermission()

    let modelID = audioModelController.selectedModelID
    let manager = try await loadManager(for: modelID)
    let session = ComposerSpeechRecordingSession(asrManager: manager)
    try session.start()
    recordingSession = session
  }

  func stop() async throws -> String {
    guard let recordingSession else {
      return ""
    }

    self.recordingSession = nil
    return try await recordingSession.stop()
  }

  func cancel() async {
    guard let recordingSession else {
      return
    }

    self.recordingSession = nil
    recordingSession.cancel()
  }

  private func loadManager(for modelID: ComposerAudioModelID) async throws -> AsrManager {
    if loadedModelID == modelID, let asrManager {
      return asrManager
    }

    let models = try await AsrModels.loadFromCache(version: modelID.asrModelVersion)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    loadedModelID = modelID
    asrManager = manager
    return manager
  }

  private static func requestMicrophonePermission() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .denied, .restricted:
      throw ComposerSpeechInputError.microphonePermissionDenied
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      guard granted else {
        throw ComposerSpeechInputError.microphonePermissionDenied
      }
    @unknown default:
      throw ComposerSpeechInputError.microphonePermissionDenied
    }
  }
}

nonisolated private final class ComposerSpeechRecordingSession {
  private let engine = AVAudioEngine()
  private let asrManager: AsrManager
  private var accumulator: ComposerSpeechSampleAccumulator?

  nonisolated init(asrManager: AsrManager) {
    self.asrManager = asrManager
  }

  nonisolated func start() throws {
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw ComposerSpeechInputError.audioInputUnavailable
    }

    let accumulator = ComposerSpeechSampleAccumulator(sampleRate: inputFormat.sampleRate)
    ComposerSpeechAudioTap.install(
      on: inputNode,
      bus: 0,
      bufferSize: 4096,
      format: inputFormat,
      accumulator: accumulator
    )
    self.accumulator = accumulator

    do {
      engine.prepare()
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      self.accumulator = nil
      throw error
    }
  }

  nonisolated func stop() async throws -> String {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    guard let accumulator else {
      return ""
    }
    self.accumulator = nil
    if let captureError = accumulator.captureError() {
      throw captureError
    }

    guard let buffer = ComposerSpeechAudioTap.combinedBuffer(from: accumulator.takeRecording())
    else {
      return ""
    }

    var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
    let result = try await asrManager.transcribe(buffer, decoderState: &decoderState)
    return result.text
  }

  nonisolated func cancel() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    accumulator?.reset()
    accumulator = nil
  }
}

nonisolated private final class ComposerSpeechSampleAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private let sampleRate: Double
  private var samples: [Float] = []
  private var error: Error?

  nonisolated init(sampleRate: Double) {
    self.sampleRate = sampleRate
  }

  nonisolated func append(_ newSamples: [Float]) {
    guard !newSamples.isEmpty else {
      return
    }

    lock.withLock {
      samples.append(contentsOf: newSamples)
    }
  }

  nonisolated func recordError(_ newError: Error) {
    lock.withLock {
      error = newError
    }
  }

  nonisolated func captureError() -> Error? {
    lock.withLock {
      error
    }
  }

  nonisolated func takeRecording() -> ComposerSpeechCapturedAudio {
    lock.withLock {
      let copiedSamples = samples
      samples.removeAll()
      error = nil
      return ComposerSpeechCapturedAudio(samples: copiedSamples, sampleRate: sampleRate)
    }
  }

  nonisolated func reset() {
    lock.withLock {
      samples.removeAll()
      error = nil
    }
  }
}

nonisolated private struct ComposerSpeechCapturedAudio: Sendable {
  let samples: [Float]
  let sampleRate: Double
}

nonisolated private enum ComposerSpeechAudioTap {
  nonisolated static func install(
    on inputNode: AVAudioNode,
    bus: AVAudioNodeBus,
    bufferSize: AVAudioFrameCount,
    format inputFormat: AVAudioFormat,
    accumulator: ComposerSpeechSampleAccumulator
  ) {
    inputNode.installTap(onBus: bus, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
      guard buffer.frameLength > 0 else {
        return
      }
      do {
        accumulator.append(try extractMonoSamples(from: buffer))
      } catch {
        accumulator.recordError(error)
      }
    }
  }

  nonisolated static func combinedBuffer(from recording: ComposerSpeechCapturedAudio)
    -> AVAudioPCMBuffer?
  {
    guard !recording.samples.isEmpty,
      recording.sampleRate > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: recording.sampleRate,
        channels: 1,
        interleaved: false
      ),
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(recording.samples.count)
      )
    else {
      return nil
    }

    outputBuffer.frameLength = AVAudioFrameCount(recording.samples.count)
    guard let targetChannels = outputBuffer.floatChannelData else {
      return nil
    }

    targetChannels[0].update(from: recording.samples, count: recording.samples.count)
    return outputBuffer
  }

  nonisolated private static func extractMonoSamples(from buffer: AVAudioPCMBuffer) throws
    -> [Float]
  {
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameCount > 0, channelCount > 0 else {
      return []
    }
    guard buffer.format.commonFormat == .pcmFormatFloat32 else {
      throw ComposerSpeechInputError.audioInputUnavailable
    }

    let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    guard !audioBuffers.isEmpty else {
      throw ComposerSpeechInputError.audioInputUnavailable
    }

    if buffer.format.isInterleaved {
      return try extractInterleavedMonoSamples(
        from: audioBuffers,
        frameCount: frameCount,
        channelCount: channelCount
      )
    }

    return try extractNonInterleavedMonoSamples(
      from: audioBuffers,
      frameCount: frameCount,
      channelCount: channelCount
    )
  }

  nonisolated private static func extractInterleavedMonoSamples(
    from audioBuffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int,
    channelCount: Int
  ) throws -> [Float] {
    let requiredSampleCount = frameCount * channelCount
    let requiredByteCount = requiredSampleCount * MemoryLayout<Float>.stride
    guard let source = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self),
      Int(audioBuffers[0].mDataByteSize) >= requiredByteCount
    else {
      throw ComposerSpeechInputError.audioInputUnavailable
    }

    if channelCount == 1 {
      return Array(UnsafeBufferPointer(start: source, count: frameCount))
    }

    var monoSamples = [Float](repeating: 0, count: frameCount)
    let scale = 1 / Float(channelCount)
    for frameIndex in 0..<frameCount {
      var sum: Float = 0
      let sourceOffset = frameIndex * channelCount
      for channelIndex in 0..<channelCount {
        sum += source[sourceOffset + channelIndex]
      }
      monoSamples[frameIndex] = sum * scale
    }
    return monoSamples
  }

  nonisolated private static func extractNonInterleavedMonoSamples(
    from audioBuffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int,
    channelCount: Int
  ) throws -> [Float] {
    let requiredByteCount = frameCount * MemoryLayout<Float>.stride
    guard audioBuffers.count >= channelCount else {
      throw ComposerSpeechInputError.audioInputUnavailable
    }

    if channelCount == 1 {
      guard let source = audioBuffers[0].mData?.assumingMemoryBound(to: Float.self),
        Int(audioBuffers[0].mDataByteSize) >= requiredByteCount
      else {
        throw ComposerSpeechInputError.audioInputUnavailable
      }
      return Array(UnsafeBufferPointer(start: source, count: frameCount))
    }

    var monoSamples = [Float](repeating: 0, count: frameCount)
    let scale = 1 / Float(channelCount)
    for channelIndex in 0..<channelCount {
      guard let source = audioBuffers[channelIndex].mData?.assumingMemoryBound(to: Float.self),
        Int(audioBuffers[channelIndex].mDataByteSize) >= requiredByteCount
      else {
        throw ComposerSpeechInputError.audioInputUnavailable
      }
      for frameIndex in 0..<frameCount {
        monoSamples[frameIndex] += source[frameIndex]
      }
    }

    for frameIndex in 0..<frameCount {
      monoSamples[frameIndex] *= scale
    }
    return monoSamples
  }
}

nonisolated enum ComposerSpeechInputError: LocalizedError, Equatable {
  case alreadyRecording
  case audioModelNotReady
  case microphonePermissionDenied
  case audioInputUnavailable

  nonisolated var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      "Speech recording is already active."
    case .audioModelNotReady:
      "Install an audio model before dictating."
    case .microphonePermissionDenied:
      "Allow microphone access to dictate messages."
    case .audioInputUnavailable:
      "No usable microphone input is available."
    }
  }
}

extension ComposerAudioModelID {
  fileprivate var asrModelVersion: AsrModelVersion {
    switch self {
    case .smallEnglish:
      .tdtCtc110m
    case .parakeetV3Multilingual:
      .v3
    }
  }
}
