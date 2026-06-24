import Foundation
import SumikaCore
import SwiftUI
import WebKit

private struct HTMLPreviewConsoleMessagePayload: Decodable {
  let level: String
  let message: String
  let source: String?
  let line: Int?
  let column: Int?
}

private struct BrowserHandlerRegistrationKey: Equatable {
  let webViewID: ObjectIdentifier
  let serviceID: ObjectIdentifier
  let preview: HTMLPreviewState

  init(
    webView: WKWebView,
    service: HTMLPreviewBrowserToolService,
    preview: HTMLPreviewState
  ) {
    self.webViewID = ObjectIdentifier(webView)
    self.serviceID = ObjectIdentifier(service)
    self.preview = preview
  }

  static func == (lhs: BrowserHandlerRegistrationKey, rhs: BrowserHandlerRegistrationKey)
    -> Bool
  {
    lhs.webViewID == rhs.webViewID
      && lhs.serviceID == rhs.serviceID
      && lhs.preview == rhs.preview
  }
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
    private var registeredBrowserHandlerKey: BrowserHandlerRegistrationKey?

    init(preview: HTMLPreviewState, refreshID: UUID) {
      self.preview = preview
      self.lastRefreshID = refreshID
    }

    func registerBrowserHandlers(for webView: WKWebView) {
      guard let browserToolService else {
        registeredBrowserHandlerKey = nil
        return
      }

      let preview = self.preview
      let registrationKey = BrowserHandlerRegistrationKey(
        webView: webView,
        service: browserToolService,
        preview: preview
      )
      guard registeredBrowserHandlerKey != registrationKey else {
        return
      }
      registeredBrowserHandlerKey = registrationKey

      Task {
        await browserToolService.register(
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
      registeredBrowserHandlerKey = nil
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
