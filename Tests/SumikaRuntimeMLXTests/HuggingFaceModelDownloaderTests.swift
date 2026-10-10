import Foundation
import HuggingFace
import SumikaTestSupport
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

@Suite(TemporaryDirectoryTrait(named: "sumika-model-download-tests"))
struct HuggingFaceModelDownloaderTests {
  @Test
  func cacheFreeSnapshotReturnsInstalledFiles() async throws {
    let directory = try scopedTemporaryDirectory()
    let model = ManagedModelCatalog.models[0]
    let downloader = try makeDownloader(baseURL: directory, scenario: "success")

    let destination = try await downloader.download(model: model) { _ in }

    #expect(
      destination
        == directory.appending(path: model.localDirectoryName, directoryHint: .isDirectory))
    #expect(try Data(contentsOf: destination.appending(path: "config.json")) == Data("{}".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
        model.localDirectoryName
      ])
  }

  @Test(arguments: ["tree-error", "file-error"])
  func cacheFreeSnapshotPropagatesDownloadFailures(scenario: String) async throws {
    let downloader = try makeDownloader(baseURL: scopedTemporaryDirectory(), scenario: scenario)

    await #expect(throws: HTTPClientError.self) {
      _ = try await downloader.download(model: ManagedModelCatalog.models[0]) { _ in }
    }
  }

  private func makeDownloader(baseURL: URL, scenario: String) throws -> HuggingFaceModelDownloader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelDownloadFixtureProtocol.self]
    let client = HubClient(
      session: URLSession(configuration: configuration),
      host: try #require(URL(string: "https://\(scenario).example")),
      tokenProvider: .none,
      cache: nil
    )
    return HuggingFaceModelDownloader(hubClient: client, modelDirectoryBaseURL: baseURL)
  }
}

nonisolated private final class ModelDownloadFixtureProtocol: URLProtocol {
  override static func canInit(with request: URLRequest) -> Bool { true }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let isTree = url.path.contains("/tree/")
    let failed = url.host == (isTree ? "tree-error.example" : "file-error.example")
    let body =
      isTree
      ? """
      [{"path":"config.json","type":"file","oid":"abc","size":2}]
      """
      : "{}"
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: failed ? 500 : 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": "application/json", "Content-Length": String(body.utf8.count),
        ]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
