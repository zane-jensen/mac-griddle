// Sources/MacGriddle/AppDelegate.swift
//
// Composition root for MacGriddle. Sequencing/shape follows
// docs/architecture/chunks/app-shell-and-lifecycle.md §2–§6; every
// construction call below has been corrected against
// docs/architecture/chunks/composition-root-wiring-fixups.md §1–§6 rather
// than that chunk's own guesses. See this change's write-up for the one
// place this file deliberately diverges further, beyond the fixups doc,
// from app-shell-and-lifecycle.md §3.6/§3.7 (launch-at-login
// reconciliation is not implemented here — see below).

import AppKit
import Combine
import SwiftUI

import MacGriddleCore   // PermissionsProviding, WindowControlling, OverlayAppearance
import GridEngine       // GridConfiguration — lives here, not MacGriddleCore
import Permissions      // PermissionsMonitor, SystemSettingsDeepLink
import WindowControl    // AXWindowController
import Overlay          // GridOverlayController
import Input            // InputEngine
import Preferences      // SettingsStore, PreferencesWindowController
import StatusBar        // StatusBarController, EngineControlBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Composition-root-owned instances
    //
    // Constructed exactly once, inside proceedPastPermissions()/
    // installStatusBar(), and live for the remainder of the process.
    // Implicitly-unwrapped rather than plain Optional for the same reason
    // app-shell-and-lifecycle.md §2.3 gives: there is no clean way to
    // express "absent only during the brief onboarding gate at startup,
    // guaranteed present afterward" other than IUO. Call sites still use
    // `?.` defensively.

    private var permissions: PermissionsProviding!
    private var settingsStore: SettingsStore!
    private var windowController: WindowControlling!
    private var overlayController: GridOverlayController!
    private var inputEngine: InputEngine!
    private var preferencesWindowController: PreferencesWindowController!
    private var statusBarController: StatusBarController!

    private var onboardingCoordinator: OnboardingCoordinator?

    private var engineEnabled = false
    private let engineEnabledSubject = CurrentValueSubject<Bool, Never>(false)
    private var permissionsSubscription: AnyCancellable?
    private var settingsSubscriptions = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let permissions = PermissionsMonitor() // fixup §1: not SystemPermissionsProvider
        self.permissions = permissions

        let store = SettingsStore()
        self.settingsStore = store

        if permissions.isFullyPermitted {
            proceedPastPermissions()
        } else {
            presentOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputEngine?.stop()
    }
}

// MARK: - Onboarding (composition-root-wiring-fixups.md §3)

private extension AppDelegate {
    func presentOnboarding() {
        let coordinator = OnboardingCoordinator(permissions: permissions)
        onboardingCoordinator = coordinator

        // Accessory apps are not auto-activated on launch — see
        // app-shell-and-lifecycle.md §6.1.
        NSApp.activate(ignoringOtherApps: true)

        coordinator.present { [weak self] in
            self?.onboardingCoordinator = nil
            self?.proceedPastPermissions()
        }
    }

    /// Closes the gap an independent review found: `permissions-model.md`
    /// §4 specifies a `degraded(missing:)` screen that should reappear
    /// after a *runtime* revocation, not just render correctly in
    /// isolation. `StatusBarController` already reflects degraded state in
    /// its own menu independently — this adds the richer explanatory
    /// window back on top of that, matching the architecture doc's stated
    /// intent ("even when the onboarding window isn't on screen").
    ///
    /// Unlike first-run `presentOnboarding()`, completion here must NOT
    /// call `proceedPastPermissions()` again — every core service is
    /// already constructed and running; it only needs to resume, and the
    /// window must not terminate the app if the user simply dismisses it
    /// (the rest of the app is already up).
    func presentDegradedNoticeIfNeeded() {
        guard onboardingCoordinator == nil else { return } // already showing one

        let coordinator = OnboardingCoordinator(
            permissions: permissions,
            startingFromDegraded: true,
            terminatesAppOnEarlyClose: false
        )
        onboardingCoordinator = coordinator

        NSApp.activate(ignoringOtherApps: true)

        coordinator.present { [weak self] in
            self?.onboardingCoordinator = nil
            self?.setEngineEnabled(true) // resume — permissions are confirmed granted again
        }
    }
}

// MARK: - Core service construction

private extension AppDelegate {
    func proceedPastPermissions() {
        let windowControl = AXWindowController()
        windowController = windowControl

        // fixup §4: OverlayAppearance built from settingsStore's color/
        // opacity fields BEFORE constructing GridOverlayController, which
        // takes it at init rather than a zero-arg init.
        let appearance = OverlayAppearance(
            cellStrokeColor: NSColor(settingsStore.cellStrokeColor),
            selectionFillColor: NSColor(settingsStore.selectionFillColor),
            selectionStrokeColor: NSColor(settingsStore.selectionStrokeColor),
            opacity: settingsStore.overlayOpacity
        )
        let overlay = GridOverlayController(appearance: appearance)
        overlayController = overlay

        // fixup §5: no settings: parameter — Input can't depend on
        // Preferences. configure(...) is a separate call.
        let engine = InputEngine(
            windowControl: windowControl,
            overlay: overlay,
            permissions: permissions
        )
        inputEngine = engine
        engine.configure(
            gridConfiguration: GridConfiguration(columns: settingsStore.gridColumns, rows: settingsStore.gridRows),
            liveResizeEnabled: settingsStore.liveResizeEnabled
        )

        engineEnabled = engine.start()
        engineEnabledSubject.value = engineEnabled

        observePermissionChanges()
        observeSettingsChanges()
        installStatusBar()

        // NOTE: app-shell-and-lifecycle.md §3.6/§3.7 calls for a
        // reconcileLaunchAtLogin() step here. Omitted deliberately —
        // project-structure.md §4 explicitly states the composition root
        // "must never call .register()/.unregister()" on LaunchAtLogin,
        // in direct conflict with that §3.6 snippet. See this change's
        // write-up for the full explanation and the deeper gap it surfaced.
    }

