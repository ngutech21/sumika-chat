import Foundation
import Synchronization
import Testing

@testable import SumikaCore
@testable import SumikaEval

@Suite(.serialized)
struct HarborWebAccessTests {
  @Test
  func enabledProfileUsesBridgeForSearchFetchAndDNS() async throws {
    WebBridgeURLProtocol.operations.withLock { $0.removeAll() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WebBridgeURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let backend = HarborWorkspaceBackend(
      bridgeURL: try #require(URL(string: "http://127.0.0.1:8765")), token: "test", session: session
    )
    let execution = WorkspaceExecution(fileIO: backend, commandRunner: backend, webClient: backend)
    let orchestrator = ToolOrchestrator.agent(
      todoWriteEnabled: false, workspaceExecution: execution
    )
    .replacingExecutorRegistry(execution.executorRegistry)
    let workspace = Workspace(name: "Web trial", rootURL: URL(filePath: "/app"))
    let fetch = await orchestrator.execute(
      request: RawToolCallRequest(
        workspaceID: workspace.id, sessionID: UUID(), toolName: .webFetch,
        arguments: ["url": .string("https://example.com/page")]), workspace: workspace)
    #expect(fetch.status == .completed)
    #expect(fetch.resultPayload?.preview.text.contains("Container page") == true)
    let search = await orchestrator.execute(
      request: RawToolCallRequest(
        workspaceID: workspace.id, sessionID: UUID(), toolName: .webSearch,
        arguments: ["query": .string("documentation")]), workspace: workspace)
    #expect(search.status == .completed)
    #expect(search.resultPayload?.preview.text.contains("Container search result") == true)
    #expect(
      WebBridgeURLProtocol.operations.withLock { $0 } == [
        "resolveHost", "http", "resolveHost", "resolveHost", "http",
      ])

    let disabled = WorkspaceExecution(fileIO: backend, commandRunner: backend)
    #expect(disabled.webAccessSettings.policy == .off)
    #expect(!disabled.executorRegistry.definitions.contains { $0.name == .webFetch })
    #expect(!disabled.executorRegistry.definitions.contains { $0.name == .webSearch })
  }

  @Test
  func failedContainerRequestHasNoHostFallback() async throws {
    WebBridgeURLProtocol.operations.withLock { $0.removeAll() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WebBridgeURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let backend = HarborWorkspaceBackend(
      bridgeURL: try #require(URL(string: "http://127.0.0.1:8765")), token: "test", session: session
    )
    let execution = WorkspaceExecution(fileIO: backend, commandRunner: backend, webClient: backend)
    let result = await execution.webFetcher.fetch(
      WebFetchRequest(
        url: try #require(URL(string: "https://denied.example/page")),
        settings: execution.webAccessSettings))
    guard case .failed(_, _, _, let reason) = result else {
      Issue.record("Expected container network failure")
      return
    }
    #expect(reason.message.contains("Container egress denied"))
    #expect(WebBridgeURLProtocol.operations.withLock { $0 } == ["resolveHost", "http"])
  }
}

private final class WebBridgeURLProtocol: URLProtocol, @unchecked Sendable {
  static let operations = Mutex<[String]>([])

  override static func canInit(with _: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let url = try #require(request.url)
      #expect(url.host == "127.0.0.1")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
      let body: Data
      if let data = request.httpBody {
        body = data
      } else {
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = stream.read(&buffer, maxLength: buffer.count)
          guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
          if count == 0 { break }
          data.append(contentsOf: buffer.prefix(count))
        }
        body = data
      }
      let rpc = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let operation = try #require(rpc["operation"] as? String)
      Self.operations.withLock { $0.append(operation) }
      var envelope: [String: Any] = ["id": try #require(rpc["id"] as? String)]
      if operation == "resolveHost" {
        envelope["result"] = ["addresses": ["93.184.216.34"]]
      } else {
        #expect(operation == "http")
        let target = try #require(rpc["url"] as? String)
        if target.contains("denied.example") {
          envelope["error"] = ["code": "webFailure", "message": "Container egress denied"]
        } else {
          let html =
            target.contains("duckduckgo.com")
            ? "<div class='result__body'><a class='result__a' href='https://example.com'>Container search result</a></div>"
            : "<html><body><main><p>Container page</p></main></body></html>"
          envelope["result"] = [
            "url": target, "statusCode": 200, "headers": ["Content-Type": "text/html"],
            "dataBase64": Data(html.utf8).base64EncodedString(),
          ]
        }
      }
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: envelope))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
