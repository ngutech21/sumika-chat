import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Darwin)
  import Darwin
#endif

public enum WebAccessPolicy: String, Codable, CaseIterable, Equatable, Sendable {
  case off
  case askEachTime
  case allow

  public var displayName: String {
    switch self {
    case .off:
      "Off"
    case .askEachTime:
      "Ask each time"
    case .allow:
      "Allow"
    }
  }
}

public enum WebSearchProvider: String, Codable, CaseIterable, Equatable, Sendable {
  case duckDuckGo
  case searxng

  public var displayName: String {
    switch self {
    case .duckDuckGo:
      "DuckDuckGo"
    case .searxng:
      "SearXNG"
    }
  }
}

public struct WebAccessSettings: Codable, Equatable, Sendable {
  public var policy: WebAccessPolicy
  public var provider: WebSearchProvider
  public var searxngBaseURL: String

  public init(
    policy: WebAccessPolicy = .off,
    provider: WebSearchProvider = .duckDuckGo,
    searxngBaseURL: String = ""
  ) {
    self.policy = policy
    self.provider = provider
    self.searxngBaseURL = searxngBaseURL
  }

  public static let disabled = WebAccessSettings()

  private enum CodingKeys: String, CodingKey {
    case policy
    case provider
    case searxngBaseURL
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    policy = try container.decodeIfPresent(WebAccessPolicy.self, forKey: .policy, default: .off)
    provider = try container.decodeIfPresent(
      WebSearchProvider.self,
      forKey: .provider,
      default: .duckDuckGo
    )
    searxngBaseURL = try container.decodeIfPresent(
      String.self,
      forKey: .searxngBaseURL,
      default: ""
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(policy, forKey: .policy)
    try container.encode(provider, forKey: .provider)
    try container.encode(searxngBaseURL, forKey: .searxngBaseURL)
  }
}

public protocol WebAccessSettingsStoring: Sendable {
  func settings() async -> WebAccessSettings
  func save(settings: WebAccessSettings) async throws
}

private enum WebAccessSettingsFileCodingKeys: String, CodingKey {
  case settings
}

public actor WebAccessSettingsStore: WebAccessSettingsStoring {
  private struct SettingsFile: Codable {
    var settings: WebAccessSettings

    init(settings: WebAccessSettings) {
      self.settings = settings
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: WebAccessSettingsFileCodingKeys.self)
      settings = try container.decodeIfPresent(
        WebAccessSettings.self,
        forKey: .settings,
        default: .disabled
      )
    }
  }

  private let settingsURL: URL

  public init(
    settingsURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "web-access-settings.json", directoryHint: .notDirectory)
  ) {
    self.settingsURL = settingsURL
  }

  public func settings() async -> WebAccessSettings {
    readSettingsFile().settings
  }

  public func save(settings: WebAccessSettings) async throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(SettingsFile(settings: settings))
    try data.write(to: settingsURL, options: .atomic)
  }

  private func readSettingsFile() -> SettingsFile {
    guard
      let data = try? Data(contentsOf: settingsURL),
      let decoded = try? JSONDecoder().decode(SettingsFile.self, from: data)
    else {
      return SettingsFile(settings: .disabled)
    }

    return decoded
  }
}

public struct WebSearchRequest: Equatable, Sendable {
  public var query: String
  public var maxResults: Int
  public var settings: WebAccessSettings

  public init(query: String, maxResults: Int, settings: WebAccessSettings) {
    self.query = query
    self.maxResults = maxResults
    self.settings = settings
  }
}

public struct WebFetchRequest: Equatable, Sendable {
  public var url: URL
  public var maxBytes: Int
  public var timeoutSeconds: Int
  public var maxRedirects: Int

  public init(
    url: URL,
    maxBytes: Int = WebAccessLimits.maxFetchBytes,
    timeoutSeconds: Int = WebAccessLimits.fetchTimeoutSeconds,
    maxRedirects: Int = WebAccessLimits.maxRedirects
  ) {
    self.url = url
    self.maxBytes = maxBytes
    self.timeoutSeconds = timeoutSeconds
    self.maxRedirects = maxRedirects
  }
}

