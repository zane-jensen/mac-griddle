import AppKit
import Combine
import MacGriddleCore

/// Concrete implementation of `PermissionsProviding` (core-contracts.md §4).
/// Owns all polling/observing logic so nothing outside this target ever
/// has to know *how* a grant or a revocation gets discovered.
///
/// Combines two signals to discover grants/revocations, since macOS has no
/// push notification for "the user just flipped a TCC checkbox in System
/// Settings":
///
/// 1. `NSApplication.didBecomeActiveNotification` — the primary signal,
///    covering the common path of System Settings taking focus away and
///    the user returning to MacGriddle afterward.
/// 2. A short-interval timer, but only while a permission is actually
///    outstanding — gives onboarding a checkmark that appears "immediately"
///    without a permanent busy-loop once setup is complete.
///
/// See docs/architecture/chunks/permissions-model.md §3.
public final class PermissionsMonitor: ObservableObject, PermissionsProviding {

    @Published public private(set) var isAccessibilityGranted: Bool
    @Published public private(set) var isInputMonitoringGranted: Bool

    /// Non-nil only while at least one permission is outstanding
    /// (first-run onboarding, or a later re-grant recovery flow).
    /// This is what keeps the strategy from being a permanent busy-loop.
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0
    private var activationObserver: NSObjectProtocol?

    public init() {
        isAccessibilityGranted = AccessibilityPermission.isGranted()
        isInputMonitoringGranted = InputMonitoringPermission.isGranted()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }

        startPollingIfNeeded()
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    // MARK: - PermissionsProviding

    public func requestAccessibility() {
        // Void return by design — see the callout below. The prompt is
        // fired; the real answer arrives later through the published
        // booleans, not through this call's return value.
        AccessibilityPermission.requestPrompt()
        startPollingIfNeeded()
    }

    public func requestInputMonitoring() {
        InputMonitoringPermission.requestPrompt()
        startPollingIfNeeded()
    }

    public func refreshStatus() {
        isAccessibilityGranted = AccessibilityPermission.isGranted()
        isInputMonitoringGranted = InputMonitoringPermission.isGranted()
        startPollingIfNeeded() // re-arms if something just became ungranted
    }

    // MARK: - Private

    /// Starts the fast poll only when at least one permission is
    /// outstanding; stops itself the instant both are granted.
    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        guard !(isAccessibilityGranted && isInputMonitoringGranted) else { return }

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ax = AccessibilityPermission.isGranted()
            let im = InputMonitoringPermission.isGranted()
            if ax != self.isAccessibilityGranted { self.isAccessibilityGranted = ax }
            if im != self.isInputMonitoringGranted { self.isInputMonitoringGranted = im }
            if ax && im {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
            }
        }
        // .common so the timer still fires while a menu is tracking
        // (the NSStatusItem menu is open) or a modal onboarding window is
        // running — same reasoning RESEARCH.md B.2.2 gives for attaching
        // the CGEventTap's run-loop source to .commonModes. Using the
        // non-auto-scheduling `Timer(timeInterval:repeats:block:)`
        // initializer and adding it to .common explicitly (rather than
        // `Timer.scheduledTimer`, which auto-adds to .default) avoids any
        // ambiguity about double registration.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
