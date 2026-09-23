import Combine

/// Two independently-gated TCC permissions MacGriddle needs — Accessibility
/// (window read/move/resize via AXUIElement) and Input Monitoring (the
/// listen-only CGEventTap). Granting one does NOT grant the other; see
/// docs/RESEARCH.md §B.2.1 and docs/architecture/chunks/permissions-model.md.
///
/// `ObservableObject` conformance is required (not a bespoke publisher
/// requirement) so conformers can expose `@Published` properties and get
/// `objectWillChange`/`$property` publishers for free — callers that need a
/// per-flag or combined publisher derive one locally from those, rather than
/// this protocol growing extra publisher-shaped requirements.
///
/// See docs/architecture/chunks/core-contracts.md §4.
public protocol PermissionsProviding: ObservableObject {
    var isAccessibilityGranted: Bool { get }
    var isInputMonitoringGranted: Bool { get }

    /// Void by design, not Bool — the underlying
    /// AXIsProcessTrustedWithOptions/CGRequestListenEventAccess calls return
    /// a Bool that reflects trust state at the instant of the call, before
    /// the user has acted on the system prompt it just triggered. The real
    /// answer arrives later, through isAccessibilityGranted/isInputMonitoringGranted.
    func requestAccessibility()
    func requestInputMonitoring()
    func refreshStatus()
}

extension PermissionsProviding {
    /// MacGriddle's gesture depends on both permissions simultaneously —
    /// partial-grant states are exactly as non-functional as no grant at
    /// all (permissions-model.md §5). A default implementation here can
    /// never drift out of sync with the two booleans it derives from.
    public var isFullyPermitted: Bool {
        isAccessibilityGranted && isInputMonitoringGranted
    }
}
