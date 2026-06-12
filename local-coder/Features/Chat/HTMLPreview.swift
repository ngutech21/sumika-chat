import LocalCoderCore
import SwiftUI
import WebKit

enum HTMLPreviewConsoleMessageLevel: String, Codable, Equatable, Sendable {
  case log
  case info
  case warn
  case error
  case debug

  var systemImage: String {
    switch self {
    case .log:
      "text.quote"
    case .info:
      "info.circle"
    case .warn:
      "exclamationmark.triangle"
    case .error:
      "xmark.octagon"
    case .debug:
      "ladybug"
    }
  }

  var tint: Color {
    switch self {
    case .log:
      .secondary
    case .info:
      .blue
    case .warn:
      .orange
    case .error:
      .red
    case .debug:
      .purple
    }
  }
}

struct HTMLPreviewConsoleEntry: Identifiable, Equatable, Sendable {
  let id = UUID()
  let level: HTMLPreviewConsoleMessageLevel
  let message: String
  let source: String?
  let line: Int?
  let column: Int?

  var detailText: String? {
    var parts: [String] = []
    if let source, !source.isEmpty {
      parts.append(source)
    }
    if let line {
      parts.append("line \(line)")
    }
    if let column {
      parts.append("column \(column)")
    }
    guard !parts.isEmpty else {
      return nil
    }
    return parts.joined(separator: ", ")
  }
}

private struct HTMLPreviewConsoleMessagePayload: Decodable {
  let level: String
  let message: String
  let source: String?
  let line: Int?
  let column: Int?
}

private enum HTMLPreviewConsoleBridgeScript {
  static let handlerName = "htmlPreviewConsole"

  static var userScript: WKUserScript {
    WKUserScript(
      source: """
        (() => {
          if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.\(handlerName)) {
            return;
          }

          const handler = window.webkit.messageHandlers.\(handlerName);

          const stringify = (value) => {
            if (typeof value === 'string') {
              return value;
            }

            if (value instanceof Error) {
              return value.stack || value.message || String(value);
            }

            try {
              return JSON.stringify(value);
            } catch (error) {
              return String(value);
            }
          };

          const emit = (level, args, source, line, column) => {
            try {
              handler.postMessage({
                level,
                message: Array.from(args, stringify).join(' '),
                source: source || null,
                line: typeof line === 'number' ? line : null,
                column: typeof column === 'number' ? column : null
              });
            } catch (error) {
            }
          };

          ['log', 'info', 'warn', 'error', 'debug'].forEach((level) => {
            const original = console[level];
            console[level] = (...args) => {
              emit(level, args);
              return original.apply(console, args);
            };
          });

          window.addEventListener('error', (event) => {
            emit('error', [event.message || 'Uncaught error'], event.filename, event.lineno, event.colno);
          });

          window.addEventListener('unhandledrejection', (event) => {
            emit('error', ['Unhandled promise rejection:', stringify(event.reason)]);
          });
        })();
        """,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: false
    )
  }
}

struct HTMLPreviewState: Equatable {
  let url: URL
  let readAccessRootURL: URL
  let relativePath: WorkspaceRelativePath

  var title: String {
    url.lastPathComponent
  }
}

enum HTMLPreviewResolutionError: LocalizedError, Equatable {
  case unsupportedFileType(String)
  case notAFile

  var errorDescription: String? {
    switch self {
    case .unsupportedFileType(let path):
      "Preview only supports HTML files: \(path)"
    case .notAFile:
      "Preview path is not a file."
    }
  }
}

