import CoreGraphics

/// Raw Input Monitoring TCC check/request calls. Internal to the
/// `Permissions` target — `PermissionsMonitor` is the only caller.
///
/// See docs/architecture/chunks/permissions-model.md §2.
enum InputMonitoringPermission {

    /// Silent check — never shows UI, safe to call as often as needed.
    static func isGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Actively prompts with the system "MacGriddle would like to receive
    /// keystrokes and other input from other applications" dialog. Same
    /// one-shot-per-code-identity behavior as Accessibility
    /// (RESEARCH.md B.2.1), and the same caveat: the returned `Bool` is the
    /// state at the moment of the call, not a confirmed post-prompt result.
    @discardableResult
    static func requestPrompt() -> Bool {
        CGRequestListenEventAccess()
    }
}