public protocol WebSearching: Sendable {
  func search(_ request: WebSearchRequest) async -> WebSearchToolResult
}

public protocol WebFetching: Sendable {
  func fetch(_ request: WebFetchRequest) async -> WebFetchToolResult
}

public enum WebAccessLimits {
  public static let maxQueryCharacters = 300
  public static let defaultSearchResultCount = 5
  public static let maxSearchResultCount = 10
  public static let maxSearchObservationResults = 5
  public static let maxSearchHTTPBytes = 512 * 1024
  public static let maxFetchBytes = 128 * 1024
  public static let maxFetchObservationCharacters = 12_000
  public static let fetchTimeoutSeconds = 15
  public static let maxRedirects = 4

  public static func cappedQuery(_ query: String) -> (String, Bool) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxQueryCharacters else {
      return (trimmed, false)
    }
    return (String(trimmed.prefix(maxQueryCharacters)), true)
  }

  public static func cappedResultCount(_ count: Int?) -> Int {
    min(max(count ?? defaultSearchResultCount, 1), maxSearchResultCount)
  }

  public static func cappedFetchBytes(_ maxBytes: Int?) -> Int {
    min(max(maxBytes ?? maxFetchBytes, 1), maxFetchBytes)
  }
}

public enum WebAccessError: LocalizedError, Equatable, Sendable {
  case disabled
  case invalidQuery
  case invalidURL(String)
  case missingSearXNGBaseURL
  case unsupportedURLScheme(String)
  case blockedHost(String)
  case blockedAddress(String)
  case tooManyRedirects
  case nonHTTPResponse
  case unsupportedContentType(String?)
  case invalidResponseEncoding
  case requestFailed(String)

  public var errorDescription: String? {
    switch self {
    case .disabled:
      "Web access is disabled."
    case .invalidQuery:
      "Search query is empty."
    case .invalidURL(let value):
      "Invalid URL: \(value)."
    case .missingSearXNGBaseURL:
      "SearXNG URL is required when SearXNG is selected."
    case .unsupportedURLScheme(let scheme):
      "Unsupported URL scheme: \(scheme). Only http and https are allowed."
    case .blockedHost(let host):
      "Blocked non-public host: \(host)."
    case .blockedAddress(let address):
      "Blocked non-public network address: \(address)."
    case .tooManyRedirects:
      "Too many redirects."
    case .nonHTTPResponse:
      "Response was not an HTTP response."
    case .unsupportedContentType(let contentType):
      "Unsupported content type: \(contentType ?? "unknown")."
    case .invalidResponseEncoding:
      "Response could not be decoded as text."
    case .requestFailed(let message):
      "Web request failed: \(message)"
    }
  }
}

public struct WebURLValidator: Sendable {
  public init() {}

  public func validatePublicHTTPURL(_ url: URL) -> WebAccessError? {
    validateHTTPURL(url, profile: .publicWebURL)
  }

  public func validateConfiguredSearchProviderHTTPURL(_ url: URL) -> WebAccessError? {
    validateHTTPURL(url, profile: .configuredSearchProviderURL)
  }

  public func validateHTTPURL(
    _ url: URL,
    profile: WebURLValidationProfile
  ) -> WebAccessError? {
    guard let scheme = url.scheme?.lowercased() else {
      return .invalidURL(url.absoluteString)
    }
    guard scheme == "http" || scheme == "https" else {
      return .unsupportedURLScheme(scheme)
    }
    guard url.user == nil, url.password == nil else {
      return .invalidURL(url.absoluteString)
    }
    guard let host = url.host(percentEncoded: false), !host.isEmpty else {
      return .invalidURL(url.absoluteString)
    }
    guard profile == .publicWebURL else {
      return nil
    }
    return validatePublicHost(host)
  }

  public func validatePublicHost(_ host: String) -> WebAccessError? {
    guard !normalizedPublicHost(host) else {
      return .blockedHost(host)
    }

    if WebAddressClassifier.isPrivateOrLocal(host) {
      return .blockedAddress(host)
    }

    return nil
  }

  public func isLocalOrPrivateHost(_ host: String) -> Bool {
    normalizedPublicHost(host) || WebAddressClassifier.isPrivateOrLocal(host)
  }