struct HTMLPreviewResolver: Sendable {
  func resolve(path: String, in workspace: Workspace) throws -> HTMLPreviewState {
    try workspace.withSecurityScopedAccess {
      let resolvedURL = try workspace.resolveAllowedPath(path)
      let fileExtension = resolvedURL.pathExtension.lowercased()
      guard fileExtension == "html" || fileExtension == "htm" else {
        throw HTMLPreviewResolutionError.unsupportedFileType(path)
      }

      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: resolvedURL.path(percentEncoded: false),
          isDirectory: &isDirectory
        ), !isDirectory.boolValue
      else {
        throw HTMLPreviewResolutionError.notAFile
      }

      return HTMLPreviewState(
        url: resolvedURL,
        readAccessRootURL: workspace.rootURL,
        relativePath: workspace.relativePath(for: resolvedURL)
      )
    }
  }
}

struct HTMLPreviewPane: View {
  let preview: HTMLPreviewState
  let refreshID: UUID
  let browserToolService: HTMLPreviewBrowserToolService
  let consoleEntries: [HTMLPreviewConsoleEntry]
  let onConsoleMessage: @Sendable (HTMLPreviewConsoleEntry) -> Void
  let onRefresh: () -> Void
  let onClose: () -> Void
  @State private var isConsoleVisible = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(preview.title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(preview.relativePath.rawValue)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        Button {
          isConsoleVisible.toggle()
        } label: {
          Image(systemName: isConsoleVisible ? "terminal.fill" : "terminal")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(isConsoleVisible ? "Hide console" : "Show console")
        .accessibilityLabel(isConsoleVisible ? "Hide console" : "Show console")
        .accessibilityIdentifier("html-preview-console-toggle-button")

        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help("Refresh preview")
        .accessibilityLabel("Refresh preview")
        .accessibilityIdentifier("html-preview-refresh-button")

        Button(action: onClose) {
          Image(systemName: "xmark")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help("Hide preview")
        .accessibilityLabel("Hide preview")
        .accessibilityIdentifier("html-preview-close-button")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      Divider()

      HTMLPreviewWebView(
        preview: preview,
        refreshID: refreshID,
        browserToolService: browserToolService,
        onConsoleMessage: onConsoleMessage
      )
      .accessibilityIdentifier("html-preview-webview")

      if isConsoleVisible {
        Divider()

        HTMLPreviewConsolePanel(entries: consoleEntries)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .frame(minWidth: 360, idealWidth: 460)
    .background(.background)
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityIdentifier("html-preview-pane")
  }
}

struct HTMLPreviewWebView: NSViewRepresentable {
  let preview: HTMLPreviewState
  let refreshID: UUID
  let browserToolService: HTMLPreviewBrowserToolService
  let onConsoleMessage: @Sendable (HTMLPreviewConsoleEntry) -> Void

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.userContentController.addUserScript(HTMLPreviewConsoleBridgeScript.userScript)
    configuration.userContentController.add(
      context.coordinator, name: HTMLPreviewConsoleBridgeScript.handlerName)

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.setValue(false, forKey: "drawsBackground")
    webView.navigationDelegate = context.coordinator
    webView.setAccessibilityIdentifier("html-preview-webview")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.preview = preview
    context.coordinator.browserToolService = browserToolService
    context.coordinator.onConsoleMessage = onConsoleMessage
    context.coordinator.registerBrowserHandlers(for: webView)

    if context.coordinator.lastRefreshID != refreshID {
      context.coordinator.lastRefreshID = refreshID
      webView.reload()
      return
    }

    guard webView.url != preview.url else {
      return
    }
    webView.loadFileURL(preview.url, allowingReadAccessTo: preview.readAccessRootURL)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(preview: preview, refreshID: refreshID)
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    _ = webView
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: HTMLPreviewConsoleBridgeScript.handlerName
    )
    webView.configuration.userContentController.removeAllUserScripts()
    coordinator.unregisterBrowserHandlers()
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var preview: HTMLPreviewState
    var lastRefreshID: UUID
    var browserToolService: HTMLPreviewBrowserToolService?
    var onConsoleMessage: @Sendable (HTMLPreviewConsoleEntry) -> Void = { _ in }
    private let loadWaiter = HTMLPreviewLoadWaiter()

    init(preview: HTMLPreviewState, refreshID: UUID) {
      self.preview = preview
      self.lastRefreshID = refreshID
    }

    func registerBrowserHandlers(for webView: WKWebView) {
      let preview = self.preview
      let service = browserToolService
      Task {
        await service?.register(
          refreshHandler: { [weak webView, weak self] input in
            guard let webView, let self else {
              return .failed(
                reason: .executionError(UnavailableBrowserToolService.unavailableMessage))
            }
            return await self.refreshPreview(using: webView, preview: preview, input: input)
          },
          inspectHandler: { [weak webView, weak self] input in
            guard let webView, let self else {
              return .failed(
                reason: .executionError(UnavailableBrowserToolService.unavailableMessage))
            }
            return await self.inspectPreview(using: webView, preview: preview, input: input)
          }
        )
      }
    }

    func unregisterBrowserHandlers() {
      let service = browserToolService
      Task {
        await service?.clear()
      }
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      _ = userContentController
      guard message.name == HTMLPreviewConsoleBridgeScript.handlerName else {
        return
      }

      guard let payload = decodeConsolePayload(from: message.body) else {
        return
      }

      let level = HTMLPreviewConsoleMessageLevel(rawValue: payload.level) ?? .log
      let entry = HTMLPreviewConsoleEntry(
        level: level,
        message: payload.message,
        source: payload.source,
        line: payload.line,
        column: payload.column
      )
      Task { @MainActor in
        onConsoleMessage(entry)
      }
    }

    private func decodeConsolePayload(from body: Any) -> HTMLPreviewConsoleMessagePayload? {
      guard JSONSerialization.isValidJSONObject(body),
        let data = try? JSONSerialization.data(withJSONObject: body)
      else {
        return nil
      }
      return try? JSONDecoder().decode(HTMLPreviewConsoleMessagePayload.self, from: data)
    }

    @MainActor
    private func refreshPreview(
      using webView: WKWebView,
      preview: HTMLPreviewState,
      input: BrowserRefreshInput
    ) async -> BrowserRefreshResult {
      let hardReload = input.hard ?? false
      if hardReload || webView.url == nil {
        webView.loadFileURL(preview.url, allowingReadAccessTo: preview.readAccessRootURL)
      } else {
        webView.reload()
      }
      return .success(
        path: preview.relativePath,
        url: preview.url.absoluteString,
        hard: hardReload
      )
    }

    @MainActor
    private func inspectPreview(
      using webView: WKWebView,
      preview: HTMLPreviewState,
      input: BrowserInspectInput
    ) async -> BrowserInspectResult {
      if webView.isLoading {
        switch await loadWaiter.waitForLoadIfNeeded() {
        case .finished:
          break
        case .failed(let reason):
          return .failed(reason: .executionError(reason))
        case .timedOut(let reason):
          webView.stopLoading()
          return .failed(reason: .executionError(reason))
        }
      }

      guard webView.url != nil else {
        return .failed(
          reason: .executionError(UnavailableBrowserToolService.unavailableMessage))
      }

      do {
        let snapshot = try await evaluateInspection(on: webView, input: input)
        if let error = snapshot.error {
          return .failed(reason: .executionError(error))
        }

        let textOutput = truncate(snapshot.text ?? "", limit: input.resolvedMaxLength)
        let htmlOutput: ToolTextOutput? =
          if input.resolvedIncludeHTML {
            truncate(snapshot.html ?? "", limit: input.resolvedMaxLength)
          } else {
            nil
          }

        return .success(
          path: preview.relativePath,
          title: snapshot.title ?? "",
          url: snapshot.url ?? preview.url.absoluteString,
          selector: input.resolvedSelector,
          text: textOutput,
          html: htmlOutput
        )
      } catch {
        return .failed(reason: .executionError(HTMLPreviewJavaScriptErrorFormatter.describe(error)))
      }
    }

    @MainActor
    private func finishLoadWaiters(error: String?) {
      loadWaiter.finish(error: error)
    }

    @MainActor
    private func evaluateInspection(
      on webView: WKWebView,
      input: BrowserInspectInput
    ) async throws -> HTMLPreviewInspectionSnapshot {
      let selector = input.resolvedSelector
      let selectorLiteral = javascriptStringLiteral(selector)
      let includeHTMLLiteral = input.resolvedIncludeHTML ? "true" : "false"
      let script = """
        (() => {
          if (!document || !document.documentElement) {
            return { error: "No document is loaded in the preview yet." };
          }
          const selector = \(selectorLiteral);
          const includeHtml = \(includeHTMLLiteral);
          let element;
          try {
            element = selector ? document.querySelector(selector) : document.body;
          } catch (error) {
            return {
              error: `Invalid CSS selector ${selector}: ${error && error.message ? error.message : String(error)}`
            };
          }
          if (!element) {
            return { error: `No element matched selector: ${selector}` };
          }
          const textSource = selector ? element : (document.body || element);
          return {
            title: document.title || "",
            url: window.location.href || "",
            text: textSource.innerText || textSource.textContent || "",
            html: includeHtml ? (element.outerHTML || "") : null
          };
        })();
        """
      let json = try await webView.evaluateJavaScriptStringAsync("JSON.stringify(\(script))")
      guard let data = json.data(using: .utf8) else {
        throw HTMLPreviewInspectionError.invalidResultShape
      }
      return try JSONDecoder().decode(HTMLPreviewInspectionSnapshot.self, from: data)
    }

    @MainActor
    private func truncate(_ text: String, limit: Int) -> ToolTextOutput {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count > limit else {
        return ToolTextOutput(text: trimmed)
      }
      return ToolTextOutput(text: String(trimmed.prefix(limit)), truncated: true)
    }

    @MainActor
    private func javascriptStringLiteral(_ value: String?) -> String {
      guard let value else {
        return "null"
      }
      let escaped =
        value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
      return "\"\(escaped)\""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      _ = webView
      _ = navigation
      Task { @MainActor in
        finishLoadWaiters(error: nil)
      }
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation?,
      withError error: Error
    ) {
      _ = webView
      _ = navigation
      Task { @MainActor in
        finishLoadWaiters(error: "Preview failed to load: \(error.localizedDescription)")
      }
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation?,
      withError error: Error
    ) {
      _ = webView
      _ = navigation
      Task { @MainActor in
        finishLoadWaiters(error: "Preview failed to load: \(error.localizedDescription)")
      }
    }
  }
}

@MainActor
enum HTMLPreviewLoadWaitOutcome: Equatable {
  case finished
  case failed(String)
  case timedOut(String)
}

@MainActor
final class HTMLPreviewLoadWaiter {
  static let defaultTimeout: Duration = .seconds(30)
  static let timeoutMessage = "Preview did not finish loading within 30 seconds."

