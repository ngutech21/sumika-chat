import Foundation

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
