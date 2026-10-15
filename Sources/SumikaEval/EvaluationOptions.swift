import Foundation
import SumikaCore

struct EvaluationOptions: Sendable {
  let modelID: String
  let workspaceRoot: URL
  let bridgeURL: URL
  let bridgeToken: String
  let promptFile: URL
  let outputDirectory: URL
  let timeoutSeconds: Double
  let networkPolicy: EvaluationNetworkPolicy
  let reasoningLevel: ReasoningEffort?

  static let usage = """
    Usage: SumikaEval --model-id ID --workspace-root /container/workspace \
    --bridge-url http://127.0.0.1:PORT --prompt-file /host/prompt.txt \
    --output-dir /host/artifacts [--timeout-seconds 600] [--network-policy JSON]
    [--reasoning-level low|medium|xhigh]
    Omit --reasoning-level to use the selected model's default.
    Set SUMIKA_HARBOR_TOKEN to the bridge's per-trial authentication token.
    """

  init(arguments: [String], environment: [String: String]) throws {
    let accepted = Set([
      "--model-id", "--workspace-root", "--bridge-url", "--prompt-file",
      "--output-dir", "--timeout-seconds",
      "--network-policy", "--reasoning-level",
    ])
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard accepted.contains(key), values[key] == nil,
        index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--")
      else {
        throw EvaluationError("Unknown, duplicate, or incomplete argument: \(key)")
      }
      values[key] = arguments[index + 1]
      index += 2
    }
    func required(_ key: String) throws -> String {
      guard let value = values[key], !value.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw EvaluationError("Missing \(key)")
      }
      return value
    }
    func absoluteFileURL(_ key: String) throws -> URL {
      let path = try required(key)
      guard path.hasPrefix("/"), !path.contains("\0") else {
        throw EvaluationError("\(key) must be an absolute path")
      }
      return URL(filePath: path).standardizedFileURL
    }
    modelID = try required("--model-id")
    if let value = values["--reasoning-level"] {
      guard let level = ReasoningEffort(rawValue: value) else {
        throw EvaluationError("--reasoning-level must be low, medium, or xhigh")
      }
      reasoningLevel = level
    } else {
      reasoningLevel = nil
    }
    workspaceRoot = try absoluteFileURL("--workspace-root")
    promptFile = try absoluteFileURL("--prompt-file")
    outputDirectory = try absoluteFileURL("--output-dir")
    let rawBridgeURL = try required("--bridge-url")
    guard let url = URL(string: rawBridgeURL), url.scheme == "http",
      url.host == "127.0.0.1", let port = url.port, (1...65_535).contains(port),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/"
    else {
      throw EvaluationError("--bridge-url must be http://127.0.0.1:PORT")
    }
    bridgeURL = url
    guard let token = environment["SUMIKA_HARBOR_TOKEN"], !token.isEmpty,
      !token.contains("\n"), !token.contains("\r")
    else {
      throw EvaluationError("SUMIKA_HARBOR_TOKEN must contain the per-trial bridge token")
    }
    bridgeToken = token
    guard let timeout = Double(values["--timeout-seconds"] ?? "600"), timeout.isFinite,
      timeout > 0, timeout <= 86_400
    else {
      throw EvaluationError("--timeout-seconds must be between 0 and 86400")
    }
    timeoutSeconds = timeout
    networkPolicy = try JSONDecoder().decode(
      EvaluationNetworkPolicy.self,
      from: Data((values["--network-policy"] ?? "{\"network_mode\":\"no-network\"}").utf8))
  }
}

struct EvaluationNetworkPolicy: Codable, Sendable {
  enum Mode: String, Codable, Sendable {
    case publicNetwork = "public"
    case noNetwork = "no-network"
    case allowlist
  }

  let networkMode: Mode
  let allowedHosts: [String]?

  var webEnabled: Bool {
    networkMode == .publicNetwork || (networkMode == .allowlist && !(allowedHosts ?? []).isEmpty)
  }

  private enum CodingKeys: String, CodingKey {
    case networkMode = "network_mode"
    case allowedHosts = "allowed_hosts"
  }
}

struct EvaluationError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}
