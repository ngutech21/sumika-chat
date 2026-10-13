import Foundation
import Testing

@testable import SumikaCore
@testable import SumikaEval

struct HarborWorkspaceBackendTests {
  @Test(arguments: [false, true], [false, true])
  func chunkReadsDoNotMixFileVersions(remote: Bool, replace: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(name: "Reader parity", rootURL: root)
    let path = root.appending(path: "notes.txt")
    let original = Data(String(repeating: "original\n", count: 1_200).utf8)
    let replacement = Data(String(repeating: "replaced\n", count: 1_200).utf8)
    try original.write(to: path)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HarborWorkerURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let fileIO: any WorkspaceFileIO
    if remote {
      let bridgeURL = try #require(URL(string: "http://harbor-test.invalid"))
        .appendingPathComponent(root.path)
      fileIO = HarborWorkspaceBackend(bridgeURL: bridgeURL, token: "test", session: session)
    } else {
      fileIO = LocalWorkspaceFileIO()
    }
    do {
      let result = try await fileIO.withReader(path: "notes.txt", in: workspace) { readChunk in
        var data = try await readChunk(0, 8 * 1_024)
        if replace { try replacement.write(to: path, options: .atomic) }
        data.append(try await readChunk(8 * 1_024, 8 * 1_024))
        return data
      }
      #expect(!remote || !replace)
      #expect(result == original)
    } catch WorkspaceFileIOError.contentChanged {
      #expect(remote && replace)
    }
  }
}

private final class HarborWorkerURLProtocol: URLProtocol, @unchecked Sendable {
  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "harbor-test.invalid"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let url = try #require(request.url)
      let body = try requestBody()
      let root = URL(filePath: url.deletingLastPathComponent().path)
      let control = root.appending(path: ".control")
      try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
      let payload = control.appending(path: UUID().uuidString + ".json")
      try body.write(to: payload)
      defer { try? FileManager.default.removeItem(at: payload) }
      let worker = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "script/harbor/worker.py")
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(filePath: "/usr/bin/env")
      process.arguments = ["python3", "-B", worker.path, root.path, control.path, payload.path]
      process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = try output.fileHandleForReading.readToEnd() ?? Data()
      process.waitUntilExit()
      try #require(process.terminationStatus == 0)
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  private func requestBody() throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
    while true {
      let count = stream.read(&buffer, maxLength: 4 * 1_024)
      guard count >= 0 else { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
      if count == 0 { return body }
      body.append(contentsOf: buffer.prefix(count))
    }
  }

  override func stopLoading() {}
}
