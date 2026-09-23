// Sources/MacGriddle/OnboardingCoordinator.swift
//
// permissions-model.md §4 explicitly declines to own "onboarding screen
// sequencing," leaving it to "whichever chunk ends up owning the actual
// enum." Nobody else claimed the sequencing logic (composition-root-wiring-
// fixups.md §3), so the view model and the NSWindow-hosting coordinator are
// built here. `OnboardingStage`/`MissingPermission` themselves are already
// defined as real, public types in the Permissions module (see
// Sources/Permissions/OnboardingStage.swift) — imported below, not
// redeclared. Deliberately minimal: functional correctness, not visual
// polish, is the goal for this milestone.

import AppKit
import Combine
import SwiftUI

import MacGriddleCore
import Permissions

/// Derives `OnboardingStage` from `PermissionsProviding`'s two live
/// booleans plus two pieces of state that only make sense scoped to a
/// single onboarding session: whether the user has tapped "Get Started"
/// yet, and whether `readyToUse` has already been reached once (which
/// distinguishes first-run "requesting" from a post-setup "degraded").
///
/// permissions-model.md §4 suggests `hasCompletedOnboardingOnce` should
/// live in Preferences' UserDefaults-backed store instead — but the real
/// SettingsStore (preferences-ui.md) has no such field, and Preferences is
/// out of bounds for this pass to add one to. `hasReachedReadyOnce` here is
/// therefore in-memory/per-launch only, not persisted; see the write-up
/// returned alongside this change for why that's an acceptable scope cut.
@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var stage: OnboardingStage = .welcome

    private let permissions: PermissionsProviding
    private var hasStarted = false
    private var hasReachedReadyOnce = false
    private var cancellable: AnyCancellable?

    init(permissions: PermissionsProviding, startingFromDegraded: Bool = false) {
        self.permissions = permissions
        self.hasReachedReadyOnce = startingFromDegraded
        // permissions.objectWillChange doesn't compile directly through the
        // PermissionsProviding existential — see
        // Sources/MacGriddleCore/PermissionsChangePublisher.swift.
        cancellable = permissions.changePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeStage() }

        recomputeStage()
    }

    func start() {
        hasStarted = true
        recomputeStage()
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
    }

    func requestInputMonitoring() {
        permissions.requestInputMonitoring()
    }

    func openAccessibilitySettings() {
        SystemSettingsDeepLink.accessibility.open()
    }

    func openInputMonitoringSettings() {
        SystemSettingsDeepLink.inputMonitoring.open()
    }

    private func recomputeStage() {
        let accessibilityGranted = permissions.isAccessibilityGranted
        let inputMonitoringGranted = permissions.isInputMonitoringGranted

        if accessibilityGranted && inputMonitoringGranted {
            hasReachedReadyOnce = true
            stage = .readyToUse
            return
        }

        if hasReachedReadyOnce {
            switch (accessibilityGranted, inputMonitoringGranted) {
            case (false, false):
                stage = .degraded(missing: .both)
            case (false, true):
                stage = .degraded(missing: .accessibility)
            case (true, false):
                stage = .degraded(missing: .inputMonitoring)
            case (true, true):
                stage = .readyToUse // unreachable — guarded above
            }
            return
        }

        if !hasStarted {
            stage = .welcome
            return
        }

        stage = accessibilityGranted ? .requestingInputMonitoring : .requestingAccessibility
    }
}

/// Hosts `OnboardingView` in a single `NSWindow`. Owned by `AppDelegate`
/// for the coordinator's lifetime (app-shell-and-lifecycle.md §6.3's
/// ownership rationale applies here too), constructed fresh each time
/// `presentOnboarding()` runs.
@MainActor
final class OnboardingCoordinator: NSObject, NSWindowDelegate {
    private let viewModel: OnboardingViewModel
    private var windowController: NSWindowController?
    private var stageCancellable: AnyCancellable?
    private var completion: (() -> Void)?
    private var didComplete = false

    /// `true` for first-run onboarding (nothing else in the app exists yet
    /// to quit from otherwise); `false` when re-presenting the degraded-
    /// permission notice after the app is already fully running, where the
    /// user closing an informational window should not quit MacGriddle.
    private let terminatesAppOnEarlyClose: Bool

    init(
        permissions: PermissionsProviding,
        startingFromDegraded: Bool = false,
        terminatesAppOnEarlyClose: Bool = true
    ) {
        self.viewModel = OnboardingViewModel(permissions: permissions, startingFromDegraded: startingFromDegraded)
        self.terminatesAppOnEarlyClose = terminatesAppOnEarlyClose
        super.init()
    }

    func present(completion: @escaping () -> Void) {
        self.completion = completion

        let hostingController = NSHostingController(rootView: OnboardingView(viewModel: viewModel))
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacGriddle"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)

        stageCancellable = viewModel.$stage
            .sink { [weak self] stage in
                if stage == .readyToUse {
                    self?.finish()
                }
            }
    }

    private func finish() {
        // Set before close(): closing triggers windowWillClose(_:) below,
        // and that must see this as a normal completion, not an early
        // user-initiated dismissal.
        didComplete = true
        stageCancellable = nil
        windowController?.close()
        windowController = nil

        let completion = self.completion
        self.completion = nil
        completion?()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !didComplete else { return }
        guard terminatesAppOnEarlyClose else { return }
        // The user closed first-run onboarding via its titlebar button
        // before both permissions were granted. Nothing else exists yet at
        // this point — proceedPastPermissions() (which installs StatusBar,
        // the only other UI this app has) only runs after this coordinator
        // calls its completion handler — so there would otherwise be no way
        // to quit this accessory app at all short of Force Quit. Treat an
        // early close as "decline to proceed" and quit outright. Does not
        // apply to the degraded-notice re-presentation, where the rest of
        // the app is already running and dismissing an informational
        // window should not quit it.
        NSApp.terminate(nil)
    }
}
