import Foundation

/// App-owned executable and writable storage; resolved by the platform composition root.
package struct MCPRuntimeConfiguration: Sendable {
  let uvExecutableURL: URL
  let dataDirectoryURL: URL
  let cacheDirectoryURL: URL

  package init(uvExecutableURL: URL, dataDirectoryURL: URL, cacheDirectoryURL: URL) {
    self.uvExecutableURL = uvExecutableURL
    self.dataDirectoryURL = dataDirectoryURL
    self.cacheDirectoryURL = cacheDirectoryURL
  }

  func environment(inheriting base: [String: String]) -> [String: String] {
    var result = base
    // A shell's active interpreter and uv storage policy must not select a user's runtime.
    for key in [
      "VIRTUAL_ENV", "CONDA_PREFIX", "PYTHONHOME", "PYTHONPATH", "UV_PYTHON",
      "UV_PYTHON_PREFERENCE", "UV_NO_MANAGED_PYTHON", "UV_PROJECT_ENVIRONMENT",
      "UV_PYTHON_DOWNLOADS_JSON_URL", "UV_PYTHON_CACHE_DIR", "UV_PYTHON_SEARCH_PATH",
    ] {
      result[key] = nil
    }
    result["UV_MANAGED_PYTHON"] = "1"
    result["UV_PYTHON_DOWNLOADS"] = "automatic"
    result["UV_PYTHON_INSTALL_DIR"] = dataDirectoryURL.appending(path: "python").path
    result["UV_TOOL_DIR"] = dataDirectoryURL.appending(path: "tools").path
    result["UV_PYTHON_BIN_DIR"] = dataDirectoryURL.appending(path: "bin").path
    result["UV_TOOL_BIN_DIR"] = dataDirectoryURL.appending(path: "bin").path
    result["UV_PYTHON_INSTALL_BIN"] = "0"
    result["UV_CACHE_DIR"] = cacheDirectoryURL.path
    return result
  }
}

extension MCPServerConfig {
  package var usesBundledUV: Bool {
    guard case .stdio(let command, _, _) = transport else { return false }
    return command == "uv" || command == "uvx"
  }
}