    func installStatusBar() {
        // Built before StatusBarController, per fixup §6b, so the same
        // instance can be passed into it — both end up sharing ownership.
        preferencesWindowController = PreferencesWindowController(settings: settingsStore)

        // fixup §6c: a real publisher backing EngineControlBridge, not an
        // imperative setEngineEnabled(_:) call on StatusBarController
        // (which doesn't exist on the real type).
        let engineControl = EngineControlBridge(
            isEnabled: { [weak self] in self?.engineEnabled ?? false },
            isEnabledPublisher: engineEnabledSubject.eraseToAnyPublisher(),
            setEnabled: { [weak self] enabled in self?.setEngineEnabled(enabled) }
        )

        // fixup §6: real parameter list — permissionsProvider/engineControl/
        // preferencesWindowController/two open*Settings closures. No
        // settings:/initialEngineEnabled:/onOpenPreferences:/
        // onToggleEngineEnabled:/onQuit: (§6a/§6d: no .install() call and
        // no onQuit either — the real Quit item flows to NSApplication via
        // the responder chain on its own).
        let statusBar = StatusBarController(
            permissionsProvider: permissions,
            engineControl: engineControl,
            preferencesWindowController: preferencesWindowController,
            openAccessibilitySettings: { SystemSettingsDeepLink.accessibility.open() },
            openInputMonitoringSettings: { SystemSettingsDeepLink.inputMonitoring.open() }
        )
        statusBarController = statusBar
    }
}

// MARK: - Reacting to permission loss at runtime

private extension AppDelegate {
    func observePermissionChanges() {
        // fixup §2, refined: permissions.objectWillChange doesn't compile
        // directly through the PermissionsProviding existential (Swift
        // can't resolve the associated ObjectWillChangePublisher type
        // without a generic binding) — use the shared Core extension
        // property instead (see Sources/MacGriddleCore/PermissionsChangePublisher.swift).
        permissionsSubscription = permissions.changePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handlePermissionsChanged() }
    }

    func handlePermissionsChanged() {
        guard !permissions.isFullyPermitted else { return }
        setEngineEnabled(false)
        presentDegradedNoticeIfNeeded()
    }

    /// Single code path for both directions the engine can be
    /// enabled/disabled: a permission being revoked (above) and the
    /// user's manual toggle in the StatusBar menu (routed here via
    /// EngineControlBridge.setEnabled above).
    func setEngineEnabled(_ enabled: Bool) {
        if enabled {
            engineEnabled = inputEngine?.start() ?? false
        } else {
            inputEngine?.stop()
            engineEnabled = false
        }
        // fixup §6c: publish through the subject StatusBar observes,
        // rather than calling a statusBarController?.setEngineEnabled(...)
        // that doesn't exist on the real type.
        engineEnabledSubject.value = engineEnabled
    }
}

// MARK: - Live settings -> running services

private extension AppDelegate {
    /// Keeps a running InputEngine/GridOverlayController in sync with
    /// Preferences edits, per input-engine-and-state-machine.md §9's and
    /// overlay-rendering.md's own confirmation that configure(...)/
    /// updateAppearance(...) are meant to be called again whenever the
    /// relevant SettingsStore fields change, not just once at launch.
    func observeSettingsChanges() {
        Publishers.CombineLatest3(
            settingsStore.$gridColumns,
            settingsStore.$gridRows,
            settingsStore.$liveResizeEnabled
        )
        .dropFirst() // initial values already applied once above
        .receive(on: DispatchQueue.main)
        .sink { [weak self] columns, rows, liveResizeEnabled in
            self?.inputEngine?.configure(
                gridConfiguration: GridConfiguration(columns: columns, rows: rows),
                liveResizeEnabled: liveResizeEnabled
            )
        }
        .store(in: &settingsSubscriptions)

        Publishers.CombineLatest4(
            settingsStore.$cellStrokeColor,
            settingsStore.$selectionFillColor,
            settingsStore.$selectionStrokeColor,
            settingsStore.$overlayOpacity
        )
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] cellStroke, selectionFill, selectionStroke, opacity in
            self?.overlayController?.updateAppearance(
                OverlayAppearance(
                    cellStrokeColor: NSColor(cellStroke),
                    selectionFillColor: NSColor(selectionFill),
                    selectionStrokeColor: NSColor(selectionStroke),
                    opacity: opacity
                )
            )
        }
        .store(in: &settingsSubscriptions)
    }
}
