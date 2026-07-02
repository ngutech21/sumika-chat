import Foundation
import Testing

@testable import SumikaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

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
  func publicURLValidatorBlocksPrivateAddressClasses() throws {
    let validator = WebURLValidator()
    let blockedURLs = [
      "http://localhost:8000",
      "http://127.0.0.1:8000",
      "http://10.0.0.5",
      "http://172.16.0.1",
      "http://172.31.255.255",
      "http://192.168.1.10",
      "http://169.254.1.2",
      "http://224.0.0.1",
      "http://[::1]/",
      "http://[fe80::1]/",
      "http://[fc00::1]/",
      "http://[fd00::1]/",
    ]

    for value in blockedURLs {
      #expect(
        validator.validatePublicHTTPURL(try #require(URL(string: value))) != nil,
        "Expected \(value) to be blocked."
      )
    }

    #expect(validator.validatePublicHTTPURL(try #require(URL(string: "http://172.32.0.1"))) == nil)
    #expect(
      validator.validatePublicHTTPURL(try #require(URL(string: "http://93.184.216.34"))) == nil)
    #expect(
      validator.validatePublicHTTPURL(try #require(URL(string: "http://[2001:db8::1]/"))) == nil)
  }

  @Test
  func configuredSearchProviderValidatorAllowsLocalAndPrivateHTTPURLs() throws {
    let validator = WebURLValidator()
    let allowedURLs = [
      "http://localhost:8080",
      "http://127.0.0.1:8080",
      "http://192.168.1.10:8888",
      "http://[::1]:8080",
    ]

    for value in allowedURLs {
      #expect(
        validator.validateConfiguredSearchProviderHTTPURL(try #require(URL(string: value))) == nil,
        "Expected configured provider URL \(value) to be allowed."
      )
    }

    #expect(
      validator.validateConfiguredSearchProviderHTTPURL(
        try #require(URL(string: "file:///tmp/search"))
      ) != nil)
    #expect(
      validator.validateConfiguredSearchProviderHTTPURL(
        try #require(URL(string: "http://user:pass@localhost:8080"))
      ) != nil)
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
    #expect(await httpClient.validationProfiles == [.publicWebURL])
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
  func publicSearxngProviderBlocksPrivateResolvedAddressBeforeHTTPRequest() async throws {
    let httpClient = CapturingHTTPClient(
      data: try fixtureData("searxng-basic.json"),
      contentType: "application/json"
    )
    let service = DefaultWebSearchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["127.0.0.1"])
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

    guard case .failed(_, let reason) = result else {
      Issue.record("Expected public SearXNG private DNS resolution to fail.")
      return
    }
    #expect(reason.message.contains("Blocked non-public network address"))
    #expect(await httpClient.requests.isEmpty)
  }

  @Test
  func searxngProviderAllowsConfiguredLocalBaseURL() async throws {
    let httpClient = CapturingHTTPClient(
      data: try fixtureData("searxng-basic.json"),
      contentType: "application/json"
    )
    let service = DefaultWebSearchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["127.0.0.1"])
    )

    let result = await service.search(
      WebSearchRequest(
        query: "Swift URLSession",
        maxResults: 5,
        settings: WebAccessSettings(
          policy: .allow,
          provider: .searxng,
          searxngBaseURL: "http://127.0.0.1:8080"
        )
      )
    )

    guard case .success(_, .searxng, let results, _) = result else {
      Issue.record("Expected local SearXNG search to run.")
      return
    }
    #expect(results.count == 2)
    let requests = await httpClient.requests
    #expect(requests.first?.url?.absoluteString.contains("http://127.0.0.1:8080/search?") == true)
    #expect(await httpClient.validationProfiles == [.configuredWebProviderURL])
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

    guard case .failed(_, .builtIn, _, let reason) = result else {
      Issue.record("Expected private resolved address to fail.")
      return
    }
    #expect(reason.message.contains("Blocked non-public network address"))
    #expect(await httpClient.requests.isEmpty)
  }

  @Test
  func webFetchRejectsLocalhostBeforeRequest() async throws {
    let httpClient = CapturingHTTPClient(data: Data("local".utf8), contentType: "text/plain")
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.fetch(
      WebFetchRequest(url: try #require(URL(string: "http://localhost:8000/private")))
    )

    guard case .failed(_, .builtIn, _, let reason) = result else {
      Issue.record("Expected localhost web_fetch to fail.")
      return
    }
    #expect(reason.message.contains("Blocked non-public host"))
    #expect(await httpClient.requests.isEmpty)
  }

  @Test
  func firecrawlFetchUsesSelfHostedScrapeEndpointWithoutAuth() async throws {
    let response = """
      {
        "success": true,
        "data": {
          "markdown": "# Example Domain\\n\\nFetched through Firecrawl.",
          "metadata": {
            "sourceURL": "https://docs.example/final",
            "statusCode": 200
          }
        }
      }
      """
    let httpClient = CapturingHTTPClient(
      data: Data(response.utf8),
      contentType: "application/json"
    )
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: HostMappingResolver(addressesByHost: [
        "docs.example": ["93.184.216.34"]
      ])
    )

    let result = await service.fetch(
      WebFetchRequest(
        url: try #require(URL(string: "https://docs.example/page")),
        settings: WebAccessSettings(
          policy: .allow,
          fetchProvider: .firecrawl,
          firecrawlBaseURL: "http://127.0.0.1:3002"
        )
      )
    )

    guard
      case .success(
        _, .firecrawl, let finalURL, 200, let contentType, let content, let byteCount) = result
    else {
      Issue.record("Expected successful Firecrawl fetch.")
      return
    }
    #expect(finalURL == "https://docs.example/final")
    #expect(contentType == "text/markdown")
    #expect(content.text.contains("Fetched through Firecrawl."))
    #expect(byteCount == "# Example Domain\n\nFetched through Firecrawl.".utf8.count)
    #expect(result.preview.text.contains("Fetch provider: Firecrawl"))

    let requests = await httpClient.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "http://127.0.0.1:3002/v2/scrape")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let payload = try JSONDecoder().decode(
      FirecrawlRequestBody.self,
      from: try #require(request.httpBody)
    )
    #expect(payload.url == "https://docs.example/page")
    #expect(payload.formats == ["markdown"])
    #expect(payload.onlyMainContent)
    #expect(payload.waitFor == 1_000)
    #expect(await httpClient.validationProfiles == [.configuredWebProviderURL])
  }

  @Test
  func firecrawlFetchRejectsTargetNon2xxStatus() async throws {
    let response = """
      {
        "success": true,
        "data": {
          "markdown": "Missing page evidence",
          "metadata": {
            "sourceURL": "https://docs.example/missing",
            "statusCode": 404
          }
        }
      }
      """
    let httpClient = CapturingHTTPClient(
      data: Data(response.utf8),
      contentType: "application/json"
    )
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: HostMappingResolver(addressesByHost: [
        "docs.example": ["93.184.216.34"]
      ])
    )
    let url = try #require(URL(string: "https://docs.example/page"))

    let result = await service.fetch(
      WebFetchRequest(
        url: url,
        settings: WebAccessSettings(
          policy: .allow,
          fetchProvider: .firecrawl,
          firecrawlBaseURL: "http://127.0.0.1:3002"
        )
      )
    )

    guard case .failed(let requestedURL, .firecrawl, let finalURL, let reason) = result else {
      Issue.record("Expected Firecrawl target 404 to fail.")
      return
    }
    #expect(requestedURL == url.absoluteString)
    #expect(finalURL == "https://docs.example/missing")
    #expect(reason.message == "Fetch returned HTTP 404.")
    #expect(!reason.message.contains("Missing page evidence"))
  }

  @Test
  func firecrawlFetchRejectsLocalhostTargetBeforeProviderRequest() async throws {
    let httpClient = CapturingHTTPClient(data: Data("{}".utf8), contentType: "application/json")
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FailingResolver()
    )

    let result = await service.fetch(
      WebFetchRequest(
        url: try #require(URL(string: "http://localhost:8000/private")),
        settings: WebAccessSettings(
          policy: .allow,
          fetchProvider: .firecrawl,
          firecrawlBaseURL: "http://127.0.0.1:3002"
        )
      )
    )

    guard case .failed(_, .firecrawl, _, let reason) = result else {
      Issue.record("Expected localhost target to fail.")
      return
    }
    #expect(reason.message.contains("Blocked non-public host"))
    #expect(await httpClient.requests.isEmpty)
  }

  @Test
  func firecrawlFetchRequiresConfiguredBaseURL() async throws {
    let httpClient = CapturingHTTPClient(data: Data("{}".utf8), contentType: "application/json")
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FailingResolver()
    )

    let result = await service.fetch(
      WebFetchRequest(
        url: try #require(URL(string: "https://docs.example/page")),
        settings: WebAccessSettings(policy: .allow, fetchProvider: .firecrawl)
      )
    )

    guard case .failed(_, .firecrawl, _, let reason) = result else {
      Issue.record("Expected missing Firecrawl URL to fail.")
      return
    }
    #expect(reason.message == "Firecrawl URL is required when Firecrawl is selected.")
    #expect(await httpClient.requests.isEmpty)
  }

  @Test
  func publicFirecrawlProviderBlocksPrivateResolvedAddressBeforeHTTPRequest() async throws {
    let httpClient = CapturingHTTPClient(data: Data("{}".utf8), contentType: "application/json")
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: HostMappingResolver(addressesByHost: [
        "docs.example": ["93.184.216.34"],
        "firecrawl.example": ["127.0.0.1"],
      ])
    )

    let result = await service.fetch(
      WebFetchRequest(
        url: try #require(URL(string: "https://docs.example/page")),
        settings: WebAccessSettings(
          policy: .allow,
          fetchProvider: .firecrawl,
          firecrawlBaseURL: "https://firecrawl.example"
        )
      )
    )

    guard case .failed(_, .firecrawl, _, let reason) = result else {
      Issue.record("Expected public Firecrawl private DNS resolution to fail.")
      return
    }
    #expect(reason.message.contains("Blocked non-public network address"))
    #expect(await httpClient.requests.isEmpty)
  }

  @Test
  func urlSessionHTTPClientBlocksPrivateConnectedRemoteAddress() throws {
    let error = URLSessionWebHTTPClient.connectedRemoteAddressValidationError([
      "93.184.216.34",
      "127.0.0.1",
    ])

    guard case .blockedAddress(let address) = error else {
      Issue.record("Expected private connected remote address to be blocked.")
      return
    }
    #expect(address == "127.0.0.1")
  }

  @Test
  func urlSessionHTTPClientAllowsPublicConnectedRemoteAddresses() throws {
    let error = URLSessionWebHTTPClient.connectedRemoteAddressValidationError([
      "93.184.216.34",
      "2001:db8::1",
      "[2001:db8::2]",
    ])

    #expect(error == nil)
  }

  @Test
  func urlSessionHTTPClientBlocksIPv4MappedPrivateRemoteAddress() throws {
    let error = URLSessionWebHTTPClient.connectedRemoteAddressValidationError([
      "::ffff:192.168.1.10"
    ])

    guard case .blockedAddress(let address) = error else {
      Issue.record("Expected IPv4-mapped private address to be blocked.")
      return
    }
    #expect(address == "::ffff:192.168.1.10")
  }

  @Test
  func webFetchRemoteAddressFailureKeepsCompactToolReason() async throws {
    let service = DefaultWebFetchService(
      httpClient: ThrowingHTTPClient(error: WebAccessError.blockedAddress("127.0.0.1")),
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.fetch(
      WebFetchRequest(url: try #require(URL(string: "https://docs.example/page")))
    )

    guard case .failed(_, _, _, let reason) = result else {
      Issue.record("Expected remote address block to fail web_fetch.")
      return
    }
    #expect(reason.message.contains("Blocked non-public network address: 127.0.0.1."))
    #expect(!reason.message.contains("URLSessionTaskMetrics"))
    #expect(!reason.message.contains("remoteAddress"))
  }

  @Test
  func webFetchRejects404HTMLResponseWithoutExposingBody() async throws {
    let httpClient = CapturingHTTPClient(
      data: Data("<html><body>Missing page evidence</body></html>".utf8),
      statusCode: 404,
      contentType: "text/html"
    )
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )
    let url = try #require(URL(string: "https://docs.example/missing"))

    let result = await service.fetch(WebFetchRequest(url: url))

    guard case .failed(let requestedURL, .builtIn, let finalURL, let reason) = result else {
      Issue.record("Expected 404 web_fetch response to fail.")
      return
    }
    #expect(requestedURL == url.absoluteString)
    #expect(finalURL == url.absoluteString)
    #expect(reason.message == "Fetch returned HTTP 404.")
    #expect(!reason.message.contains("Missing page evidence"))
  }

  @Test
  func webFetchRejects500PlainTextResponse() async throws {
    let httpClient = CapturingHTTPClient(
      data: Data("server error body".utf8),
      statusCode: 500,
      contentType: "text/plain"
    )
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.fetch(
      WebFetchRequest(url: try #require(URL(string: "https://docs.example/failure")))
    )

    guard case .failed(_, .builtIn, _, let reason) = result else {
      Issue.record("Expected 500 web_fetch response to fail.")
      return
    }
    #expect(reason.message == "Fetch returned HTTP 500.")
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
    guard case .webFetch(.success(_, .builtIn, _, 200, _, let content, _)) = record.resultPayload
    else {
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

    guard case .success(_, .builtIn, _, 200, _, let content, 200) = result else {
      Issue.record("Expected successful truncated fetch.")
      return
    }
    #expect(content.text.count == 32)
    #expect(content.truncated)
  }

  @Test
  func swiftSoupExtractorRemovesPageChromeAndKeepsArticleText() throws {
    let html = """
      <html>
        <body>
          <nav>Home Docs Pricing</nav>
          <article>
            <h1>Local Model Coding</h1>
            <p>Small local models work best when coding tasks are broken into focused steps with inspectable context and clear review points.</p>
            <p>The extractor should keep these article paragraphs while removing navigation, forms, sidebars, and footer copy.</p>
          </article>
          <aside>Related promo links should disappear.</aside>
          <footer>Copyright and legal links.</footer>
        </body>
      </html>
      """

    let text = SwiftSoupMainContentExtractor().extractText(
      fromHTML: html,
      baseURL: try #require(URL(string: "https://docs.example/article"))
    )

    #expect(text.contains("Local Model Coding"))
    #expect(text.contains("Small local models work best"))
    #expect(!text.contains("Home Docs Pricing"))
    #expect(!text.contains("Copyright and legal links"))
  }

  @Test
  func swiftSoupExtractorPrefersArticleOverLinkHeavyRelatedContent() throws {
    let relatedLinks = (0..<20)
      .map { "<a href=\"/related-\($0)\">Related navigation link \($0)</a>" }
      .joined(separator: " ")
    let html = """
      <html>
        <body>
          <div class="related">\(relatedLinks)</div>
          <article class="post-content">
            <h1>Focused Context</h1>
            <p>Useful extraction prefers dense article paragraphs over long blocks that are mostly links and repeated recommendations.</p>
            <p>This paragraph gives the article enough real text to win against boilerplate and related content areas.</p>
          </article>
        </body>
      </html>
      """

    let text = SwiftSoupMainContentExtractor().extractText(
      fromHTML: html,
      baseURL: try #require(URL(string: "https://docs.example/context"))
    )

    #expect(text.contains("Focused Context"))
    #expect(text.contains("Useful extraction prefers dense article paragraphs"))
    #expect(!text.contains("Related navigation link"))
  }

  @Test
  func swiftSoupExtractorPrefersMainRoleCandidate() throws {
    let html = """
      <html>
        <body>
          <div>
            <p>Generic page text can be present, but the main region should be preferred when it contains coherent paragraphs.</p>
          </div>
          <main>
            <h1>Installation Guide</h1>
            <p>The main element contains the actual documentation page and should be selected as the best readable content block.</p>
            <p>Keeping this content gives the model the useful instructions instead of surrounding layout copy.</p>
          </main>
        </body>
      </html>
      """

    let text = SwiftSoupMainContentExtractor().extractText(
      fromHTML: html,
      baseURL: try #require(URL(string: "https://docs.example/install"))
    )

    #expect(text.contains("Installation Guide"))
    #expect(text.contains("actual documentation page"))
    #expect(!text.contains("Generic page text can be present"))
  }

  @Test
  func swiftSoupExtractorHandlesRelativeLinksWithBaseURL() throws {
    let html = """
      <html>
        <body>
          <article>
            <h1>API Reference</h1>
            <p>Read the <a href="/reference">reference guide</a> before using the command examples in production workflows.</p>
            <p>Relative links and image paths should not prevent readable text extraction from the page body.</p>
          </article>
        </body>
      </html>
      """

    let text = SwiftSoupMainContentExtractor().extractText(
      fromHTML: html,
      baseURL: try #require(URL(string: "https://docs.example/base/path"))
    )

    #expect(text.contains("reference guide"))
    #expect(text.contains("Relative links and image paths"))
  }

  @Test
  func swiftSoupExtractorFallsBackToBodyTextWhenNoCandidateIsStrong() throws {
    let html = """
      <html>
        <body>
          <p>Short standalone page.</p>
          <p>No large article wrapper exists.</p>
        </body>
      </html>
      """

    let text = SwiftSoupMainContentExtractor().extractText(
      fromHTML: html,
      baseURL: try #require(URL(string: "https://docs.example/simple"))
    )

    #expect(text.contains("Short standalone page."))
    #expect(text.contains("No large article wrapper exists."))
  }

  @Test
  func swiftSoupExtractorDoesNotDuplicateNestedBlockText() throws {
    let html = """
      <html>
        <body>
          <article>
            <h1>Nested Blocks</h1>
            <blockquote>
              <p>Quoted guidance should appear once even when nested inside a blockquote element.</p>
            </blockquote>
            <ul>
              <li><p>List guidance should also appear once even when wrapped in a paragraph.</p></li>
            </ul>
            <p>The final paragraph gives the article enough standalone content for extraction.</p>
          </article>
        </body>
      </html>
      """

    let text = SwiftSoupMainContentExtractor().extractText(
      fromHTML: html,
      baseURL: try #require(URL(string: "https://docs.example/nested"))
    )

    #expect(text.components(separatedBy: "Quoted guidance should appear once").count == 2)
    #expect(text.components(separatedBy: "List guidance should also appear once").count == 2)
  }

  @Test
  func webFetchUsesBuiltInHTMLExtractor() async throws {
    let html = """
      <html>
        <body>
          <nav>Top navigation should be removed.</nav>
          <main>
            <h1>Fetched Article</h1>
            <p>The default fetch service should return the extracted main content for HTML pages instead of raw page chrome.</p>
            <p>This keeps web observations smaller and more relevant for the model context.</p>
          </main>
        </body>
      </html>
      """
    let httpClient = CapturingHTTPClient(data: Data(html.utf8), contentType: "text/html")
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.fetch(
      WebFetchRequest(url: try #require(URL(string: "https://docs.example/fetched")))
    )

    guard case .success(_, .builtIn, _, 200, _, let content, _) = result else {
      Issue.record("Expected successful HTML fetch.")
      return
    }
    #expect(content.text.contains("Fetched Article"))
    #expect(content.text.contains("extracted main content"))
    #expect(!content.text.contains("Top navigation should be removed"))
  }

  @Test
  func defaultWebFetchServiceDelegatesToInjectedExtractor() async throws {
    let extractor = RecordingPageExtractor()
    let service = DefaultWebFetchService(extractor: extractor)
    let url = try #require(URL(string: "https://docs.example/delegated"))

    let result = await service.fetch(
      WebFetchRequest(url: url, maxBytes: 123, timeoutSeconds: 7, maxRedirects: 2)
    )

    guard case .success(_, .builtIn, _, 200, _, let content, _) = result else {
      Issue.record("Expected injected extractor result.")
      return
    }
    #expect(content.text == "delegated")
    let requests = await extractor.requests
    #expect(
      requests == [
        WebPageExtractionRequest(url: url, maxBytes: 123, timeoutSeconds: 7, maxRedirects: 2)
      ])
  }

  @Test
  func webFetchKeepsPlainTextNormalizationForNonHTML() async throws {
    let httpClient = CapturingHTTPClient(
      data: Data("alpha\t\tbeta\n\n\n\ngamma".utf8),
      contentType: "text/plain"
    )
    let service = DefaultWebFetchService(
      httpClient: httpClient,
      hostResolver: FakeResolver(addresses: ["93.184.216.34"])
    )

    let result = await service.fetch(
      WebFetchRequest(url: try #require(URL(string: "https://docs.example/plain")))
    )

    guard case .success(_, .builtIn, _, 200, _, let content, _) = result else {
      Issue.record("Expected successful plain-text fetch.")
      return
    }
    #expect(content.text == "alpha beta\n\ngamma")
  }

  @Test
  func webAccessSettingsStorePersistsGlobalSettings() async throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "web-access-\(UUID().uuidString).json", directoryHint: .notDirectory)
    let settings = WebAccessSettings(
      policy: .allow,
      provider: .searxng,
      searxngBaseURL: "https://search.example",
      fetchProvider: .firecrawl,
      firecrawlBaseURL: "http://127.0.0.1:3002"
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
    .appending(path: "sumika-web-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return Workspace(name: "Web Tests", rootURL: root)
}

private struct FirecrawlRequestBody: Decodable {
  var url: String
  var formats: [String]
  var onlyMainContent: Bool
  var waitFor: Int
}

private actor CapturingHTTPClient: WebHTTPClient {
  let data: Data
  let statusCode: Int
  let contentType: String
  private(set) var requests: [URLRequest] = []
  private(set) var validationProfiles: [WebURLValidationProfile] = []

  init(data: Data, statusCode: Int = 200, contentType: String) {
    self.data = data
    self.statusCode = statusCode
    self.contentType = contentType
  }

  func data(
    for request: URLRequest,
    maxRedirects: Int,
    validationProfile: WebURLValidationProfile
  ) async throws -> (Data, URLResponse) {
    _ = maxRedirects
    requests.append(request)
    validationProfiles.append(validationProfile)
    let response = HTTPURLResponse(
      url: try #require(request.url),
      statusCode: statusCode,
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

private struct HostMappingResolver: WebHostResolving {
  var addressesByHost: [String: [String]]

  func addresses(for host: String) async throws -> [String] {
    addressesByHost[host] ?? []
  }
}

private struct FailingResolver: WebHostResolving {
  func addresses(for host: String) async throws -> [String] {
    throw WebAccessError.requestFailed("Unexpected DNS resolution for \(host).")
  }
}

private struct ThrowingHTTPClient: WebHTTPClient {
  var error: Error

  func data(
    for request: URLRequest,
    maxRedirects: Int,
    validationProfile: WebURLValidationProfile
  ) async throws -> (Data, URLResponse) {
    _ = request
    _ = maxRedirects
    _ = validationProfile
    throw error
  }
}

private struct FakeFetcher: WebFetching {
  func fetch(_ request: WebFetchRequest) async -> WebFetchToolResult {
    WebFetchToolResult(
      url: request.url.absoluteString,
      provider: request.settings.fetchProvider,
      finalURL: request.url.absoluteString,
      statusCode: 200,
      contentType: "text/plain",
      content: ToolTextOutput(text: "Fetched fixture text."),
      byteCount: 21
    )
  }
}

private actor RecordingPageExtractor: WebPageExtracting {
  private(set) var requests: [WebPageExtractionRequest] = []

  func extract(_ request: WebPageExtractionRequest) async -> WebFetchToolResult {
    requests.append(request)
    return WebFetchToolResult(
      url: request.url.absoluteString,
      provider: .builtIn,
      finalURL: request.url.absoluteString,
      statusCode: 200,
      contentType: "text/plain",
      content: ToolTextOutput(text: "delegated"),
      byteCount: 9
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