  private func normalizedPublicHost(_ host: String) -> Bool {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalizedHost.isEmpty
      || normalizedHost == "localhost"
      || normalizedHost.hasSuffix(".localhost")
      || normalizedHost.hasSuffix(".local")
  }
}

public enum WebURLValidationProfile: Sendable {
  case publicWebURL
  case configuredSearchProviderURL
}

private struct IPv4Address: Equatable {
  let octets: [Int]

  init?(_ value: String) {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
      return nil
    }
    var parsed: [Int] = []
    for part in parts {
      guard let octet = Int(part), octet >= 0, octet <= 255 else {
        return nil
      }
      parsed.append(octet)
    }
    octets = parsed
  }

  var isPrivateOrLocal: Bool {
    let first = octets[0]
    let second = octets[1]
    switch (first, second) {
    case (0, _), (10, _), (127, _), (169, 254):
      return true
    case (172, 16...31), (192, 168):
      return true
    case (224...255, _):
      return true
    default:
      return false
    }
  }
}

public protocol WebHTTPClient: Sendable {
  func data(
    for request: URLRequest,
    maxRedirects: Int,
    validationProfile: WebURLValidationProfile
  ) async throws -> (Data, URLResponse)
}

extension WebHTTPClient {
  public func data(
    for request: URLRequest,
    maxRedirects: Int
  ) async throws -> (Data, URLResponse) {
    try await data(
      for: request,
      maxRedirects: maxRedirects,
      validationProfile: .publicWebURL
    )
  }
}

public protocol WebHostResolving: Sendable {
  func addresses(for host: String) async throws -> [String]
}

public struct SystemWebHostResolver: WebHostResolving {
  public init() {}

  public func addresses(for host: String) async throws -> [String] {
    #if canImport(Darwin)
      return try await Task.detached {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &info)
        guard status == 0, let info else {
          throw WebAccessError.requestFailed(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(info) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let current = cursor {
          if let address = Self.addressString(from: current.pointee) {
            addresses.append(address)
          }
          cursor = current.pointee.ai_next
        }
        return addresses
      }.value
    #else
      _ = host
      return []
    #endif
  }

  #if canImport(Darwin)
    private static func addressString(from info: addrinfo) -> String? {
      guard let address = info.ai_addr else {
        return nil
      }

      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      switch info.ai_family {
      case AF_INET:
        var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          $0.pointee
        }
        guard
          inet_ntop(
            AF_INET,
            &socketAddress.sin_addr,
            &buffer,
            socklen_t(buffer.count)
          ) != nil
        else {
          return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
          pointer.baseAddress.flatMap(String.init(validatingCString:))
        }
      case AF_INET6:
        var socketAddress = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          $0.pointee
        }
        guard
          inet_ntop(
            AF_INET6,
            &socketAddress.sin6_addr,
            &buffer,
            socklen_t(buffer.count)
          ) != nil
        else {
          return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
          pointer.baseAddress.flatMap(String.init(validatingCString:))
        }
      default:
        return nil
      }
    }
  #endif
}

extension URLSession: WebHTTPClient {
  public func data(
    for request: URLRequest,
    maxRedirects: Int,
    validationProfile: WebURLValidationProfile = .publicWebURL
  ) async throws -> (Data, URLResponse) {
    try await URLSessionWebHTTPClient(session: self).data(
      for: request,
      maxRedirects: maxRedirects,
      validationProfile: validationProfile
    )
  }
}

public struct URLSessionWebHTTPClient: WebHTTPClient {
  private let session: URLSession
  private let urlValidator: WebURLValidator
  private let hostResolver: any WebHostResolving

  public init(
    session: URLSession = .shared,
    urlValidator: WebURLValidator = WebURLValidator(),
    hostResolver: any WebHostResolving = SystemWebHostResolver()
  ) {
    self.session = session
    self.urlValidator = urlValidator
    self.hostResolver = hostResolver
  }

