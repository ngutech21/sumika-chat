enum ToolLineRendering {
  static let lineFormat = "N: content"

  static func prefix(for lineNumber: Int) -> String {
    "\(lineNumber): "
  }
}
