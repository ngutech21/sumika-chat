import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import Testing

@testable import LocalCoderCore

struct WebAccessTests {
  @Test
  func duckDuckGoHTMLParserReadsLocalFixture() throws {
    let html = try fixtureText("duckduckgo-lite-basic.html")
    let results = DuckDuckGoHTMLSearchParser().parse(html: html, maxResults: 10)

    #expect(results.count == 2)
    #expect(results[0].title == "Swift Documentation")
    #expect(results[0].url == "https://www.swift.org/documentation/")
    #expect(results[0].snippet == "Swift docs for the language and packages.")
    #expect(results[1].title == "URLSession | Apple Developer Documentation")
  }

  @Test
  func searxngJSONParserReadsLocalFixture() throws {
    let data = try fixtureData("searxng-basic.json")
    let results = try SearXNGJSONSearchParser().parse(data: data, maxResults: 1)

    #expect(results.count == 1)
    #expect(results[0].title == "Swift.org - Documentation")
    #expect(results[0].url == "https://www.swift.org/documentation/")
    #expect(results[0].snippet == "Documentation for Swift packages and language features.")
  }

  @Test
  func urlValidatorBlocksLocalPrivateAndNonHTTPURLs() throws {
    let validator = WebURLValidator()

    #expect(validator.validatePublicHTTPURL(try #require(URL(string: "file:///tmp/a"))) != nil)
    #expect(
      validator.validatePublicHTTPURL(try #require(URL(string: "http://localhost:8000"))) != nil)
    #expect(
      validator.validatePublicHTTPURL(try #require(URL(string: "http://127.0.0.1:8000"))) != nil)
    #expect(
      validator.validatePublicHTTPURL(try #require(URL(string: "http://192.168.1.10"))) != nil)
    #expect(
      validator.validatePublicHTTPURL(try #require(URL(string: "https://www.swift.org"))) == nil)
  }

  @Test
  func searxngProviderUsesJSONEndpointFromConfiguredBaseURL() async throws {
    let httpClient = CapturingHTTPClient(
      data: try fixtureData("searxng-basic.json"),
      contentType: "application/json"
    )
    let service = DefaultWebSearchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.search(
      WebSearchRequest(
        query: "Swift URLSession",
        maxResults: 5,
        settings: WebAccessSettings(
          policy: .allow,
          provider: .searxng,
          searxngBaseURL: "https://search.example"
        )
      )
    )

    let requests = await httpClient.requests
    #expect(requests.count == 1)
    #expect(requests[0].url?.absoluteString.contains("https://search.example/search?") == true)
    #expect(requests[0].url?.query?.contains("format=json") == true)
    guard case .success(_, .searxng, let results, _) = result else {
      Issue.record("Expected successful SearXNG search.")
      return
    }
    #expect(results.count == 2)
  }

  @Test
  func searxngProviderDoesNotAppendSearchTwiceWhenEndpointIsConfigured() async throws {
    let httpClient = CapturingHTTPClient(
      data: try fixtureData("searxng-basic.json"),
      contentType: "application/json"
    )
    let service = DefaultWebSearchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    _ = await service.search(
      WebSearchRequest(
        query: "Swift URLSession",
        maxResults: 5,
        settings: WebAccessSettings(
          policy: .allow,
          provider: .searxng,
          searxngBaseURL: "https://search.example/search"
        )
      )
    )

    let url = try #require(await httpClient.requests.first?.url?.absoluteString)
    #expect(url.contains("https://search.example/search?"))
    #expect(!url.contains("/search/search"))
  }

  @Test
  func webSearchCapsLongQueriesBeforeHTTPRequest() async throws {
    let httpClient = CapturingHTTPClient(
      data: try fixtureData("searxng-basic.json"),
      contentType: "application/json"
    )
    let service = DefaultWebSearchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.search(
      WebSearchRequest(
        query: String(repeating: "x", count: WebAccessLimits.maxQueryCharacters + 20),
        maxResults: 5,
        settings: WebAccessSettings(
          policy: .allow,
          provider: .searxng,
          searxngBaseURL: "https://search.example"
        )
      )
    )

    let query = await httpClient.requests.first?.url?.query ?? ""
    #expect(query.contains(String(repeating: "x", count: WebAccessLimits.maxQueryCharacters)))
    guard case .success(let cappedQuery, _, _, let truncated) = result else {
      Issue.record("Expected successful capped search.")
      return
    }
    #expect(cappedQuery.count == WebAccessLimits.maxQueryCharacters)
    #expect(truncated)
  }

  @Test
  func webFetchBlocksResolvedPrivateAddressesBeforeRequest() async throws {
    let httpClient = CapturingHTTPClient(data: Data("private".utf8), contentType: "text/plain")
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["10.0.0.5"])
    )

    let result = await service.fetch(
      WebFetchRequest(url: try #require(URL(string: "https://docs.example/page")))
    )

    guard case .failed(_, _, let reason) = result else {
      Issue.record("Expected private resolved address to fail.")
      return
    }
    #expect(reason.message.contains("Blocked non-public network address"))
    #expect(await httpClient.requests.isEmpty)
  }

  @Test
  func urlSessionHTTPClientBlocksPrivateRedirectBeforeSecondRequest() async throws {
    PrivateRedirectURLProtocol.state.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PrivateRedirectURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = URLSessionWebHTTPClient(
      session: session,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )
    let request = URLRequest(url: try #require(URL(string: "https://public.example/start")))

    do {
      _ = try await client.data(for: request, maxRedirects: 4)
      Issue.record("Expected redirect to a private address to be blocked.")
    } catch WebAccessError.blockedAddress(let address) {
      #expect(address == "127.0.0.1")
    } catch {
      Issue.record("Expected blockedAddress, got \(error).")
    }

    let requestedHosts = PrivateRedirectURLProtocol.state.requestedURLs()
      .compactMap(\.host)
    #expect(requestedHosts == ["public.example"])
  }

  @Test
  func webFetchToolRequiresApprovalWhenPolicyAsksEachTime() async throws {
    let workspace = try makeWorkspace()
    let raw = RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: UUID(),
      toolName: .webFetch,
      arguments: ["url": .string("https://www.swift.org/documentation/")]
    )
    let orchestrator = ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([AnyToolExecutor(WebFetchToolExecutor())]),
      webFetcher: FakeFetcher(),
      webAccessSettingsProvider: {
        WebAccessSettings(policy: .askEachTime, provider: .duckDuckGo)
      }
    )

    let record = await orchestrator.execute(request: raw, workspace: workspace)

    #expect(record.status == .awaitingApproval)
    #expect(record.approvalPreview?.text.contains("Web fetch requires approval") == true)
  }

  @Test
  func webFetchToolRunsWhenPolicyAllowsWorkspace() async throws {
    let workspace = try makeWorkspace()
    let raw = RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: UUID(),
      toolName: .webFetch,
      arguments: ["url": .string("https://www.swift.org/documentation/")]
    )
    let orchestrator = ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([AnyToolExecutor(WebFetchToolExecutor())]),
      webFetcher: FakeFetcher(),
      webAccessSettingsProvider: {
        WebAccessSettings(policy: .allow, provider: .duckDuckGo)
      }
    )

    let record = await orchestrator.execute(request: raw, workspace: workspace)

    #expect(record.status == .completed)
    guard case .webFetch(.success(_, _, 200, _, let content, _)) = record.resultPayload else {
      Issue.record("Expected successful web_fetch payload.")
      return
    }
    #expect(content.text == "Fetched fixture text.")
  }