  public func data(
    for request: URLRequest,
    maxRedirects: Int,
    validationProfile: WebURLValidationProfile = .publicWebURL
  ) async throws -> (Data, URLResponse) {
    var currentRequest = request
    var remainingRedirects = max(0, maxRedirects)

    while true {
      guard let currentURL = currentRequest.url else {
        throw WebAccessError.invalidURL("")
      }
      if let error = urlValidator.validateHTTPURL(currentURL, profile: validationProfile) {
        throw error
      }
      if validationProfile == .publicWebURL,
        let error = await resolvedHostValidationError(for: currentURL)
      {
        throw error
      }

      let delegate = WebHTTPClientTaskDelegate()
      let (data, response) = try await session.data(for: currentRequest, delegate: delegate)
      if validationProfile == .publicWebURL,
        let error = Self.connectedRemoteAddressValidationError(delegate.remoteAddresses)
      {
        throw error
      }
      guard
        let httpResponse = response as? HTTPURLResponse,
        (300..<400).contains(httpResponse.statusCode)
      else {
        return (data, response)
      }

      guard remainingRedirects > 0 else {
        throw WebAccessError.tooManyRedirects
      }
      remainingRedirects -= 1

      guard
        let location = httpResponse.value(forHTTPHeaderField: "Location"),
        let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL
      else {
        throw WebAccessError.requestFailed("Redirect response was missing a Location header.")
      }

      if let error = urlValidator.validateHTTPURL(nextURL, profile: validationProfile) {
        throw error
      }
      if validationProfile == .publicWebURL,
        let error = await resolvedHostValidationError(for: nextURL)
      {
        throw error
      }

      currentRequest.url = nextURL
    }
  }

  static func connectedRemoteAddressValidationError(
    _ remoteAddresses: [String]
  ) -> WebAccessError? {
    for address in remoteAddresses where WebAddressClassifier.isPrivateOrLocal(address) {
      return .blockedAddress(address)
    }
    return nil
  }

  private func resolvedHostValidationError(for url: URL) async -> WebAccessError? {
    guard let host = url.host(percentEncoded: false) else {
      return .blockedHost(url.absoluteString)
    }
    do {
      let addresses = try await hostResolver.addresses(for: host)
      for address in addresses where WebAddressClassifier.isPrivateOrLocal(address) {
        return .blockedAddress(address)
      }
      return nil
    } catch let error as WebAccessError {
      return error
    } catch {
      return .requestFailed(error.localizedDescription)
    }
  }
}

private final class WebHTTPClientTaskDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var collectedRemoteAddresses: [String] = []

  var remoteAddresses: [String] {
    lock.lock()
    defer { lock.unlock() }
    return collectedRemoteAddresses
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @Sendable (URLRequest?) -> Void
  ) {
    _ = session
    _ = task
    _ = response
    _ = request
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    _ = session
    _ = task
    let addresses = metrics.transactionMetrics.compactMap(\.remoteAddress)
    guard !addresses.isEmpty else {
      return
    }

    lock.lock()
    collectedRemoteAddresses.append(contentsOf: addresses)
    lock.unlock()
  }
}

public struct DefaultWebSearchService: WebSearching {
  private let httpClient: any WebHTTPClient
  private let urlValidator: WebURLValidator
  private let hostResolver: any WebHostResolving

  public init(
    httpClient: any WebHTTPClient = URLSessionWebHTTPClient(),
    urlValidator: WebURLValidator = WebURLValidator(),
    hostResolver: any WebHostResolving = SystemWebHostResolver()
  ) {
    self.httpClient = httpClient
    self.urlValidator = urlValidator
    self.hostResolver = hostResolver
  }

  public func search(_ request: WebSearchRequest) async -> WebSearchToolResult {
    let (query, queryTruncated) = WebAccessLimits.cappedQuery(request.query)
    guard !query.isEmpty else {
      return .failed(
        query: request.query, reason: .invalidArguments(.parserError("Search query is empty.")))
    }

    switch request.settings.provider {
    case .duckDuckGo:
      return await duckDuckGoSearch(
        query: query,
        maxResults: request.maxResults,
        queryTruncated: queryTruncated
      )
    case .searxng:
      return await searxngSearch(
        query: query,
        maxResults: request.maxResults,
        queryTruncated: queryTruncated,
        baseURL: request.settings.searxngBaseURL
      )
    }
  }

