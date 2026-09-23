import ApplicationServices

/// Opaque, cross-module reference to a single window, owned by whichever
/// application exposes it. `WindowControl` is the only target that should
/// ever read `.axElement`; every other target treats `WindowHandle` as an
/// opaque value it passes around, not something it introspects.
///
/// See docs/architecture/chunks/core-contracts.md §3.
public struct WindowHandle: Equatable {
    public let axElement: AXUIElement

    public init(axElement: AXUIElement) {
        self.axElement = axElement
    }

    /// `AXUIElement` does not conform to `Equatable` on its own — it is a
    /// `CFTypeRef` under the hood, and `CFEqual` is the correct way to
    /// compare two references for referring to the same accessibility
    /// object. Needed by Input's state machine to confirm "the window I
    /// started this gesture on is still the one I'm about to commit a
    /// resize on."
    public static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
}

/// Every function operates in Quartz (global-display, top-left-origin,
/// Y-down) screen coordinates — the same space `AXUIElement` and
/// `CGEventTap` both already agree on natively. See
/// docs/architecture/chunks/core-contracts.md §7.
public protocol WindowControlling {
    /// The window at `point`, in Quartz screen coordinates.
    func window(at point: CGPoint) -> WindowHandle?

    /// `window`'s current frame, in Quartz screen coordinates.
    func frame(of window: WindowHandle) -> CGRect?

    /// Moves and resizes `window` to `frame` (Quartz screen coordinates).
    /// Returns `false` — rather than throwing — on any AX failure or
    /// unsettable-attribute case.
    @discardableResult
    func setFrame(_ frame: CGRect, of window: WindowHandle) -> Bool
}