  @Test
  func webFetchCapsTextOutputAndMarksTruncation() async throws {
    let httpClient = CapturingHTTPClient(
      data: Data(String(repeating: "a", count: 200).utf8),
      contentType: "text/plain"
    )
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.fetch(
      WebFetchRequest(
        url: try #require(URL(string: "https://docs.example/page")),
        maxBytes: 32
      )
    )

    guard case .success(_, _, 200, _, let content, 200) = result else {
      Issue.record("Expected successful truncated fetch.")
      return
    }
    #expect(content.text.count == 32)
    #expect(content.truncated)
  }

  @Test
  func webAccessSettingsStorePersistsGlobalSettings() async throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "web-access-\(UUID().uuidString).json", directoryHint: .notDirectory)
    let settings = WebAccessSettings(
      policy: .allow,
      provider: .searxng,
      searxngBaseURL: "https://search.example"
    )

    let store = WebAccessSettingsStore(settingsURL: url)
    try await store.save(settings: settings)
    let reloaded = WebAccessSettingsStore(settingsURL: url)

    #expect(await reloaded.settings() == settings)
  }
}

private func fixtureData(_ name: String) throws -> Data {
  let fixtureURL = try #require(
    Bundle.module.url(
      forResource: name,
      withExtension: nil
    )
  )
  return try Data(contentsOf: fixtureURL)
}

private func fixtureText(_ name: String) throws -> String {
  try #require(String(data: try fixtureData(name), encoding: .utf8))
}

private func makeWorkspace() throws -> Workspace {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "local-coder-web-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return Workspace(name: "Web Tests", rootURL: root)
}

private actor CapturingHTTPClient: WebHTTPClient {
  let data: Data
  let contentType: String
  private(set) var requests: [URLRequest] = []

  init(data: Data, contentType: String) {
    self.data = data
    self.contentType = contentType
  }

  func data(for request: URLRequest, maxRedirects: Int) async throws -> (Data, URLResponse) {
    _ = maxRedirects
    requests.append(request)
    let response = HTTPURLResponse(
      url: try #require(request.url),
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": contentType]
    )
    return (data, try #require(response))
  }
}

private struct FakeResolver: WebHostResolving {
  var addresses: [String]

  func addresses(for host: String) async throws -> [String] {
    _ = host
    return addresses
  }
}

private struct FakeFetcher: WebFetching {
  func fetch(_ request: WebFetchRequest) async -> WebFetchToolResult {
    WebFetchToolResult(
      url: request.url.absoluteString,
      finalURL: request.url.absoluteString,
      statusCode: 200,
      contentType: "text/plain",
      content: ToolTextOutput(text: "Fetched fixture text."),
      byteCount: 21
    )
  }
}

private final class PrivateRedirectURLProtocol: URLProtocol {
  static let state = RedirectProtocolState()

  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "public.example" || request.url?.host == "127.0.0.1"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let (response, data) = try Self.state.response(for: request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private final class RedirectProtocolState: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    urls = []
  }

  func requestedURLs() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return urls
  }

  func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    lock.lock()
    urls.append(url)
    lock.unlock()
    let fields: [String: String]
    let statusCode: Int
    let data: Data
    if url.host == "public.example" {
      statusCode = 302
      fields = ["Location": "http://127.0.0.1/private"]
      data = Data()
    } else {
      statusCode = 200
      fields = ["Content-Type": "text/plain"]
      data = Data("private response must not be requested".utf8)
    }
    return (
      try #require(
        HTTPURLResponse(
          url: url,
          statusCode: statusCode,
          httpVersion: "HTTP/1.1",
          headerFields: fields
        )
      ),
      data
    )
  }
}