  private func duckDuckGoSearch(
    query: String,
    maxResults: Int,
    queryTruncated: Bool
  ) async -> WebSearchToolResult {
    var components = URLComponents(string: "https://duckduckgo.com/html/")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
    guard let url = components?.url else {
      return .failed(
        query: query, reason: .executionError("Could not build DuckDuckGo search URL."))
    }
    return await loadSearchPage(
      url: url,
      query: query,
      provider: .duckDuckGo,
      validationProfile: .publicWebURL,
      queryTruncated: queryTruncated,
      maxResults: maxResults
    ) { data in
      let html = String(data: data, encoding: .utf8) ?? ""
      return DuckDuckGoHTMLSearchParser().parse(html: html, maxResults: maxResults)
    }
  }

  private func searxngSearch(
    query: String,
    maxResults: Int,
    queryTruncated: Bool,
    baseURL: String
  ) async -> WebSearchToolResult {
    let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let baseURL = URL(string: trimmedBaseURL), !trimmedBaseURL.isEmpty else {
      return .failed(
        query: query,
        reason: .executionError(WebAccessError.missingSearXNGBaseURL.localizedDescription))
    }
    if let error = urlValidator.validateConfiguredSearchProviderHTTPURL(baseURL) {
      return .failed(query: query, reason: .executionError(error.localizedDescription))
    }
    guard let baseHost = baseURL.host(percentEncoded: false) else {
      return .failed(
        query: query,
        reason: .executionError(
          WebAccessError.invalidURL(baseURL.absoluteString).localizedDescription))
    }
    let validationProfile: WebURLValidationProfile =
      urlValidator.isLocalOrPrivateHost(baseHost)
      ? .configuredSearchProviderURL
      : .publicWebURL
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return .failed(query: query, reason: .executionError("Could not build SearXNG search URL."))
    }
    let pathComponents = components.path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    if pathComponents.isEmpty {
      components.path = "/search"
    } else if pathComponents.last?.lowercased() == "search" {
      components.path = "/" + pathComponents.joined(separator: "/")
    } else {
      components.path = "/" + pathComponents.joined(separator: "/") + "/search"
    }
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "format", value: "json"),
    ]
    guard let url = components.url else {
      return .failed(query: query, reason: .executionError("Could not build SearXNG search URL."))
    }
    return await loadSearchPage(
      url: url,
      query: query,
      provider: .searxng,
      validationProfile: validationProfile,
      queryTruncated: queryTruncated,
      maxResults: maxResults
    ) { data in
      try SearXNGJSONSearchParser().parse(data: data, maxResults: maxResults)
    }
  }

  private func loadSearchPage(
    url: URL,
    query: String,
    provider: WebSearchProvider,
    validationProfile: WebURLValidationProfile,
    queryTruncated: Bool,
    maxResults: Int,
    parser: (Data) throws -> [WebSearchResult]
  ) async -> WebSearchToolResult {
    if let error = urlValidator.validateHTTPURL(url, profile: validationProfile) {
      return .failed(query: query, reason: .executionError(error.localizedDescription))
    }
    if validationProfile == .publicWebURL,
      let error = await resolvedHostValidationError(for: url)
    {
      return .failed(query: query, reason: .executionError(error.localizedDescription))
    }

    do {
      var urlRequest = URLRequest(url: url)
      urlRequest.timeoutInterval = TimeInterval(WebAccessLimits.fetchTimeoutSeconds)
      urlRequest.setValue("Sumika/1.0", forHTTPHeaderField: "User-Agent")
      let (data, response) = try await httpClient.data(
        for: urlRequest,
        maxRedirects: WebAccessLimits.maxRedirects,
        validationProfile: validationProfile
      )
      guard let httpResponse = response as? HTTPURLResponse else {
        return .failed(
          query: query, reason: .executionError(WebAccessError.nonHTTPResponse.localizedDescription)
        )
      }
      guard (200..<300).contains(httpResponse.statusCode) else {
        return .failed(
          query: query,
          reason: .executionError("Search provider returned HTTP \(httpResponse.statusCode).")
        )
      }
      let limitedData = data.prefix(WebAccessLimits.maxSearchHTTPBytes)
      let results = try parser(Data(limitedData))
      return WebSearchToolResult(
        query: query,
        provider: provider,
        results: results,
        truncated: queryTruncated || data.count > WebAccessLimits.maxSearchHTTPBytes
          || results.count > maxResults
      )
    } catch {
      return .failed(query: query, reason: .executionError(error.localizedDescription))
    }
  }
}