  private let timeout: Duration
  private var waiters: [UUID: CheckedContinuation<HTMLPreviewLoadWaitOutcome, Never>] = [:]
  private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

  init(timeout: Duration = defaultTimeout) {
    self.timeout = timeout
  }

  func waitForLoadIfNeeded() async -> HTMLPreviewLoadWaitOutcome {
    let id = UUID()
    let timeout = self.timeout
    return await withCheckedContinuation { continuation in
      waiters[id] = continuation
      timeoutTasks[id] = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        self?.completeWaiter(id, with: .timedOut(Self.timeoutMessage))
      }
    }
  }

  func finish(error: String?) {
    completeAll(with: error.map(HTMLPreviewLoadWaitOutcome.failed) ?? .finished)
  }

  private func completeWaiter(_ id: UUID, with outcome: HTMLPreviewLoadWaitOutcome) {
    guard let waiter = waiters.removeValue(forKey: id) else {
      return
    }
    timeoutTasks.removeValue(forKey: id)?.cancel()
    waiter.resume(returning: outcome)
  }

  private func completeAll(with outcome: HTMLPreviewLoadWaitOutcome) {
    let waiters = self.waiters
    let timeoutTasks = self.timeoutTasks
    self.waiters.removeAll()
    self.timeoutTasks.removeAll()
    for timeoutTask in timeoutTasks.values {
      timeoutTask.cancel()
    }
    for waiter in waiters.values {
      waiter.resume(returning: outcome)
    }
  }
}

