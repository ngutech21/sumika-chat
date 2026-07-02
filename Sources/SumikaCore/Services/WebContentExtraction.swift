import Foundation
import SwiftSoup

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct WebPageExtractionRequest: Equatable, Sendable {
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

  public init(_ request: WebFetchRequest) {
    self.init(
      url: request.url,
      maxBytes: request.maxBytes,
      timeoutSeconds: request.timeoutSeconds,
      maxRedirects: request.maxRedirects
    )
  }
}

public protocol WebPageExtracting: Sendable {
  func extract(_ request: WebPageExtractionRequest) async -> WebFetchToolResult
}

public struct BuiltInWebPageExtractor: WebPageExtracting {
  private let httpClient: any WebHTTPClient
  private let urlValidator: WebURLValidator
  private let hostResolver: any WebHostResolving
  private let htmlExtractor: SwiftSoupMainContentExtractor

  public init(
    httpClient: any WebHTTPClient = URLSessionWebHTTPClient(),
    urlValidator: WebURLValidator = WebURLValidator(),
    hostResolver: any WebHostResolving = SystemWebHostResolver(),
    htmlExtractor: SwiftSoupMainContentExtractor = SwiftSoupMainContentExtractor()
  ) {
    self.httpClient = httpClient
    self.urlValidator = urlValidator
    self.hostResolver = hostResolver
    self.htmlExtractor = htmlExtractor
  }

  public func extract(_ request: WebPageExtractionRequest) async -> WebFetchToolResult {
    if let error = urlValidator.validatePublicHTTPURL(request.url) {
      return .failed(
        url: request.url.absoluteString, provider: .builtIn, finalURL: nil,
        reason: .executionError(error.localizedDescription))
    }
    if let error = await resolvedHostValidationError(for: request.url) {
      return .failed(
        url: request.url.absoluteString, provider: .builtIn, finalURL: nil,
        reason: .executionError(error.localizedDescription))
    }

    do {
      var urlRequest = URLRequest(url: request.url)
      urlRequest.timeoutInterval = TimeInterval(request.timeoutSeconds)
      urlRequest.setValue("Sumika/1.0", forHTTPHeaderField: "User-Agent")
      let (data, response) = try await httpClient.data(
        for: urlRequest,
        maxRedirects: request.maxRedirects,
        validationProfile: .publicWebURL
      )
      guard let httpResponse = response as? HTTPURLResponse else {
        return .failed(
          url: request.url.absoluteString, provider: .builtIn, finalURL: nil,
          reason: .executionError(WebAccessError.nonHTTPResponse.localizedDescription))
      }
      let finalURL = httpResponse.url ?? request.url
      if let error = urlValidator.validatePublicHTTPURL(finalURL) {
        return .failed(
          url: request.url.absoluteString, provider: .builtIn, finalURL: finalURL.absoluteString,
          reason: .executionError(error.localizedDescription))
      }
      if let error = await resolvedHostValidationError(for: finalURL) {
        return .failed(
          url: request.url.absoluteString, provider: .builtIn, finalURL: finalURL.absoluteString,
          reason: .executionError(error.localizedDescription))
      }
      guard (200..<300).contains(httpResponse.statusCode) else {
        return .failed(
          url: request.url.absoluteString,
          provider: .builtIn,
          finalURL: finalURL.absoluteString,
          reason: .executionError("Fetch returned HTTP \(httpResponse.statusCode).")
        )
      }

      let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
      guard Self.isSupportedTextContentType(contentType) else {
        return .failed(
          url: request.url.absoluteString,
          provider: .builtIn,
          finalURL: finalURL.absoluteString,
          reason: .unsupportedFileType(contentType ?? "unknown")
        )
      }

      let maxBytes = WebAccessLimits.cappedFetchBytes(request.maxBytes)
      let truncated = data.count > maxBytes
      let limitedData = Data(data.prefix(maxBytes))
      guard !Self.looksBinary(limitedData) else {
        return .failed(
          url: request.url.absoluteString,
          provider: .builtIn,
          finalURL: finalURL.absoluteString,
          reason: .unsupportedFileType(contentType ?? "binary")
        )
      }
      guard let rawText = String(data: limitedData, encoding: .utf8) else {
        return .failed(
          url: request.url.absoluteString,
          provider: .builtIn,
          finalURL: finalURL.absoluteString,
          reason: .executionError(WebAccessError.invalidResponseEncoding.localizedDescription)
        )
      }

      let text = extractedText(from: rawText, contentType: contentType, finalURL: finalURL)
      let cappedText = String(text.prefix(WebAccessLimits.maxFetchObservationCharacters))
      return WebFetchToolResult(
        url: request.url.absoluteString,
        provider: .builtIn,
        finalURL: finalURL.absoluteString,
        statusCode: httpResponse.statusCode,
        contentType: contentType,
        content: ToolTextOutput(
          text: cappedText,
          truncated: truncated || text.count > cappedText.count
        ),
        byteCount: data.count
      )
    } catch {
      return .failed(
        url: request.url.absoluteString,
        provider: .builtIn,
        finalURL: nil,
        reason: .executionError(error.localizedDescription)
      )
    }
  }

