import ApplicationServices
import MacGriddleCore

/// Concrete `WindowControlling` conformance backed by the macOS
/// Accessibility (AX) API — the only type in MacGriddle that talks
/// directly to another application's `AXUIElement` tree.
///
/// Stateless today (a `struct` would work identically) but written as a
/// `final class` to leave room for future instance state (e.g. retry
/// counters, instrumentation) without an API change.
///
/// See docs/architecture/chunks/window-control-and-coordinates.md.
public final class AXWindowController: WindowControlling {
    public init() {}
}

extension AXWindowController {
    /// The window at `point`, in Quartz (global-display, top-left-origin,
    /// Y-down) screen coordinates.
    public func window(at point: CGPoint) -> WindowHandle? {
        guard let axWindow = Self.resolvedWindowElement(at: point) else { return nil }
        return WindowHandle(axElement: axWindow)
    }
}

private extension AXWindowController {
    /// The system-wide accessibility element: the hit-testing root for
    /// *every* other application, never a specific app's own element.
    /// Cheap and stateless to hold on to — no need to recreate it per call.
    static let systemWideElement = AXUIElementCreateSystemWide()

    /// Resolves the window-level `AXUIElement` at `point`. `point` must
    /// already be in Quartz screen coordinates. Note the underlying C API
    /// takes `Float` (32-bit), not `CGFloat`/`Double`; the narrowing
    /// conversion below is required by
    /// `AXUIElementCopyElementAtPosition`'s actual signature, not a mistake.
    static func resolvedWindowElement(at point: CGPoint) -> AXUIElement? {
        var hitElement: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard error == .success, let element = hitElement else { return nil }
        return resolveToWindow(element)
    }

    /// Walks from an arbitrary hit-tested element (a button, a text field,
    /// whatever is visually topmost — `AXUIElementCopyElementAtPosition`
    /// returns the *deepest* element, not necessarily the window) up to
    /// its owning window:
    ///
    /// 1. Fast path — is the hit element itself already role `kAXWindowRole`?
    /// 2. Otherwise, does it expose `kAXWindowAttribute` (a direct pointer
    ///    to its containing window)?
    /// 3. Otherwise, fall back to walking `kAXParentAttribute` by hand
    ///    until role `kAXWindowRole` is found or the chain runs out.
    ///
    /// Deliberately not used: `kAXTopLevelUIElementAttribute` — it returns
    /// `nil` for some floating/panel-style windows; `kAXWindowAttribute`
    /// covers the same case reliably, so the parent-walk stays the last
    /// resort, not the primary path.
    static func resolveToWindow(_ element: AXUIElement) -> AXUIElement? {
        // 1. Fast path — is this element itself a window?
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == kAXWindowRole as String {
            return element
        }

        // 2. Most elements expose kAXWindowAttribute: a direct pointer to
        //    their containing window, without needing a manual parent walk.
        //    Per Apple's header docs: "Required for any element that has
        //    an element of role kAXWindowRole somewhere in its parent
        //    chain."
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
           let window = windowRef {
            return (window as! AXUIElement)
        }

        // 3. Fallback for the rare element with neither: walk
        //    kAXParentAttribute manually until role == kAXWindowRole or
        //    the chain ends.
        var current = element
        while true {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                return nil
            }
            current = parent as! AXUIElement

            var parentRoleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &parentRoleRef) == .success,
               let parentRole = parentRoleRef as? String,
               parentRole == kAXWindowRole as String {
                return current
            }
        }
    }
}