private struct HTMLPreviewConsolePanel: View {
  let entries: [HTMLPreviewConsoleEntry]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label("Console", systemImage: "terminal")
          .font(.caption.weight(.semibold))

        Spacer()

        Text("\(entries.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
              Text("No console output yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
              ForEach(entries) { entry in
                HTMLPreviewConsoleEntryRow(entry: entry)
                  .id(entry.id)
              }
            }
          }
          .padding(.vertical, 10)
        }
        .onChange(of: entries.count) {
          guard let lastEntry = entries.last else {
            return
          }
          proxy.scrollTo(lastEntry.id, anchor: .bottom)
        }
      }
    }
    .frame(height: 180)
    .background(Color(nsColor: .controlBackgroundColor))
    .accessibilityIdentifier("html-preview-console-panel")
  }
}

private struct HTMLPreviewConsoleEntryRow: View {
  let entry: HTMLPreviewConsoleEntry

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: entry.level.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(entry.level.tint)
        .frame(width: 14)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.message)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        if let detailText = entry.detailText {
          Text(detailText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
  }
}

private struct HTMLPreviewInspectionSnapshot {
  var title: String?
  var url: String?
  var text: String?
  var html: String?
  var error: String?
}

extension HTMLPreviewInspectionSnapshot: Decodable {}

