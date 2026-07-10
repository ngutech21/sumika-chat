public struct WebSearchInput: Codable, Equatable, Sendable {
  public var query: String
  public var maxResults: Int?

  public init(query: String, maxResults: Int? = nil) {
    self.query = query
    self.maxResults = maxResults
  }
}

public struct WebSearchResult: Codable, Equatable, Sendable {
  public var title: String
  public var url: String
  public var snippet: String?

  public init(title: String, url: String, snippet: String? = nil) {
    self.title = title
    self.url = url
    self.snippet = snippet
  }
}

public enum WebSearchToolResult: Codable, Equatable, Sendable {
  case success(
    query: String, provider: WebSearchProvider, results: [WebSearchResult], truncated: Bool)
  case failed(query: String, reason: ToolFailureReason)

  public init(
    query: String,
    provider: WebSearchProvider,
    results: [WebSearchResult],
    truncated: Bool = false
  ) {
    self = .success(query: query, provider: provider, results: results, truncated: truncated)
  }
}

nonisolated extension WebSearchToolResult {
  var preview: ToolResultPreview {
    switch self {
    case .success(let query, let provider, let results, let truncated):
      let resultText =
        results.isEmpty
        ? "(no results)"
        : results.enumerated().map { index, result in
          let snippet = result.snippet.map { "\n\($0)" } ?? ""
          return "\(index + 1). \(result.title)\n\(result.url)\(snippet)"
        }.joined(separator: "\n\n")
      return ToolResultPreview(
        text: "Search provider: \(provider.displayName)\nQuery: \(query)\n\n\(resultText)",
        truncated: truncated
      )
    case .failed(_, let reason):
      return ToolResultPreview(status: reason.previewStatus, text: reason.message)
    }
  }
}

nonisolated extension ToolDefinition {
  public static let webSearch = ToolDefinition(
    name: .webSearch,
    description: "Search public web pages without sending workspace contents.",
    parameters: [
      ToolParameterDefinition(
        name: "query",
        description:
          "Public web search query. Do not include private source code, secrets, or full logs.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "maxResults",
        description: "Maximum result count.",
        isRequired: false,
        valueType: .integer,
        minimum: 1,
        maximum: Double(WebAccessLimits.maxSearchResultCount)
      ),
    ],
    capabilities: [.accessWeb],
    riskLevel: .high
  )
}

public struct WebSearchToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<WebSearchInput>(
    definition: ToolDefinition.webSearch,
    makePayload: ToolCallPayload.webSearch,
    extractInput: { payload in
      guard case .webSearch(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.webSearch.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.requireNonEmptyString(
        input.query,
        name: "query",
        expected: "a non-empty public web search query"
      )
    }
  )

  public init() {}

  public func evaluatePermission(
    _ input: WebSearchInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    return webPermissionEvaluation(context.webAccessSettings)
  }

  public func previewApproval(
    _ input: WebSearchInput,
    context: ToolContext
  ) async -> ToolResultPreview? {
    let (query, queryTruncated) = WebAccessLimits.cappedQuery(input.query)
    guard !query.isEmpty else {
      return ToolResultPreview(status: .failed, text: "Search query is empty.")
    }
    let truncatedText = queryTruncated ? "\nQuery was capped before it would be sent." : ""
    return ToolResultPreview(
      text: """
        Web search requires approval.
        Provider: \(context.webAccessSettings.provider.displayName)
        Query: \(query)
        Max results: \(WebAccessLimits.cappedResultCount(input.maxResults))\(truncatedText)
        """
    )
  }

  public func run(_ input: WebSearchInput, context: ToolContext) async -> ToolResultPayload {
    guard context.webAccessSettings.policy != .off else {
      return .webSearch(.failed(query: input.query, reason: .permissionDenied))
    }
    let maxResults = WebAccessLimits.cappedResultCount(input.maxResults)
    let result = await context.webSearcher.search(
      WebSearchRequest(
        query: input.query,
        maxResults: maxResults,
        settings: context.webAccessSettings
      )
    )
    return .webSearch(result)
  }
}
