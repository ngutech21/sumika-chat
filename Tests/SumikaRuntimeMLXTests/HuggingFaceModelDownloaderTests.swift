import Foundation
import HuggingFace
import SumikaTestSupport
import Synchronization
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-model-download-tests"))
struct HuggingFaceModelDownloaderTests {
  @Test
  func snapshotInstallsOnlyCompleteFiles() async throws {
    let directory = try scopedTemporaryDirectory()
    let model = ManagedModelCatalog.defaultModel
    let downloader = try makeDownloader(baseURL: directory)
    let destination = try await downloader.download(model: model) { _ in }

    #expect(destination == directory.appending(path: model.localDirectoryName))
    #expect(LocalModelDirectory.isComplete(at: destination))
    #expect(
      try Data(contentsOf: destination.appending(path: "model.safetensors"))
        == ModelDownloadFixtureProtocol.weights)
    #expect(!FileManager.default.fileExists(atPath: workingDirectory(directory).path))
  }

  @Test(arguments: [
    "tree-error", "file-error", "unsafe-path", "missing-weights", "short-file", "oversized-file",
  ])
  func failuresNeverPublishAnInstallation(scenario: String) async throws {
    let directory = try scopedTemporaryDirectory()
    let downloader = try makeDownloader(baseURL: directory, scenario: scenario)
    await #expect(throws: (any Error).self) {
      _ = try await downloader.download(model: ManagedModelCatalog.defaultModel) { _ in }
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appending(path: ManagedModelCatalog.defaultModel.localDirectoryName).path)
    )
  }

  @Test(arguments: ["pause", "ignore-range"])
  func interruptedDownloadResumesBytesAndReusesCompletedFiles(scenario: String) async throws {
    let directory = try scopedTemporaryDirectory()
    let downloader = try makeDownloader(baseURL: directory, scenario: scenario)
    let task = Task {
      try await downloader.download(model: ManagedModelCatalog.defaultModel) { _ in }
    }
    let staging = workingDirectory(directory).appending(path: "model")
    try await waitUntil {
      FileManager.default.fileExists(atPath: staging.appending(path: "config.json").path)
        && (try? Data(contentsOf: staging.appending(path: "model.safetensors.partial")).count)
          == 4096
    }
    task.cancel()
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(
      !LocalModelDirectory.isComplete(
        at: directory.appending(path: ManagedModelCatalog.defaultModel.localDirectoryName)))
    let requestCount = ModelDownloadFixtureProtocol.requests.withLock { $0.count }
    // A new downloader represents resuming after an app restart.
    let resumed = try makeDownloader(baseURL: directory, scenario: scenario, resetRequests: false)
    let destination = try await resumed.download(model: ManagedModelCatalog.defaultModel) { _ in }
    let requests = ModelDownloadFixtureProtocol.requests.withLock {
      Array($0.dropFirst(requestCount))
    }
    #expect(requests.contains { $0.value(forHTTPHeaderField: "Range") == "bytes=4096-" })
    #expect(!requests.contains { $0.url?.lastPathComponent == "config.json" })
    #expect(
      !requests.contains {
        $0.url?.path == "/api/models/\(ManagedModelCatalog.defaultModel.huggingFaceRepoID)"
      })
    #expect(
      try Data(contentsOf: destination.appending(path: "model.safetensors"))
        == ModelDownloadFixtureProtocol.weights)
  }

  @Test
  func cancelDiscardsOnlyUnfinishedFilesAndAllowsFreshDownload() async throws {
    let directory = try scopedTemporaryDirectory()
    let downloader = try makeDownloader(baseURL: directory, scenario: "pause")
    let installed = directory.appending(path: ManagedModelCatalog.defaultModel.localDirectoryName)
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let existing = installed.appending(path: "keep.txt")
    try Data("installed".utf8).write(to: existing)
    let task = Task {
      try await downloader.download(model: ManagedModelCatalog.defaultModel) { _ in }
    }
    let partial = workingDirectory(directory).appending(path: "model/model.safetensors.partial")
    try await waitUntil { (try? Data(contentsOf: partial).count) == 4096 }
    task.cancel()
    _ = await task.result
    try await downloader.discardDownload(model: ManagedModelCatalog.defaultModel)
    #expect(!FileManager.default.fileExists(atPath: workingDirectory(directory).path))
    #expect(try String(contentsOf: existing, encoding: .utf8) == "installed")
    let fresh = try makeDownloader(baseURL: directory)
    let destination = try await fresh.download(model: ManagedModelCatalog.defaultModel) { _ in }
    #expect(LocalModelDirectory.isComplete(at: destination))
    #expect(!FileManager.default.fileExists(atPath: existing.path))
  }

  @Test
  func invalidRangeDoesNotAppendOrInstall() async throws {
    let directory = try scopedTemporaryDirectory()
    let downloader = try makeDownloader(baseURL: directory, scenario: "bad-range")
    let partial = workingDirectory(directory).appending(path: "model/model.safetensors.partial")
    try FileManager.default.createDirectory(
      at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ModelDownloadFixtureProtocol.weights.prefix(4096).write(to: partial)
    await #expect(throws: (any Error).self) {
      _ = try await downloader.download(model: ManagedModelCatalog.defaultModel) { _ in }
    }
    #expect(try Data(contentsOf: partial).count == 4096)
  }

  @Test
  func partialSymlinkCannotWriteOutsideDownloadDirectory() async throws {
    let directory = try scopedTemporaryDirectory()
    let partial = workingDirectory(directory).appending(path: "model/model.safetensors.partial")
    try FileManager.default.createDirectory(
      at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
    let outside = directory.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: outside)
    let downloader = try makeDownloader(baseURL: directory)
    await #expect(throws: (any Error).self) {
      _ = try await downloader.download(model: ManagedModelCatalog.defaultModel) { _ in }
    }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
  }

  @Test(arguments: [false, true])
  func stagingSymlinkCannotRedirectDownloads(nested: Bool) async throws {
    let directory = try scopedTemporaryDirectory()
    let outside = directory.appending(path: "installed")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let existing = outside.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: existing)
    let link =
      nested
      ? workingDirectory(directory).appending(path: "model")
      : directory.appending(path: ".downloads")
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let downloader = try makeDownloader(baseURL: directory)
    await #expect(throws: (any Error).self) {
      _ = try await downloader.download(model: ManagedModelCatalog.defaultModel) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
  }

  private func workingDirectory(_ baseURL: URL) -> URL {
    baseURL.appending(path: ".downloads/\(ManagedModelCatalog.defaultModel.localDirectoryName)")
  }

  private func makeDownloader(
    baseURL: URL, scenario: String = "success", resetRequests: Bool = true
  ) throws -> HuggingFaceModelDownloader {
    if resetRequests { ModelDownloadFixtureProtocol.requests.withLock { $0 = [] } }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelDownloadFixtureProtocol.self]
    let client = HubClient(
      session: URLSession(configuration: configuration),
      host: try #require(URL(string: "https://\(scenario).example")), tokenProvider: .none,
      cache: nil
    )
    return HuggingFaceModelDownloader(
      hubClient: client, modelDirectoryBaseURL: baseURL, sessionConfiguration: configuration
    )
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

