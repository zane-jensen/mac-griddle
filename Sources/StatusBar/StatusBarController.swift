import AppKit
import Combine
import MacGriddleCore
import Preferences

/// The menu bar icon and menu. Constructing this already makes the status
/// item appear — there is no separate `show()`/`activate()` step, and no
/// explicit teardown API: this is expected to live for the entire app
/// process (a `let` on the composition root is sufficient, no `weak`
/// reference — an `NSStatusItem` that isn't retained anywhere disappears
/// from the menu bar the moment it's deallocated).
///
/// See `docs/architecture/chunks/statusbar-menu.md` for the full design.
@MainActor
public final class StatusBarController: NSObject {

    // MARK: - Status item

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // MARK: - Injected dependencies

    private let permissionsProvider: PermissionsProviding
    private let engineControl: EngineControlBridge
    private let preferencesWindowController: PreferencesWindowController
    private let openAccessibilitySettings: () -> Void
    private let openInputMonitoringSettings: () -> Void

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Menu items
    //
    // All stable NSMenuItem instances, held for the lifetime of the
    // controller and mutated in place (.isHidden, .title, .state) rather
    // than the menu being torn down and rebuilt on every state change —
    // rebuilding while the menu happens to be open risks visual glitches
    // and loses whatever item is currently highlighted under the mouse.

    private let headerItem = StatusBarController.makeHeaderItem()

