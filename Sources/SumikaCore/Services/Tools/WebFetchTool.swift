import Foundation

public struct WebFetchToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<WebFetchInput>(
    definition: ToolDefinition.webFetch,
    makePayload: ToolCallPayload.webFetch,
    extractInput: { payload in
      guard case .webFetch(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.webFetch.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.requireNonEmptyString(
        input.url,
        name: "url",
        expected: "a non-empty public http or https URL"
      )
    }
  )

  private let urlValidator = WebURLValidator()

  public init() {}

  public func evaluatePermission(
    _ input: WebFetchInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    guard let url = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: WebAccessError.invalidURL(input.url).localizedDescription,
        riskLevel: .high
      )
    }
    if let error = urlValidator.validatePublicHTTPURL(url) {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .high
      )
    }
    return webPermissionEvaluation(context.webAccessSettings)
  }

  public func previewApproval(
    _ input: WebFetchInput,
    context: ToolContext
  ) async -> ToolResultPreview? {
    ToolResultPreview(
      text: """
        Web fetch requires approval.
        URL: \(input.url)
        Max bytes: \(WebAccessLimits.cappedFetchBytes(input.maxBytes))
        """
    )
  }

  public func run(_ input: WebFetchInput, context: ToolContext) async -> ToolResultPayload {
    guard context.webAccessSettings.policy != .off else {
      return .webFetch(.failed(url: input.url, finalURL: nil, reason: .permissionDenied))
    }
    guard let url = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return .webFetch(
        .failed(
          url: input.url,
          finalURL: nil,
          reason: .invalidArguments(
            .parserError(WebAccessError.invalidURL(input.url).localizedDescription))
        )
      )
    }
    let result = await context.webFetcher.fetch(
      WebFetchRequest(
        url: url,
        maxBytes: WebAccessLimits.cappedFetchBytes(input.maxBytes)
      )
    )
    return .webFetch(result)
  }
}

func webPermissionEvaluation(
  _ settings: WebAccessSettings
) -> ToolPermissionEvaluation {
  switch settings.policy {
  case .off:
    return ToolPermissionEvaluation(
      decision: .denied,
      reason: "Web access is disabled.",
      riskLevel: .high
    )
  case .askEachTime:
    return ToolPermissionEvaluation(
      decision: .requiresApproval,
      reason: "Web access requires approval.",
      riskLevel: .high
    )
  case .allow:
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Web access is allowed.",
      riskLevel: .high
    )
  }
}
