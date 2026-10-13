import Foundation
import SumikaCore

/// The adapter owns the authenticated loopback endpoint and the task container.
struct HarborWorkspaceBackend: WorkspaceFileIO, CommandProcessRunning {
  let bridgeURL: URL
  let token: String
  private let session: URLSession

  init(bridgeURL: URL, token: String, session: URLSession = .shared) {
    self.bridgeURL = bridgeURL
    self.token = token
    self.session = session
  }

  func resolve(path: String, in _: Workspace) async throws -> WorkspaceFileLocation {
    let result: Location = try await call(Request(operation: "resolve", path: path))
    return WorkspaceFileLocation(
      absolutePath: result.absolutePath,
      relativePath: WorkspaceRelativePath(rawValue: result.relativePath),
      isRegularFile: result.isRegularFile)
  }

  func read(path: String, in _: Workspace, offset: Int, maxBytes: Int?) async throws -> Data {
    let result: Bytes = try await call(
      Request(operation: "read", path: path, offset: offset, maxBytes: maxBytes))
    guard let data = Data(base64Encoded: result.dataBase64) else {
      throw BridgeError.invalidResponse
    }
    return data
  }

  func withReader<Result: Sendable>(
    path: String, in _: Workspace,
    _ operation:
      @Sendable (@escaping @Sendable (Int, Int) async throws -> Data) async throws -> Result
  ) async throws -> Result {
    let initial: Bytes = try await call(
      Request(operation: "read", path: path, offset: 0, maxBytes: 0))
    return try await operation { offset, maxBytes in
      let result: Bytes = try await call(
        Request(
          operation: "read", path: path, offset: offset, maxBytes: maxBytes,
          expectedVersion: initial.version))
      guard result.version == initial.version else { throw WorkspaceFileIOError.contentChanged }
      guard let data = Data(base64Encoded: result.dataBase64) else {
        throw BridgeError.invalidResponse
      }
      return data
    }
  }

  func write(path: String, in _: Workspace, data: Data, expectedContents: Data?) async throws {
    let _: Empty = try await call(
      Request(
        operation: "write", path: path, dataBase64: data.base64EncodedString(),
        expectedContentsBase64: expectedContents?.base64EncodedString()))
  }

  func listDirectory(path: String, in _: Workspace) async throws -> [String] {
    let result: Names = try await call(Request(operation: "list", path: path))
    return result.names
  }

  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    let result: CommandResult = try await call(
      Request(
        operation: "run", executable: request.executableURL.path(percentEncoded: false),
        arguments: request.arguments, cwd: request.workingDirectoryURL.path(percentEncoded: false),
        timeoutSeconds: request.timeoutSeconds,
        standardInputBase64: request.standardInput?.base64EncodedString(),
        maxStdoutBytes: request.maxStdoutBytes, maxStderrBytes: request.maxStderrBytes,
        stdoutRetention: retention(request.stdoutRetention),
        stderrRetention: retention(request.stderrRetention)))
    guard let stdoutData = Data(base64Encoded: result.stdoutDataBase64) else {
      throw BridgeError.invalidResponse
    }
    return CommandProcessResult(
      exitCode: result.exitCode, durationMs: result.durationMs, stdout: result.stdout,
      stderr: result.stderr, stdoutData: stdoutData, timedOut: result.timedOut,
      cancelled: result.cancelled, stdoutTruncated: result.stdoutTruncated,
      stderrTruncated: result.stderrTruncated, stdoutOmittedBytes: result.stdoutOmittedBytes,
      stderrOmittedBytes: result.stderrOmittedBytes)
  }

  private func retention(_ value: ProcessOutputRetention) -> String {
    switch value {
    case .prefix: "prefix"
    case .headTail: "headTail"
    case .tail: "tail"
    }
  }

  private func call<Result: Decodable & Sendable>(_ request: Request) async throws -> Result {
    try await withTaskCancellationHandler {
      try await send(request)
    } onCancel: {
      Task {
        let _: Empty? = try? await send(Request(operation: "cancel", targetRequestID: request.id))
      }
    }
  }

  private func send<Result: Decodable & Sendable>(_ request: Request) async throws -> Result {
    var http = URLRequest(url: bridgeURL.appendingPathComponent("rpc"))
    http.httpMethod = "POST"
    http.timeoutInterval = Double(request.timeoutSeconds ?? 60) + 15
    http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.httpBody = try JSONEncoder().encode(request)
    let (data, response) = try await session.data(for: http)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw BridgeError.invalidResponse
    }
    let envelope = try JSONDecoder().decode(Response<Result>.self, from: data)
    guard envelope.id == request.id else { throw BridgeError.invalidResponse }
    if let error = envelope.error {
      switch error.code {
      case "notFound": throw CocoaError(.fileReadNoSuchFile)
      case "permissionDenied": throw CocoaError(.fileReadNoPermission)
      case "pathOutsideWorkspace": throw WorkspacePathResolutionError.pathOutsideWorkspace
      case "contentChanged": throw WorkspaceFileIOError.contentChanged
      default: throw error
      }
    }
    guard let result = envelope.result else { throw BridgeError.invalidResponse }
    return result
  }

  private struct Request: Encodable, Sendable {
    var id = UUID().uuidString
    var operation: String
    var path: String?
    var offset: Int?
    var maxBytes: Int?
    var expectedVersion: String?
    var dataBase64: String?
    var expectedContentsBase64: String?
    var executable: String?
    var arguments: [String]?
    var cwd: String?
    var timeoutSeconds: Int?
    var standardInputBase64: String?
    var maxStdoutBytes: Int?
    var maxStderrBytes: Int?
    var stdoutRetention: String?
    var stderrRetention: String?
    var targetRequestID: String?
  }

  private struct Response<Result: Decodable>: Decodable {
    let id: String
    let result: Result?
    let error: RemoteError?
  }

  private struct RemoteError: Decodable, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { "Harbor workspace: \(message)" }
  }

  private enum BridgeError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "Invalid response from the Harbor workspace bridge." }
  }

  private struct Empty: Decodable, Sendable {}
  private struct Location: Decodable, Sendable {
    let absolutePath: String
    let relativePath: String
    let isRegularFile: Bool
  }
  private struct Bytes: Decodable, Sendable {
    let dataBase64: String
    let version: String
  }
  private struct Names: Decodable, Sendable { let names: [String] }
  private struct CommandResult: Decodable, Sendable {
    let exitCode: Int32?
    let durationMs: Int
    let stdout: String
    let stderr: String
    let stdoutDataBase64: String
    let timedOut: Bool
    let cancelled: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let stdoutOmittedBytes: Int
    let stderrOmittedBytes: Int
  }
}
