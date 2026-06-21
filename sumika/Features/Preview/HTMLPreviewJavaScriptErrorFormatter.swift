import Foundation

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
