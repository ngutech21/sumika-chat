import FluidAudio
import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaApp

@Suite(TemporaryDirectoryTrait(named: "sumika-audio-download-tests"))
struct FluidAudioModelServiceTests {
  @Test
  func interruptedAudioFilesStayOutsideInstalledDirectoryAndCancelPreservesExistingFiles()
    async throws
  {
    let root = try scopedTemporaryDirectory()
    let destination = root.appending(path: Repo.parakeetTdtCtc110m.folderName)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let existing = destination.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: existing)
    let service = FluidAudioModelService(
      directory: { _ in destination },
      downloadModel: { _, staging, _ in
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appending(path: "weights.partial"))
        throw CancellationError()
      }
    )
    await #expect(throws: CancellationError.self) {
      try await service.download(.smallEnglish) { _ in }
    }
    #expect(!(await service.isInstalled(.smallEnglish)))
    let workDirectory = root.appending(path: ".sumika-downloads/smallEnglish")
    #expect(FileManager.default.fileExists(atPath: workDirectory.path))
    try await service.discardDownload(.smallEnglish)
    #expect(!FileManager.default.fileExists(atPath: workDirectory.path))
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
  }

  @Test
  func completedAudioDownloadIsPromotedAndIncompleteResultIsRejected() async throws {
    let root = try scopedTemporaryDirectory()
    let destination = root.appending(path: Repo.parakeetTdtCtc110m.folderName)
    let incomplete = FluidAudioModelService(
      directory: { _ in destination },
      downloadModel: { _, staging, _ in
        for name in ModelNames.ASR.requiredModelsFused {
          try FileManager.default.createDirectory(
            at: staging.appending(path: name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: staging.appending(path: ModelNames.ASR.vocabularyFile))
      }
    )
    await #expect(throws: CocoaError.self) { try await incomplete.download(.smallEnglish) { _ in } }
    #expect(!(await incomplete.isInstalled(.smallEnglish)))
    let complete = FluidAudioModelService(
      directory: { _ in destination },
      downloadModel: { _, staging, _ in
        for name in ModelNames.ASR.requiredModelsFused {
          try FileManager.default.createDirectory(
            at: staging.appending(path: name), withIntermediateDirectories: true)
          try Data([1]).write(to: staging.appending(path: name).appending(path: "coremldata.bin"))
        }
        try Data("{}".utf8).write(to: staging.appending(path: ModelNames.ASR.vocabularyFile))
      }
    )
    try await complete.download(.smallEnglish) { _ in }
    #expect(await complete.isInstalled(.smallEnglish))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appending(path: ".sumika-downloads/smallEnglish").path))
    let partial = destination.appending(path: "weights.partial")
    try Data([1]).write(to: partial)
    #expect(!(await complete.isInstalled(.smallEnglish)))
    try FileManager.default.removeItem(at: partial)
    #expect(await complete.isInstalled(.smallEnglish))
  }

  @Test
  func stagingSymlinkCannotRedirectAudioDownloads() async throws {
    let root = try scopedTemporaryDirectory()
    let destination = root.appending(path: Repo.parakeetTdtCtc110m.folderName)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let existing = destination.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: existing)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: ".sumika-downloads"), withDestinationURL: destination)
    let service = FluidAudioModelService(
      directory: { _ in destination },
      downloadModel: { _, _, _ in Issue.record("Unsafe staging directory reached the downloader") }
    )
    await #expect(throws: CocoaError.self) { try await service.download(.smallEnglish) { _ in } }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["keep.txt"])
  }
}
