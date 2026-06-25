// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import NeotildeKit

/// Renders a pulsed border-glow overlay for the visual bell. Place as a
/// full-frame subview over the terminal/pane view; it is transparent when idle.
///
/// Drive pattern:
/// 1. Call `configure(color:)` once at setup (or when the theme changes).
/// 2. On each `bell()` delegate call: update your `BellStateMachine`, then call
///    `start(machine:)` — this arms/restarts the `CADisplayLink`.
/// 3. The display link self-terminates when `intensity` reaches 0.
///
/// The view draws an inset border using `CALayer.borderColor` + `CALayer.borderWidth`.
/// `alpha` is applied on top so the glow fades smoothly without re-rendering the
/// layer border geometry each frame.
///
/// UIKit/macOS assumption: `CADisplayLink` is available in UIKit (iOS 3.1+);
/// `layer.borderColor` / `layer.borderWidth` are standard `CALayer` properties.
/// This file cannot be compiled on Linux — macOS CI validates it.
final class BellHaloView: UIView {
    // MARK: - Configuration

    /// Halo border inset from the view edges (points).
    private static let borderInset: CGFloat = 2
    private static let borderWidth: CGFloat = 3

    private var machine: BellStateMachine = BellStateMachine()
    private var displayLink: CADisplayLink?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false   // pass-through; never intercepts touches
        backgroundColor = .clear
        alpha = 0
        layer.borderWidth = Self.borderWidth
        layer.borderColor = UIColor.clear.cgColor
    }

    // MARK: - API

    /// Set the halo border color from the active theme.
    ///
    /// - Parameter color: Resolved `UIColor` from `theme.bell.edge`.
    func configure(color: UIColor) {
        layer.borderColor = color.cgColor
    }

    /// Register a new bell ring and arm (or re-arm) the display link.
    ///
    /// - Parameter machine: The updated `BellStateMachine` after calling `ring(at:)`.
    func start(machine: BellStateMachine) {
        self.machine = machine
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        // Snap to peak immediately so the first frame is visible.
        alpha = 1
    }

    // MARK: - Display link

    @objc private func tick() {
        let i = machine.intensity(at: Date())
        alpha = CGFloat(i)
        if i == 0 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}
