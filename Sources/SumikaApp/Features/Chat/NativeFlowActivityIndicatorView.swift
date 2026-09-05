import AppKit

// Shared activity mark for generation and reasoning. Animation stays within
// these layers so streaming updates do not restart the pulse or drive layout.
final class NativeFlowActivityIndicatorView: NSView {
  private let strokes = (0..<3).map { _ in CALayer() }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    configureLayers()

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(updateAnimation),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateStrokeColors),
      name: NSColor.systemColorsDidChangeNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let notifications = NotificationCenter.default
    notifications.removeObserver(
      self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    notifications.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    if let window {
      notifications.addObserver(
        self,
        selector: #selector(updateAnimation),
        name: NSWindow.didChangeOcclusionStateNotification,
        object: window
      )
      if let clipView = enclosingScrollView?.contentView {
        clipView.postsBoundsChangedNotifications = true
        notifications.addObserver(
          self,
          selector: #selector(updateAnimation),
          name: NSView.boundsDidChangeNotification,
          object: clipView
        )
      }
    }
    updateAnimation()
  }

  override func viewDidHide() {
    super.viewDidHide()
    updateAnimation()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateAnimation()
  }

  override func layout() {
    super.layout()
    updateAnimation()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateStrokeColors()
  }

  private func configureLayers() {
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityElement(false)
    wantsLayer = true
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 18),
      heightAnchor.constraint(equalToConstant: 18),
    ])

    var slant = CATransform3DIdentity
    slant.m21 = tan(14 * .pi / 180)
    layer?.sublayerTransform = slant
    for (index, stroke) in strokes.enumerated() {
      stroke.bounds = CGRect(x: 0, y: 0, width: 3, height: 13)
      stroke.position = CGPoint(x: 3 + index * 6, y: 9)
      stroke.cornerRadius = 1.5
      stroke.transform = CATransform3DMakeScale(1, [0.5, 1, 0.7][index], 1)
      layer?.addSublayer(stroke)
    }
    updateStrokeColors()
  }

  @objc private func updateStrokeColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for stroke in strokes {
        stroke.backgroundColor = NSColor.controlAccentColor.cgColor
      }
      CATransaction.commit()
    }
  }

  @objc private func updateAnimation() {
    let shouldAnimate =
      window?.occlusionState.contains(.visible) == true
      && !isHiddenOrHasHiddenAncestor && visibleRect.intersects(bounds)
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard shouldAnimate else {
      for stroke in strokes {
        stroke.removeAnimation(forKey: "flow")
      }
      return
    }
    guard strokes.first?.animation(forKey: "flow") == nil else {
      return
    }

    let scale = CAKeyframeAnimation(keyPath: "transform.scale.y")
    scale.values = [0.42, 1, 0.65, 0.42]
    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    opacity.values = [0.55, 1, 0.75, 0.55]
    for animation in [scale, opacity] {
      animation.keyTimes = [0, 0.45, 0.75, 1]
      animation.duration = 1.8
      animation.timingFunctions = Array(
        repeating: CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1),
        count: 3
      )
    }

    let now = CACurrentMediaTime()
    for (index, stroke) in strokes.enumerated() {
      let pulse = CAAnimationGroup()
      pulse.animations = [scale, opacity]
      pulse.duration = 1.8
      pulse.repeatCount = .infinity
      pulse.beginTime = stroke.convertTime(now, from: nil)
      pulse.timeOffset = [0, 1.2, 0.6][index]
      stroke.add(pulse, forKey: "flow")
    }
  }
}
