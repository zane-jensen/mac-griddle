import AppKit
import MacGriddleCore

/// One borderless, click-through overlay window covering exactly one
/// `NSScreen`. Owned and recreated by `GridOverlayController` (see
/// GridOverlayController.swift) — never instantiated directly by `Input`
/// or anything outside this target.
///
/// See docs/architecture/chunks/overlay-rendering.md §1.
final class OverlayWindow: NSWindow {

    /// The view that actually draws grid lines + the selection highlight.
    /// Always non-nil by the time any caller can observe an `OverlayWindow`
    /// instance — set by `make(for:)` immediately after construction, never
    /// during `init` itself. See the doc comment on `make(for:)` for why.
    private(set) var overlayContentView: GridOverlayContentView!

    // Never let this window take key/main status. This is as important as
    // `ignoresMouseEvents` for not disturbing whatever app the user is
    // mid-drag on.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The only supported way to construct an `OverlayWindow`.
    ///
    /// This deliberately does NOT override either of `NSWindow`'s two
    /// designated initializers. Confirmed via a real crash
    /// ("Thread stack size exceeded due to excessive recursion"): AppKit's
    /// own base implementations of `init(contentRect:styleMask:backing:defer:)`
    /// and `init(contentRect:styleMask:backing:defer:screen:)` dynamically
    /// call back into *each other* on `self` as part of their own setup. If
    /// a subclass overrides one of them and that override calls
    /// `super.init` targeting the *other* arity (as a previous version of
    /// this file did, to resolve per-screen defaults), AppKit's internal
    /// cross-call re-enters the override, which calls `super.init` again,
    /// which gets cross-called again — infinitely, until the stack
    /// overflows. This reproduced reliably on every Option-hold gesture.
    ///
    /// Since `OverlayWindow` defines no custom designated initializer at
    /// all (all its own stored properties have implicit `nil`/default
    /// values), Swift automatically inherits `NSWindow`'s initializers
    /// unchanged — no override, no cross-call, no recursion. All
    /// per-screen setup happens here, as a plain method call *after*
    /// construction has already fully completed.
    static func make(for screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let contentView = GridOverlayContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.overlayContentView = contentView
        window.configureWindow(for: screen)
        window.contentView = contentView

        return window
    }

    private func configureWindow(for screen: NSScreen) {
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isRestorable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    /// This window's frame converted to Quartz/global-display space
    /// (top-left origin, Y-down) — the same space `GridEngine` and `Input`
    /// operate in end to end, per the coordinate discipline fixed in
    /// `docs/architecture/overview.md`. Uses `ScreenSpace` from
    /// `MacGriddleCore` (see core-contracts.md §6).
    var quartzFrame: CGRect {
        ScreenSpace.flippedRect(frame, primaryScreenHeight: ScreenSpace.primaryScreenHeight())
    }

    var quartzOrigin: CGPoint { quartzFrame.origin }
}
