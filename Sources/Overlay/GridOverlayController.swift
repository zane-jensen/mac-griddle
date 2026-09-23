import AppKit
import MacGriddleCore
import GridEngine

/// Not an `NSWindowController` subclass on purpose — that type models a
/// single window, and this one intentionally owns N of them (one per
/// connected screen), rebuilt on every `show()`. Constructed once by the
/// composition root and lives for the app's whole run.
///
/// Deliberately **not** `@MainActor`, despite constructing `NSWindow`s —
/// this was tried during a code-review rework pass and reverted after it
/// caused a real crash. `Input` calls into this type synchronously from
/// the `CGEventTap` C callback, which runs on the physical main thread but
/// is invoked directly by CoreFoundation, bypassing GCD entirely — Swift's
/// concurrency runtime does not recognize that context as "on MainActor"
/// even though it is on the main thread. Marking this class `@MainActor`
/// (with `@preconcurrency` conformance to silence the resulting compile
/// warning) inserts a runtime isolation check at every call, which crashed
/// with "Fatal error: Incorrect actor executor assumption" the first time
/// a gesture reached `show(configuration:state:)` from that callback (i.e.
/// every time). Every call into this type happens to run on the main
/// thread in practice (verified by the same review that first suggested
/// this annotation), which is sufficient for AppKit's own thread-safety
/// requirements — it just isn't something Swift's actor system can verify
/// given how the CGEventTap callback is invoked. See docs/REVIEW.md's
/// rework-pass addendum for the fix history.
///
/// See docs/architecture/chunks/overlay-rendering.md §2 and §4.
public final class GridOverlayController: GridOverlayRendering {
    private var overlayWindows: [OverlayWindow] = []
    private var appearance: OverlayAppearance
    private var isVisible = false
    private var lastConfiguration: GridConfiguration?
    private var lastState: GestureState?

    public init(appearance: OverlayAppearance) {
        self.appearance = appearance
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenParametersDidChange()
        }
    }

    // MARK: - GridOverlayRendering

    public func show(configuration: GridConfiguration, state: GestureState) {
        lastConfiguration = configuration
        lastState = state
        rebuildWindows()
        applyConfiguration(configuration, state: state)
        fadeIn()
        isVisible = true
    }

    public func updateSelection(rect: CGRect, state: GestureState) {
        lastState = state
        guard let target = overlayWindows.max(by: { overlapArea($0, rect) < overlapArea($1, rect) }) else { return }
        for window in overlayWindows {
            let view: GridOverlayContentView = window.overlayContentView
            view.setGridLinesVisible(shouldShowGridLines(for: state))
            if window === target {
                view.setFreeResizeStyle(isFreeResize(state))
                view.setSelection(rect, quartzOrigin: window.quartzOrigin)
            } else {
                view.setSelection(nil, quartzOrigin: window.quartzOrigin)
            }
        }
    }

    public func hide() {
        guard isVisible else { return }
        isVisible = false
        fadeOutThenTeardown()
    }

    /// Lets Preferences update the overlay's colors/opacity live without
    /// tearing down and reconstructing the whole controller. Added during
    /// Input-module integration planning (not part of the original chunk
    /// document).
    public func updateAppearance(_ appearance: OverlayAppearance) {
        self.appearance = appearance
    }

    // MARK: - Screen configuration changes

    /// Registered once at init against
    /// `NSApplication.didChangeScreenParametersNotification`.
    private func screenParametersDidChange() {
        // Not currently mid-gesture: nothing to do. The next show() call
        // will read NSScreen.screens fresh and build the right window set
        // naturally.
        guard isVisible else { return }

        // Mid-gesture screen change (monitor unplugged/lid closed/
        // arrangement changed while the user is dragging): tear down and
        // rebuild cleanly against the new screen list, and re-apply
        // whatever grid config/state was last known. Deliberately does
        // NOT try to preserve the in-flight selection rect — if the screen
        // the anchor cell lived on just disappeared, that rect may no
        // longer mean anything. Overlay's job is to not crash and not show
        // garbage; deciding whether to keep going or cancel the gesture
        // entirely belongs to Input, not to this target.
        rebuildWindows()
        if let configuration = lastConfiguration, let state = lastState {
            applyConfiguration(configuration, state: state)
        }
        for window in overlayWindows {
            window.alphaValue = appearance.opacity
            window.orderFront(nil)
        }
    }

    // MARK: - Window lifecycle

    /// Overlay windows are cheap, short-lived, and rebuilt from scratch on
    /// every `show()` call by reading `NSScreen.screens` fresh each time —
    /// there is no persistent pool of windows sitting around between
    /// gestures. This sidesteps an entire class of "stale screen array"
    /// bugs for free.
    private func rebuildWindows() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = NSScreen.screens.map { OverlayWindow.make(for: $0) }
    }

    private func applyConfiguration(_ configuration: GridConfiguration, state: GestureState) {
        for window in overlayWindows {
            window.overlayContentView.applyAppearance(appearance)
            window.overlayContentView.rebuildGridLines(
                configuration: configuration,
                screenFrame: window.quartzFrame,
                quartzOrigin: window.quartzOrigin
            )
            window.overlayContentView.setGridLinesVisible(shouldShowGridLines(for: state))
        }
    }

    private func fadeIn() {
        for window in overlayWindows {
            window.alphaValue = 0
            window.orderFront(nil) // never makeKeyAndOrderFront — see OverlayWindow
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            overlayWindows.forEach { $0.animator().alphaValue = appearance.opacity }
        }
    }

    private func fadeOutThenTeardown() {
        // Capture and clear self.overlayWindows immediately (rather than
        // after the animation completes) so a fast hide() followed by a
        // new show() never touches windows that are still mid-fade-out —
        // the new show() simply builds a fresh set.
        let windowsToClose = overlayWindows
        overlayWindows = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            windowsToClose.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            windowsToClose.forEach { $0.orderOut(nil) }
        })
    }

    // MARK: - Helpers

    /// `updateSelection` never receives (or needs) a screen parameter:
    /// since the incoming rect is already in Quartz-global space, this
    /// determines which screen's window should show the highlight purely
    /// by finding the greatest-overlap `quartzFrame` among its own
    /// windows.
    private func overlapArea(_ window: OverlayWindow, _ rect: CGRect) -> CGFloat {
        let intersection = window.quartzFrame.intersection(rect)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func shouldShowGridLines(for state: GestureState) -> Bool {
        switch state {
        case .gridActive, .anchored:
            return true
        case .idle, .dragging, .freeResize, .committed, .cancelled:
            return false
        }
    }

    private func isFreeResize(_ state: GestureState) -> Bool {
        if case .freeResize = state { return true }
        return false
    }
}