public struct DefaultWebFetchService: WebFetching {
  private let extractor: any WebPageExtracting

  public init(
    httpClient: any WebHTTPClient = URLSessionWebHTTPClient(),
    urlValidator: WebURLValidator = WebURLValidator(),
    hostResolver: any WebHostResolving = SystemWebHostResolver()
  ) {
    self.extractor = BuiltInWebPageExtractor(
      httpClient: httpClient,
      urlValidator: urlValidator,
      hostResolver: hostResolver
    )
  }

  public init(extractor: any WebPageExtracting) {
    self.extractor = extractor
  }

  public func fetch(_ request: WebFetchRequest) async -> WebFetchToolResult {
    await extractor.extract(WebPageExtractionRequest(request))
  }
}

extension DefaultWebSearchService {
  fileprivate func resolvedHostValidationError(for url: URL) async -> WebAccessError? {
    guard let host = url.host(percentEncoded: false) else {
      return .blockedHost(url.absoluteString)
    }
    do {
      let addresses = try await hostResolver.addresses(for: host)
      for address in addresses where WebAddressClassifier.isPrivateOrLocal(address) {
        return .blockedAddress(address)
      }
      return nil
    } catch let error as WebAccessError {
      return error
    } catch {
      return .requestFailed(error.localizedDescription)
    }
  }
}

enum WebAddressClassifier {
  static func isPrivateOrLocal(_ address: String) -> Bool {
    let normalized = normalizedAddress(address)
    if let ipv4 = IPv4Address(normalized) {
      return ipv4.isPrivateOrLocal
    }
    if normalized.hasPrefix("::ffff:") {
      let mappedAddress = String(normalized.dropFirst("::ffff:".count))
      if let ipv4 = IPv4Address(mappedAddress) {
        return ipv4.isPrivateOrLocal
      }
    }
    return normalized == "::1"
      || normalized.hasPrefix("fe80:")
      || normalized.hasPrefix("fc")
      || normalized.hasPrefix("fd")
  }

  private static func normalizedAddress(_ address: String) -> String {
    var normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("["),
      let endIndex = normalized.firstIndex(of: "]")
    {
      normalized = String(normalized[normalized.index(after: normalized.startIndex)..<endIndex])
    }
    if let zoneIndex = normalized.firstIndex(of: "%") {
      normalized = String(normalized[..<zoneIndex])
    }
    return normalized
  }
}

public struct DuckDuckGoHTMLSearchParser: Sendable {
  private static let snippetAnchorRegex = compiledRegex(
    #"<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#,
    options: [.dotMatchesLineSeparators]
  )
  private static let snippetDivRegex = compiledRegex(
    #"<div[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</div>"#,
    options: [.dotMatchesLineSeparators]
  )
  private static let resultAnchorRegex = compiledRegex(
    #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
    options: [.dotMatchesLineSeparators]
  )

  public init() {}

  public func parse(html: String, maxResults: Int) -> [WebSearchResult] {
    let blocks = html.components(separatedBy: "result__body")
    return blocks.compactMap(parseResultBlock(_:)).prefix(maxResults).map(\.self)
  }

  private func parseResultBlock(_ block: String) -> WebSearchResult? {
    guard let link = firstAnchor(in: block) else {
      return nil
    }
    let snippet =
      firstMatch(in: block, using: Self.snippetAnchorRegex)
      ?? firstMatch(in: block, using: Self.snippetDivRegex)
    return WebSearchResult(
      title: WebTextExtractor.plainText(fromHTMLFragment: link.title),
      url: decodedDuckDuckGoRedirect(link.url),
      snippet: snippet.map(WebTextExtractor.plainText(fromHTMLFragment:))
    )
  }

