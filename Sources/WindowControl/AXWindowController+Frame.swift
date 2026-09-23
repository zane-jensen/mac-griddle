import ApplicationServices
import MacGriddleCore

extension AXWindowController {
    /// `window`'s current frame, in Quartz screen coordinates.
    ///
    /// Position and size come back from the Accessibility API as
    /// `AXValue`-boxed `CFTypeRef`s, which must be unboxed with
    /// `AXValueGetValue` into a `CGPoint`/`CGSize`. Two independent things
    /// can fail here, and both are checked: the `AXError` from the
    /// `AXUIElementCopy...` calls that fetch the boxed values, and the
    /// separate `Bool` from `AXValueGetValue` that reports whether the
    /// unboxing itself succeeded.
    public func frame(of window: WindowHandle) -> CGRect? {
        let axWindow = window.axElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }
}

extension AXWindowController {
    /// Moves and resizes `window` to `frame` (Quartz screen coordinates).
    ///
    /// Position is written before size: applying a *smaller* size first,
    /// while the window is still sitting at its *old* position, is what
    /// can get the resize clipped/clamped against stale geometry (e.g. a
    /// window pinned to the bottom-right of a screen that's both shrinking
    /// and moving). Both attribute writes execute unconditionally — the
    /// `&&` below only combines the two `AXError` results for the return
    /// value, it does not short-circuit the second
    /// `AXUIElementSetAttributeValue` call, so even if the position write
    /// fails, the size write is still attempted rather than leaving the
    /// window in an ambiguous, partially-applied state.
    @discardableResult
    public func setFrame(_ frame: CGRect, of window: WindowHandle) -> Bool {
        let axWindow = window.axElement
        var origin = frame.origin
        var size = frame.size

        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }

        let positionResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

        return positionResult == .success && sizeResult == .success
    }
}

extension AXWindowController {
    /// Preflight check for whether `window` supports being moved/resized
    /// at all (some windows — e.g. certain non-resizable utility panels —
    /// report `kAXPositionAttribute`/`kAXSizeAttribute` as not settable).
    ///
    /// Not required before calling `setFrame` — it already fails safely
    /// either way. Useful only when a caller wants to distinguish "this
    /// window doesn't support being moved/resized" from "the call failed
    /// for some other reason" ahead of time.
    public func isFrameSettable(_ window: WindowHandle) -> Bool {
        let axWindow = window.axElement
        var positionSettable: DarwinBoolean = false
        var sizeSettable: DarwinBoolean = false

        let positionCheck = AXUIElementIsAttributeSettable(axWindow, kAXPositionAttribute as CFString, &positionSettable)
        let sizeCheck = AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &sizeSettable)

        return positionCheck == .success && sizeCheck == .success
            && positionSettable.boolValue && sizeSettable.boolValue
    }
}
