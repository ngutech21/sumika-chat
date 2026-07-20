import Foundation

public struct WebFetchInput: Codable, Equatable, Sendable {
  public var url: String
  public var maxBytes: Int?

  public init(url: String, maxBytes: Int? = nil) {
    self.url = url
    self.maxBytes = maxBytes
  }
}

public enum WebFetchToolResult: Codable, Equatable, Sendable {
  case success(
    url: String,
    provider: WebFetchProvider?,
    finalURL: String,
    statusCode: Int,
    contentType: String?,
    content: ToolTextOutput,
    byteCount: Int
  )
  case failed(
    url: String,
    provider: WebFetchProvider?,
    finalURL: String?,
    reason: ToolFailureReason
  )

  public init(
    url: String,
    provider: WebFetchProvider?,
    finalURL: String,
    statusCode: Int,
    contentType: String?,
    content: ToolTextOutput,
    byteCount: Int
  ) {
    self = .success(
      url: url,
      provider: provider,
      finalURL: finalURL,
      statusCode: statusCode,
      contentType: contentType,
      content: content,
      byteCount: byteCount
    )
  }
}

nonisolated extension WebFetchToolResult {
  var preview: ToolResultPreview {
    switch self {
    case .success(
      let url, let provider, let finalURL, let statusCode, let contentType, let content,
      let byteCount):
      let redirectText = url == finalURL ? "" : "\nFinal URL: \(finalURL)"
      return ToolResultPreview(
        text: """
          URL: \(url)\(redirectText)
          Fetch provider: \(providerDisplayName(provider))
          Status: \(statusCode)
          Content-Type: \(contentType ?? "unknown")
          Bytes: \(byteCount)

          \(content.text)
          """,
        truncated: content.truncated,
        redacted: content.redacted
      )
    case .failed(let url, let provider, let finalURL, let reason):
      let finalURLText = finalURL.map { "\nFinal URL: \($0)" } ?? ""
      return ToolResultPreview(
        status: reason.previewStatus,
        text: """
          URL: \(url)\(finalURLText)
          Fetch provider: \(providerDisplayName(provider))
          \(reason.message)
          """
      )
    }
  }

  private func providerDisplayName(_ provider: WebFetchProvider?) -> String {
    provider?.displayName ?? "Unknown"
  }
}

nonisolated extension ToolDefinition {
  public static let webFetch = ToolDefinition(
    name: .webFetch,
    description: "Fetch public text content from an http or https URL.",
    parameters: [
      ToolParameterDefinition(
        name: "url",
        description:
          "Public http or https URL. Local, private, file, and internal network URLs are blocked.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "maxBytes",
        description: "Maximum response bytes to read.",
        isRequired: false,
        valueType: .integer,
        minimum: 1,
        maximum: Double(WebAccessLimits.maxFetchBytes)
      ),
    ],
    capabilities: [.accessWeb],
    riskLevel: .high
  )
}

struct WebFetchToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<WebFetchInput>(
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

  init() {}

  func evaluatePermission(
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

  func previewApproval(
    _ input: WebFetchInput,
    context: ToolContext
  ) async -> ToolResultPreview? {
    ToolResultPreview(
      text: """
        Web fetch requires approval.
        Provider: \(context.webAccessSettings.fetchProvider.displayName)
        URL: \(input.url)
        Max bytes: \(WebAccessLimits.cappedFetchBytes(input.maxBytes))
        """
    )
  }

  func run(_ input: WebFetchInput, context: ToolContext) async -> ToolResultPayload {
    guard context.webAccessSettings.policy != .off else {
      return .webFetch(
        .failed(
          url: input.url,
          provider: context.webAccessSettings.fetchProvider,
          finalURL: nil,
          reason: .permissionDenied
        ))
    }
    guard let url = URL(string: input.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return .webFetch(
        .failed(
          url: input.url,
          provider: context.webAccessSettings.fetchProvider,
          finalURL: nil,
          reason: .invalidArguments(
            .parserError(WebAccessError.invalidURL(input.url).localizedDescription))
        )
      )
    }
    let result = await context.webFetcher.fetch(
      WebFetchRequest(
        url: url,
        maxBytes: WebAccessLimits.cappedFetchBytes(input.maxBytes),
        settings: context.webAccessSettings
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
