import Dispatch
import Testing

@testable import SumikaApp

@MainActor
struct ComposerSpeechSampleAccumulatorTests {
  @Test
  func sequentialAppendsPreserveSamplesAndSampleRate() {
    let accumulator = ComposerSpeechSampleAccumulator(sampleRate: 48_000)
    accumulator.append([])
    accumulator.append([0.25, -0.5])
    accumulator.append([])
    accumulator.append([1])
    accumulator.append([])

    let recording = accumulator.takeRecording()

    #expect(recording.samples == [0.25, -0.5, 1])
    #expect(recording.sampleRate == 48_000)
  }

  @Test
  func takingRecordingClearsSamplesAndPreservesReturnedRecording() {
    let accumulator = ComposerSpeechSampleAccumulator(sampleRate: 44_100)
    accumulator.append([0.25, -0.5])
    let firstRecording = accumulator.takeRecording()
    let emptyRecording = accumulator.takeRecording()

    accumulator.append([1, -1])
    let secondRecording = accumulator.takeRecording()

    #expect(firstRecording.samples == [0.25, -0.5])
    #expect(emptyRecording.samples.isEmpty)
    #expect(emptyRecording.sampleRate == 44_100)
    #expect(secondRecording.samples == [1, -1])
    #expect(secondRecording.sampleRate == 44_100)
  }

  @Test
  func latestErrorPersistsUntilRecordingIsTaken() {
    let accumulator = ComposerSpeechSampleAccumulator(sampleRate: 48_000)
    #expect(accumulator.captureError() == nil)

    accumulator.recordError(CaptureError.first)
    #expect(accumulator.captureError() as? CaptureError == .first)
    #expect(accumulator.captureError() as? CaptureError == .first)

    accumulator.recordError(CaptureError.second)
    #expect(accumulator.captureError() as? CaptureError == .second)

    _ = accumulator.takeRecording()
    #expect(accumulator.captureError() == nil)
  }

  @Test
  func resetDiscardsSamplesAndErrorAndAllowsReuse() {
    let accumulator = ComposerSpeechSampleAccumulator(sampleRate: 48_000)
    accumulator.append([0.25, -0.5])
    accumulator.recordError(CaptureError.first)

    accumulator.reset()

    #expect(accumulator.captureError() == nil)
    #expect(accumulator.takeRecording().samples.isEmpty)

    accumulator.append([1, -1])
    let recording = accumulator.takeRecording()
    #expect(recording.samples == [1, -1])
    #expect(recording.sampleRate == 48_000)
  }

  @Test
  func concurrentAppendsPreserveEverySampleExactlyOnce() {
    let accumulator = ComposerSpeechSampleAccumulator(sampleRate: 48_000)
    let chunkCount = 64
    let samplesPerChunk = 32

    DispatchQueue.concurrentPerform(iterations: chunkCount) { index in
      let firstSample = index * samplesPerChunk
      let samples = (firstSample..<(firstSample + samplesPerChunk)).map { Float($0) }
      accumulator.append(samples)
    }

    let recording = accumulator.takeRecording()
    let expectedSamples = (0..<(chunkCount * samplesPerChunk)).map { Float($0) }
    #expect(recording.samples.sorted() == expectedSamples)
  }
}

nonisolated private enum CaptureError: Error, Equatable {
  case first
  case second
}
