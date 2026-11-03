import AppKit
import SwiftUI
import Testing

@testable import SumikaApp

@MainActor
struct SkillPreviewLayoutTests {
  @Test(arguments: [CGFloat?.none, .some(.infinity), .some(.nan)])
  func unboundedProposalsPreserveNativeGeometry(width: CGFloat?) {
    let view = NativeSkillMarkdownBlocksView()
    view.update(markdown: "# Review\n\nInspect the diff.")
    view.setFrameSize(NSSize(width: 460, height: 120))
    let previousFrame = view.frame

    let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))

    #expect(size == nil)
    #expect(view.frame == previousFrame)
  }

  @Test
  func finiteProposalsMeasureWrappedMarkdown() throws {
    let view = NativeSkillMarkdownBlocksView()
    view.update(markdown: String(repeating: "Inspect the diff and check the result. ", count: 20))

    let narrowSize = try #require(
      view.sizeThatFits(ProposedViewSize(width: 240, height: nil))
    )
    let wideSize = try #require(
      view.sizeThatFits(ProposedViewSize(width: 460, height: nil))
    )

    #expect(narrowSize.width == 240)
    #expect(wideSize.width == 460)
    #expect(narrowSize.height.isFinite)
    #expect(wideSize.height > 0)
    #expect(narrowSize.height > wideSize.height)
  }
}