    private let permissionsHeaderItem: NSMenuItem = {
        let item = NSMenuItem(title: "Permissions Needed", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()

    private let grantAccessibilityItem = NSMenuItem(
        title: "Grant Accessibility Access…",
        action: #selector(StatusBarController.grantAccessibilityAccess),
        keyEquivalent: ""
    )

    private let grantInputMonitoringItem = NSMenuItem(
        title: "Grant Input Monitoring Access…",
        action: #selector(StatusBarController.grantInputMonitoringAccess),
        keyEquivalent: ""
    )

    private let permissionsSectionSeparator = NSMenuItem.separator()

    private let enabledToggleItem = NSMenuItem(
        title: "Enabled",
        action: #selector(StatusBarController.toggleEnabled),
        keyEquivalent: ""
    )

    private let preferencesItem = NSMenuItem(
        title: "Preferences…",
        action: #selector(StatusBarController.openPreferences),
        keyEquivalent: ","
    )

    private let aboutItem = NSMenuItem(
        title: "About MacGriddle",
        action: #selector(StatusBarController.showAbout),
        keyEquivalent: ""
    )

    // target deliberately stays nil — the action flows up the responder
    // chain to NSApplication.terminate(_:) automatically, the standard
    // pattern for Quit menu items, not a bridge Input/Permissions need.
    private let quitItem = NSMenuItem(
        title: "Quit MacGriddle",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )

    // MARK: - Init

    public init(
        permissionsProvider: PermissionsProviding,
        engineControl: EngineControlBridge,
        preferencesWindowController: PreferencesWindowController,
        openAccessibilitySettings: @escaping () -> Void,
        openInputMonitoringSettings: @escaping () -> Void
    ) {
        self.permissionsProvider = permissionsProvider
        self.engineControl = engineControl
        self.preferencesWindowController = preferencesWindowController
        self.openAccessibilitySettings = openAccessibilitySettings
        self.openInputMonitoringSettings = openInputMonitoringSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItemButton()
        configureMenuItemTargets()
        buildMenuStructure()
        subscribeToLiveState()

        updateForCurrentState(
            accessibilityGranted: permissionsProvider.isAccessibilityGranted,
            inputMonitoringGranted: permissionsProvider.isInputMonitoringGranted,
            engineEnabled: engineControl.isEnabled()
        )
    }

    // MARK: - NSStatusItem / button setup

    private static func makeHeaderItem() -> NSMenuItem {
        let item = NSMenuItem(title: "MacGriddle", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: "MacGriddle",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        return item
    }

    private func configureStatusItemButton() {
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: "square.grid.3x2",
            accessibilityDescription: "MacGriddle"
        )
        // Template mode is what makes AppKit auto-recolor the glyph to
        // match the current menu bar tint — the only correct rendering
        // mode for a monochrome status item glyph.
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    // MARK: - Menu construction

    private func configureMenuItemTargets() {
        for item in [grantAccessibilityItem, grantInputMonitoringItem, enabledToggleItem, preferencesItem, aboutItem] {
            item.target = self
        }
        // quitItem deliberately keeps target == nil (see its declaration).
    }

    private func buildMenuStructure() {
        menu.addItem(headerItem)
        menu.addItem(.separator())

        menu.addItem(permissionsHeaderItem)
        menu.addItem(grantAccessibilityItem)
        menu.addItem(grantInputMonitoringItem)
        menu.addItem(permissionsSectionSeparator)

        menu.addItem(enabledToggleItem)
        menu.addItem(.separator())

        menu.addItem(preferencesItem)
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Live state observation

    /// `PermissionsProviding` only guarantees `ObservableObject`
    /// conformance (`objectWillChange`) plus synchronous getters for
    /// `isAccessibilityGranted`/`isInputMonitoringGranted` — it does not
    /// vend a per-flag `AnyPublisher` (see `core-contracts.md` §4/§8, the
    /// reconciled, real protocol shape). This derives a live
    /// `AnyPublisher<Bool, Never>` for one flag from those two guarantees
    /// alone, generic over the concrete conformer so the property-wrapper
    /// machinery isn't needed:
    ///
    /// - `.receive(on:)` runs *before* the read, not after. `@Published`'s
    ///   synthesized `objectWillChange` fires from `willSet` — before the
    ///   backing storage is actually updated — so a synchronous read inside
    ///   the same call stack would observe the stale, pre-mutation value.
    ///   Hopping to the main queue first guarantees the mutation has
    ///   completed by the time `currentValue` is evaluated.
    /// - `.prepend` supplies an immediate current value on subscription, so
    ///   the `Publishers.CombineLatest3` below (which only emits once every
    ///   input has emitted at least once) gets a first value from this
    ///   input right away, rather than waiting for some future change that
    ///   may never come during this run.
    private func liveGrantedPublisher<P: PermissionsProviding>(
        from provider: P,
        reading currentValue: @escaping (P) -> Bool
    ) -> AnyPublisher<Bool, Never> {
        provider.objectWillChange
            .receive(on: DispatchQueue.main)
            .map { _ in currentValue(provider) }
            .prepend(currentValue(provider))
            .eraseToAnyPublisher()
    }

    private func subscribeToLiveState() {
        let accessibilityGrantedPublisher = liveGrantedPublisher(from: permissionsProvider) {
            $0.isAccessibilityGranted
        }
        let inputMonitoringGrantedPublisher = liveGrantedPublisher(from: permissionsProvider) {
            $0.isInputMonitoringGranted
        }

        // One combined subscription rather than three separate ones, so
        // there's a single code path (updateForCurrentState) that always
        // sees a consistent triple of the latest values.
        Publishers.CombineLatest3(
            accessibilityGrantedPublisher,
            inputMonitoringGrantedPublisher,
            engineControl.isEnabledPublisher
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] accessibilityGranted, inputMonitoringGranted, engineEnabled in
            self?.updateForCurrentState(
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                engineEnabled: engineEnabled
            )
        }
        .store(in: &cancellables)
    }

    private func updateForCurrentState(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        engineEnabled: Bool
    ) {
        let permissionsComplete = accessibilityGranted && inputMonitoringGranted

        permissionsHeaderItem.isHidden = permissionsComplete
        grantAccessibilityItem.isHidden = accessibilityGranted
        grantInputMonitoringItem.isHidden = inputMonitoringGranted
        permissionsSectionSeparator.isHidden = permissionsComplete

        enabledToggleItem.title = engineEnabled ? "Enabled" : "Disabled"
        enabledToggleItem.state = engineEnabled ? .on : .off

        refreshIcon(isFullyActive: permissionsComplete && engineEnabled)
    }

    // MARK: - Icon state signaling

    /// Dims the whole status item to reduced opacity when the engine isn't
    /// fully active (both permissions granted *and* the toggle is on); full
    /// opacity when it is. `alphaValue` is a pure rendering property —
    /// unlike `NSControl.isEnabled = false`, it does not affect
    /// hit-testing, so the button stays fully clickable, which matters:
    /// the user must always be able to open the menu to fix whatever's
    /// wrong, especially while something's wrong.
    private func refreshIcon(isFullyActive: Bool) {
        guard let button = statusItem.button else { return }
        button.alphaValue = isFullyActive ? 1.0 : 0.4

        // alphaValue alone communicates nothing to VoiceOver — mirror the
        // same signal in the accessibility label.
        button.setAccessibilityLabel(
            isFullyActive
                ? "MacGriddle"
                : "MacGriddle — attention needed, open menu for details"
        )
    }

    // MARK: - Menu actions

    @objc private func toggleEnabled() {
        // Does not optimistically flip its own title/state — it calls
        // setEnabled and waits for the resulting value to come back
        // through isEnabledPublisher, so the menu never shows a state it
        // merely hopes is true.
        engineControl.setEnabled(!engineControl.isEnabled())
    }

    @objc private func openPreferences() {
        preferencesWindowController.show()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [:])
        // MacGriddle runs with an accessory activation policy (no Dock
        // icon) — without an explicit activate call, the about panel can
        // appear behind whatever app currently has focus.
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func grantAccessibilityAccess() {
        openAccessibilitySettings()
    }

    @objc private func grantInputMonitoringAccess() {
        openInputMonitoringSettings()
    }
}

// MARK: - NSMenuDelegate

extension StatusBarController: NSMenuDelegate {
    /// The combined subscription in `subscribeToLiveState()` already keeps
    /// everything live whether or not the menu is open. This is a
    /// defensive resync on top of that, not the primary mechanism — it
    /// guards against any edge case where a state change happened before
    /// that subscription finished wiring up, or while the app was
    /// suspended.
    public func menuWillOpen(_ menu: NSMenu) {
        updateForCurrentState(
            accessibilityGranted: permissionsProvider.isAccessibilityGranted,
            inputMonitoringGranted: permissionsProvider.isInputMonitoringGranted,
            engineEnabled: engineControl.isEnabled()
        )
    }
}
