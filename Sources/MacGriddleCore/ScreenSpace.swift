import AppKit

/// Converts between Cocoa (AppKit: bottom-left origin, Y increases upward)
/// and Quartz (CoreGraphics/Accessibility: top-left origin, Y increases
/// downward) screen coordinate spaces. See docs/RESEARCH.md §B.3 and
/// docs/architecture/chunks/core-contracts.md §6.
///
/// Originally designed in docs/architecture/chunks/window-control-and-coordinates.md
/// as a WindowControl-local type; hoisted to Core because Overlay (which
/// does not depend on WindowControl) also needs it.
public enum ScreenSpace {
    /// The height of the PRIMARY screen (`NSScreen.screens[0]`) — Quartz's
    /// global coordinate origin is defined relative to this display, and it
    /// is NOT necessarily the screen under the cursor or the one with the
    /// key window. Deliberately not cached: screen arrangement can change
    /// at runtime, and a stale cached value is exactly the bug this type
    /// exists to prevent — every conversion function takes this as a
    /// required argument rather than defaulting it.
    public static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    public static func cocoaToQuartz(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The transform is its own inverse — identical arithmetic to
    /// `cocoaToQuartz`, kept as a separately named function so each call
    /// site reads correctly for the direction it means.
    public static func quartzToCocoa(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    public static func cocoaToQuartz(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    public static func quartzToCocoa(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Alias for `cocoaToQuartz(_:primaryScreenHeight:)` (rect overload),
    /// matching docs/RESEARCH.md §B.3.1's own function name exactly.
    public static func flippedRect(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        cocoaToQuartz(rect, primaryScreenHeight: primaryScreenHeight)
    }
}