nonisolated private final class ModelDownloadFixtureProtocol: URLProtocol {
  static let requests = Mutex<[URLRequest]>([])
  static let weights = Data(repeating: 42, count: 16384)
  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    requestsAppend()
    guard let url = request.url else { return }
    let scenario = url.host ?? ""
    let isTree = url.path.contains("/tree/")
    let isModel = url.path.hasPrefix("/api/models/") && !isTree
    let isWeights = url.lastPathComponent == "model.safetensors"
    let range = request.value(forHTTPHeaderField: "Range")
    let offset = range.flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
    var status = 200
    var headers = ["Content-Type": "application/octet-stream"]
    let body: Data
    if isModel {
      body = Data(
        "{\"id\":\"\(ManagedModelCatalog.defaultModel.huggingFaceRepoID)\",\"sha\":\"\(String(repeating: "a", count: 40))\"}"
          .utf8)
    } else if isTree {
      let weightPath = scenario == "unsafe-path.example" ? "../outside.json" : "model.safetensors"
      let weights =
        scenario == "missing-weights.example"
        ? "" : ",{\"path\":\"\(weightPath)\",\"type\":\"file\",\"size\":16384}"
      body = Data(
        "[{\"path\":\"config.json\",\"type\":\"file\",\"size\":2},{\"path\":\"tokenizer.json\",\"type\":\"file\",\"size\":2}\(weights)]"
          .utf8)
    } else if isWeights {
      if offset > 0, scenario != "ignore-range.example" {
        status = 206
        headers["Content-Range"] =
          scenario == "bad-range.example" ? "bytes 0-16383/16384" : "bytes \(offset)-16383/16384"
        body = Self.weights.dropFirst(offset)
      } else if scenario == "short-file.example" {
        body = Self.weights.prefix(4096)
      } else if scenario == "oversized-file.example" {
        body = Self.weights + Data([42])
      } else {
        body = Self.weights
      }
    } else {
      body = Data("{}".utf8)
    }
    if (isTree && scenario == "tree-error.example")
      || (isWeights && scenario == "file-error.example")
    {
      status = 500
    }
    headers["Content-Length"] = String(body.count)
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if isWeights, offset == 0, ["pause.example", "ignore-range.example"].contains(scenario) {
      client?.urlProtocol(self, didLoad: body.prefix(4096))
      return
    }
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  private func requestsAppend() { Self.requests.withLock { $0.append(request) } }
  override func stopLoading() {}
}
