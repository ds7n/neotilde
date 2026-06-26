// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Fn-layer state (function-keys spec). Caps-lock semantics plus context
/// auto-engage with a per-episode user override.
public enum FnMode: Equatable, Sendable { case off, armed, locked }

public struct FnState: Equatable, Sendable {
    public private(set) var mode: FnMode = .off
    /// The active pane is currently in an auto-Fn context (htop/top/mc).
    private var autoActive = false
    /// The user dismissed Fn during the current auto episode → don't re-lock.
    private var userOverride = false
    /// User just manually locked; don't set override on the next unlock.
    private var justManuallyLocked = false

    public init() {}

    /// True when F-keys should be shown (Armed or Locked).
    public var engaged: Bool { mode != .off }

    /// Single tap: off→armed, armed→locked, locked→off. Turning a locked Fn off
    /// while a context has it auto-engaged sets the per-episode override.
    public mutating func tap() {
        switch mode {
        case .off:    mode = .armed
        case .armed:  mode = .locked
        case .locked:
            mode = .off
            if autoActive && !justManuallyLocked { userOverride = true }
            justManuallyLocked = false
        }
    }

    /// Double tap: lock. A manual lock clears any standing override.
    public mutating func doubleTap() { mode = .locked; userOverride = false; justManuallyLocked = true }

    /// An F-key fired: clears a one-shot arm; a lock persists.
    public mutating func fireFKey() { if mode == .armed { mode = .off } }

    /// Context entered an auto-Fn process: lock unless the user overrode this episode.
    public mutating func autoEngage() {
        autoActive = true
        if !userOverride { mode = .locked }
    }

    /// Context left the auto-Fn process: end the episode and return to off.
    public mutating func autoDisengage() {
        autoActive = false
        userOverride = false
        justManuallyLocked = false
        mode = .off
    }

    /// Full reset (e.g. the focused pane changed): clears mode + episode state.
    public mutating func reset() { mode = .off; autoActive = false; userOverride = false; justManuallyLocked = false }
}