  private func extractedText(from rawText: String, contentType: String?, finalURL: URL) -> String {
    guard let contentType, contentType.lowercased().contains("html") else {
      return WebTextExtractor.extractText(from: rawText, contentType: contentType)
    }
    return htmlExtractor.extractText(fromHTML: rawText, baseURL: finalURL)
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

  private static func isSupportedTextContentType(_ contentType: String?) -> Bool {
    guard let contentType else {
      return true
    }
    let normalized = contentType.lowercased()
    return normalized.hasPrefix("text/")
      || normalized.contains("application/json")
      || normalized.contains("application/xml")
      || normalized.contains("application/xhtml+xml")
      || normalized.contains("application/javascript")
      || normalized.contains("application/x-javascript")
  }

  private static func looksBinary(_ data: Data) -> Bool {
    data.prefix(512).contains(0)
  }
}

public struct SwiftSoupMainContentExtractor: Sendable {
  private static let boilerplateSelector = [
    "script",
    "style",
    "noscript",
    "template",
    "nav",
    "footer",
    "aside",
    "form",
    "iframe",
    "svg",
    "canvas",
    "button",
    "input",
  ].joined(separator: ", ")

  private static let candidateSelector = "article, main, [role=main], section, div"
  private static let blockSelector = "h1, h2, h3, h4, h5, h6, p, li, blockquote, pre"
  private static let positivePattern = #"article|content|post|entry|main|story"#
  private static let negativePattern = #"nav|footer|sidebar|comment|related|promo|ad|share"#

  public init() {}

  public func extractText(fromHTML html: String, baseURL: URL) -> String {
    do {
      let document = try SwiftSoup.parse(html, baseURL.absoluteString)
      try document.select(Self.boilerplateSelector).remove()
      let root = try bestContentElement(in: document) ?? document.body()
      guard let root else {
        return WebTextExtractor.plainText(fromHTMLFragment: html)
      }
      try root.select(Self.boilerplateSelector).remove()
      let extractedText = try readableText(from: root)
      guard !extractedText.isEmpty else {
        return WebTextExtractor.plainText(fromHTMLFragment: html)
      }
      return extractedText
    } catch {
      return WebTextExtractor.plainText(fromHTMLFragment: html)
    }
  }

  private func bestContentElement(in document: Document) throws -> Element? {
    let candidates = try document.select(Self.candidateSelector).array()
    let scoredCandidates = try candidates.map { candidate in
      (element: candidate, score: try score(candidate))
    }
    guard let best = scoredCandidates.max(by: { $0.score < $1.score }), best.score >= 120 else {
      return nil
    }
    return best.element
  }

  private func score(_ element: Element) throws -> Double {
    let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
    let textLength = Double(text.count)
    guard textLength >= 80 else {
      return 0
    }

    let paragraphCount = try element.select("p").array()
      .filter { try $0.text().count >= 40 }
      .count
    let headingCount = try element.select("h1, h2, h3").array().count
    let linkTextLength = try element.select("a").array()
      .map { try $0.text().count }
      .reduce(0, +)
    let linkDensity = Double(linkTextLength) / max(textLength, 1)
    let hints = try [
      element.tagName(),
      element.attr("class"),
      element.attr("id"),
      element.attr("role"),
    ].joined(separator: " ").lowercased()

    var score = textLength
    score += Double(paragraphCount) * 35
    score += Double(headingCount) * 20
    if matches(hints, pattern: Self.positivePattern) {
      score += 300
    }
    if matches(hints, pattern: Self.negativePattern) {
      score -= 500
    }
    score -= linkDensity * 900
    return score
  }

  private func readableText(from element: Element) throws -> String {
    let blocks = try element.select(Self.blockSelector).array()
    let textBlocks = try blocks.filter { block in
      !hasSelectedBlockAncestor(block, selectedBlocks: blocks)
    }.compactMap { block -> String? in
      let text = try block.text().trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
    let text = textBlocks.joined(separator: "\n\n")
    guard !text.isEmpty else {
      return WebTextExtractor.extractText(from: try element.text(), contentType: nil)
    }
    return WebTextExtractor.extractText(from: text, contentType: nil)
  }

  private func hasSelectedBlockAncestor(
    _ block: Element,
    selectedBlocks: [Element]
  ) -> Bool {
    var ancestor = block.parent()
    while let current = ancestor {
      if selectedBlocks.contains(where: { $0 === current }) {
        return true
      }
      ancestor = current.parent()
    }
    return false
  }

  private func matches(_ text: String, pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
}