private enum HTMLPreviewInspectionError: LocalizedError {
  case invalidResultShape

  var errorDescription: String? {
    switch self {
    case .invalidResultShape:
      "Preview inspection returned an unexpected result."
    }
  }
}

enum HTMLPreviewJavaScriptErrorFormatter {
  static func describe(_ error: Error) -> String {
    let nsError = error as NSError
    var parts: [String] = []

    if let message = stringValue(for: "WKJavaScriptExceptionMessage", in: nsError.userInfo) {
      parts.append("JavaScript exception: \(message)")
    } else {
      parts.append(nsError.localizedDescription)
    }

    if let sourceURL = stringValue(for: "WKJavaScriptExceptionSourceURL", in: nsError.userInfo) {
      parts.append("Source: \(sourceURL)")
    }

    let line = numberValue(for: "WKJavaScriptExceptionLineNumber", in: nsError.userInfo)
    let column = numberValue(for: "WKJavaScriptExceptionColumnNumber", in: nsError.userInfo)
    if let line, let column {
      parts.append("Location: line \(line), column \(column)")
    } else if let line {
      parts.append("Location: line \(line)")
    } else if let column {
      parts.append("Location: column \(column)")
    }

    return parts.joined(separator: "\n")
  }

  private static func stringValue(for key: String, in userInfo: [String: Any]) -> String? {
    guard let value = userInfo[key] else {
      return nil
    }
    if let string = value as? String, !string.isEmpty {
      return string
    }
    if let url = value as? URL {
      return url.absoluteString
    }
    return nil
  }

  private static func numberValue(for key: String, in userInfo: [String: Any]) -> Int? {
    guard let value = userInfo[key] else {
      return nil
    }
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = value as? String, let number = Int(string) {
      return number
    }
    return nil
  }
}

extension WKWebView {
  @MainActor
  fileprivate func evaluateJavaScriptStringAsync(_ script: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let stringValue = value as? String else {
          continuation.resume(throwing: HTMLPreviewInspectionError.invalidResultShape)
          return
        }
        continuation.resume(returning: stringValue)
      }
    }
  }
}
