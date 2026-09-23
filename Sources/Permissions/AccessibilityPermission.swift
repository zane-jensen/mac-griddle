import ApplicationServices

/// Raw Accessibility TCC check/request calls. Internal to the `Permissions`
/// target — `PermissionsMonitor` is the only caller.
///
/// See docs/architecture/chunks/permissions-model.md §1.
enum AccessibilityPermission {

    /// Silent check — never shows UI, safe to call as often as needed.
    static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Actively prompts the user with the system "MacGriddle would like to
    /// control this computer using accessibility features" dialog — but
    /// only the FIRST time this process's code-signing identity is ever
    /// asked. Every call after an explicit Allow/Deny is a silent no-op
    /// that just returns the current trust state (RESEARCH.md B.1.1).
    ///
    /// - Important: the `Bool` this returns is the trust state at the
    ///   instant of the call — almost always still `false` immediately
    ///   after showing the prompt, because the user hasn't acted on the
    ///   system dialog yet. Never treat this return value as "the user
    ///   granted access." The real outcome shows up later, asynchronously,
    ///   through `isGranted()` — via the poll timer or
    ///   `didBecomeActiveNotification` (see `PermissionsMonitor`).
    @discardableResult
    static func requestPrompt() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [promptKey: true]
        return AXIsProcessTrustedWithOptions(options)
    }
}