  private func firstAnchor(in block: String) -> (title: String, url: String)? {
    guard let match = firstMatchGroups(in: block, using: Self.resultAnchorRegex) else {
      return nil
    }
    return (match[1], htmlDecoded(match[0]))
  }

  private func decodedDuckDuckGoRedirect(_ url: String) -> String {
    let decoded = htmlDecoded(url)
    guard
      let components = URLComponents(string: decoded),
      let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
      !uddg.isEmpty
    else {
      return decoded
    }
    return uddg
  }
}

public struct SearXNGJSONSearchParser: Sendable {
  private struct Response: Decodable {
    var results: [ResultItem]
  }

  private struct ResultItem: Decodable {
    var title: String?
    var url: String?
    var content: String?
  }

  public init() {}

  public func parse(data: Data, maxResults: Int) throws -> [WebSearchResult] {
    let response = try JSONDecoder().decode(Response.self, from: data)
    return response.results.compactMap { item in
      guard
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
        let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
        !title.isEmpty,
        !url.isEmpty
      else {
        return nil
      }
      return WebSearchResult(
        title: title,
        url: url,
        snippet: item.content?.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }.prefix(maxResults).map(\.self)
  }
}

public enum WebTextExtractor {
  private static let scriptRegex = compiledRegex(#"(?is)<script\b[^>]*>.*?</script>"#)
  private static let styleRegex = compiledRegex(#"(?is)<style\b[^>]*>.*?</style>"#)
  private static let lineBreakRegex = compiledRegex(#"(?i)<br\s*/?>"#)
  private static let blockCloseRegex = compiledRegex(#"(?i)</p>|</div>|</li>|</h[1-6]>"#)
  private static let tagRegex = compiledRegex(#"(?is)<[^>]+>"#)
  private static let horizontalWhitespaceRegex = compiledRegex(#"[ \t\r\f]+"#)
  private static let excessBlankLineRegex = compiledRegex(#"\n\s*\n\s*\n+"#)

  public static func extractText(from rawText: String, contentType: String?) -> String {
    guard let contentType, contentType.lowercased().contains("html") else {
      return collapseWhitespace(rawText)
    }
    return plainText(fromHTMLFragment: rawText)
  }

  public static func plainText(fromHTMLFragment html: String) -> String {
    var text = html
    text = replacingMatches(of: scriptRegex, in: text, with: " ")
    text = replacingMatches(of: styleRegex, in: text, with: " ")
    text = replacingMatches(of: lineBreakRegex, in: text, with: "\n")
    text = replacingMatches(of: blockCloseRegex, in: text, with: "\n")
    text = replacingMatches(of: tagRegex, in: text, with: " ")
    return collapseWhitespace(htmlDecoded(text))
  }

  private static func collapseWhitespace(_ text: String) -> String {
    var collapsed = replacingMatches(of: horizontalWhitespaceRegex, in: text, with: " ")
    collapsed = replacingMatches(of: excessBlankLineRegex, in: collapsed, with: "\n\n")
    return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replacingMatches(
    of regex: NSRegularExpression?,
    in text: String,
    with template: String
  ) -> String {
    guard let regex else {
      return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }
}

private func compiledRegex(
  _ pattern: String,
  options: NSRegularExpression.Options = []
) -> NSRegularExpression? {
  try? NSRegularExpression(pattern: pattern, options: options)
}

private func firstMatch(in text: String, using regex: NSRegularExpression?) -> String? {
  firstMatchGroups(in: text, using: regex)?.first
}

private func firstMatchGroups(in text: String, using regex: NSRegularExpression?) -> [String]? {
  guard let regex else {
    return nil
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
    return nil
  }
  return (1..<match.numberOfRanges).compactMap { index in
    guard let range = Range(match.range(at: index), in: text) else {
      return nil
    }
    return String(text[range])
  }
}

private func htmlDecoded(_ text: String) -> String {
  var decoded = text
  let entities = [
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": "\"",
    "&#39;": "'",
    "&apos;": "'",
  ]
  for (entity, value) in entities {
    decoded = decoded.replacingOccurrences(of: entity, with: value)
  }
  return decoded
}
