import SwiftUI

extension View {
  /// Applies a floating panel surface: Liquid Glass on macOS 26+, falling back
  /// to a material fill with a hairline border on macOS 15–25.
  ///
  /// Use only for surfaces that float above content (composer, popovers, plan
  /// panels) — never for inline content such as message bubbles or code blocks.
  @ViewBuilder
  func glassPanel(cornerRadius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: shape)
    } else {
      background(.regularMaterial, in: shape)
        .overlay {
          shape.strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
  }
}
