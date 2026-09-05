import AppKit
import Testing

@testable import SumikaApp

@MainActor
struct NativeGenerationIndicatorViewTests {
  @Test
  func generationAnimationSurvivesUpdatesAndStopsWhenNotVisible() throws {
    let window = GenerationIndicatorTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = try #require(window.contentView)
    let indicator = NativeGenerationIndicatorView(title: "Generating")
    host.addSubview(indicator)
    indicator.setFrameSize(indicator.fittingSize)
    indicator.layoutSubtreeIfNeeded()
    let strokes = try strokeLayers(in: indicator)
    expectAnimation(strokes, visible: true)
    let startTimes = strokes.map { $0.animation(forKey: "flow")?.beginTime }

    indicator.update(title: "Generating")
    indicator.needsLayout = true
    indicator.layoutSubtreeIfNeeded()
    #expect(strokes.map { $0.animation(forKey: "flow")?.beginTime } == startTimes)

    host.isHidden = true
    expectAnimation(strokes, visible: false)
    host.isHidden = false
    expectAnimation(strokes, visible: true)

    window.simulatedOcclusionState = []
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    expectAnimation(strokes, visible: false)
    window.simulatedOcclusionState = [.visible]
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    expectAnimation(strokes, visible: true)

    indicator.removeFromSuperview()
    expectAnimation(strokes, visible: false)
    host.addSubview(indicator)
    indicator.layoutSubtreeIfNeeded()
    expectAnimation(strokes, visible: true)
  }

  @Test
  func generationAnimationStopsOutsideTheTranscriptViewport() throws {
    let window = GenerationIndicatorTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    scrollView.documentView = document
    window.contentView = scrollView
    let indicator = NativeGenerationIndicatorView(title: "Generating")
    document.addSubview(indicator)
    indicator.setFrameSize(indicator.fittingSize)
    scrollView.layoutSubtreeIfNeeded()
    let strokes = try strokeLayers(in: indicator)
    expectAnimation(strokes, visible: true)

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 150))
    #expect(!indicator.visibleRect.intersects(indicator.bounds))
    expectAnimation(strokes, visible: false)

    scrollView.contentView.scroll(to: .zero)
    #expect(indicator.visibleRect.intersects(indicator.bounds))
    expectAnimation(strokes, visible: true)
  }

  private func strokeLayers(in indicator: NativeGenerationIndicatorView) throws -> [CALayer] {
    let mark = try #require(indicator.arrangedSubviews.first)
    let strokes = try #require(mark.layer?.sublayers)
    #expect(strokes.count == 3)
    return strokes
  }

  private func expectAnimation(_ strokes: [CALayer], visible: Bool) {
    let shouldAnimate = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for stroke in strokes {
      #expect((stroke.animation(forKey: "flow") != nil) == shouldAnimate)
    }
  }
}

@MainActor
private final class GenerationIndicatorTestWindow: NSWindow {
  var simulatedOcclusionState: NSWindow.OcclusionState = [.visible]

  override var occlusionState: NSWindow.OcclusionState {
    simulatedOcclusionState
  }
}
