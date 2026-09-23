import Combine
import CoreGraphics
import GridEngine
import MacGriddleCore
import Overlay

/// Orchestrates `WindowControl`, `Overlay`, and `Permissions` during a
/// live gesture by turning `GlobalMouseAndModifierTap`'s raw callbacks
/// into transitions of the internal gesture state machine (`InternalState`,
/// see InternalState.swift).
///
/// See docs/architecture/chunks/input-engine-and-state-machine.md §9.
public final class InputEngine {
    private let windowControl: WindowControlling
    private let overlay: GridOverlayRendering
    private let permissions: PermissionsProviding

    private var tap: GlobalMouseAndModifierTap?
    private var state: InternalState = .idle
    private var configuration = GridConfiguration(columns: 6, rows: 4) // overview.md default
    private var liveResizeEnabled = false
    private var permissionsCancellable: AnyCancellable?

    public init(
        windowControl: WindowControlling,
        overlay: GridOverlayRendering,
        permissions: PermissionsProviding
    ) {
        self.windowControl = windowControl
        self.overlay = overlay
        self.permissions = permissions

        // Retry tap creation whenever Input Monitoring flips true mid-session
        // (onboarding, or re-granting after a revocation) — §8. Routed
        // through subscribeToPermissionsChange(_:handler:) below rather than
        // calling `permissions.objectWillChange` directly on this existential
        // — see that function's doc comment for why the direct call doesn't
        // compile.
        permissionsCancellable = subscribeToPermissionsChange(permissions) { [weak self] in
            guard let self, self.permissions.isInputMonitoringGranted else { return }
            self.tap?.start()
        }
    }

    /// Called once by the composition root at launch, and again whenever
    /// the relevant SettingsStore fields change. `Input` never imports
    /// `Preferences` (see the chunk's fixed dependency table), so it only
    /// ever receives plain values here, not a live settings reference.
    public func configure(gridConfiguration: GridConfiguration, liveResizeEnabled: Bool) {
        self.configuration = gridConfiguration
        self.liveResizeEnabled = liveResizeEnabled
    }

    /// Installs the event tap. Returns whether the tap itself started
    /// successfully (Input Monitoring granted) — this does not also depend
    /// on Accessibility being granted; see §8 for why.
    @discardableResult
    public func start() -> Bool {
        let newTap = GlobalMouseAndModifierTap { [weak self] type, event in
            self?.handle(type: type, event: event)
        }
        let started = newTap.start()
        tap = newTap
        return started
    }

    public func stop() {
        tap?.stop()
        tap = nil
        // Defensive reset, mirroring the panic hotkey's own behavior — a
        // stop() call mid-gesture (app quitting, permission revoked) should
        // leave the target window exactly as it was, not half-resized.
        forceResetToIdle()
    }

    // MARK: - Deferring AppKit work off the CGEventTap callback

    /// Real crash, confirmed via a macOS crash report: creating an
    /// `NSWindow` synchronously from within the `CGEventTap` callback
    /// traps inside AppKit's own `-[NSWindow initWithContentRect:...]`.
    /// The callback is invoked reentrantly from deep inside
    /// `NSApplication`'s own live event-fetching machinery
    /// (`_DPSNextEvent` is on the same stack), and AppKit's window-creation
    /// path is not safe to re-enter from that nested context even though
    /// it is on the main thread. Every call into `overlay` — which
    /// constructs/tears down `NSWindow`s — must go through this, never
    /// called directly from `handle...` methods. Only ever pass plain,
    /// already-extracted value types (`CGRect`, `GestureState`,
    /// `GridConfiguration`) into `work` — never a `CGEvent`, whose lifetime
    /// is not guaranteed past this callback's synchronous scope.
    private func onMainRunLoop(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    // MARK: - Dispatch

    /// The single call site that assembles the §3 transition table and the
    /// §7 panic-hotkey check into the real switch-on-(state, event)
    /// implementation. Delegates to one private handler per CGEventType;
    /// each of those switches on the current `InternalState`.
    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            handleKeyDown(event)
        case .leftMouseDown:
            handleMouseDown(at: event.location)
        case .leftMouseDragged:
            handleMouseDragged(to: event.location)
        case .leftMouseUp:
            handleMouseUp(at: event.location)
        case .flagsChanged:
            handleFlagsChanged(optionHeld: event.flags.contains(.maskAlternate), at: event.location)
        default:
            break // tapDisabledByTimeout/ByUserInput are already handled and
                   // swallowed inside GlobalMouseAndModifierTap itself.
        }
    }

    /// §7: unconditional force-reset, safe to invoke from any state
    /// (including `.idle`, where it's a no-op past the state assignment
    /// already performed inside forceResetToIdle()).
    private func handleKeyDown(_ event: CGEvent) {
        guard isPanicHotkey(event) else { return }
        forceResetToIdle()
    }

    /// §3 table, `idle` row only — every other state has no defined
    /// `leftMouseDown` transition, so a stray mouseDown while a gesture is
    /// already in flight (which the OS shouldn't actually deliver without
    /// an intervening mouseUp) is ignored rather than restarting anything.
    private func handleMouseDown(at point: CGPoint) {
        guard case .idle = state else { return }

        guard let window = windowControl.window(at: point),
              let originalFrame = windowControl.frame(of: window) else {
            return // nothing under the cursor to act on; stay idle
        }

        let candidate = GestureCandidate(
            window: window,
            originalFrame: originalFrame,
            screenFrame: screenFrame(containing: point)
        )
        state = .dragging(candidate)
    }

    /// §3 table's `leftMouseDragged` rows, plus §6's live-resize branch.
    private func handleMouseDragged(to point: CGPoint) {
        switch state {
        case .idle, .dragging:
            break // no row for these — the native OS drag continues untouched

        case .gridActive:
            // Before anchoring, re-resolve the screen under the cursor on
            // every move (§9: "the user is free to choose which monitor to
            // start on") rather than using any previously-captured frame.
            let currentScreenFrame = screenFrame(containing: point)
            let hoveredCell = GridEngine.cell(at: point, in: configuration, screenFrame: currentScreenFrame)
            let hoveredCellRect = GridEngine.cellRect(
                column: hoveredCell.column,
                row: hoveredCell.row,
                in: configuration,
                screenFrame: currentScreenFrame
            )
            let publicState = state.publicState
            onMainRunLoop { [overlay] in overlay.updateSelection(rect: hoveredCellRect, state: publicState) }

        case .anchored(let candidate, let anchor):
            let rect = coveringRect(candidate: candidate, anchor: anchor, at: point)
            let publicState = state.publicState
            onMainRunLoop { [overlay] in overlay.updateSelection(rect: rect, state: publicState) }
            if liveResizeEnabled {
                windowControl.setFrame(rect, of: candidate.window)
            }

        case .freeResize(let candidate, let anchorPoint):
            let rect = GridEngine.freeResizeRect(from: anchorPoint, to: point)
            let publicState = state.publicState
            onMainRunLoop { [overlay] in overlay.updateSelection(rect: rect, state: publicState) }
            if liveResizeEnabled {
                windowControl.setFrame(rect, of: candidate.window)
            }
        }
    }

    /// §3 table's `leftMouseUp` rows: the ordinary-click discard, the
    /// cancel path, and the two commit paths (§5).
    private func handleMouseUp(at point: CGPoint) {
        switch state {
        case .idle:
            break

        case .dragging:
            // Ordinary click/drag the OS already handled; discard candidate.
            state = .idle

        case .gridActive(let candidate):
            // Cancel: leftMouseUp arriving in .gridActive means Option is
            // still held (an Option release would already have moved us to
            // .anchored) — exactly the table's "leftMouseUp (⌥ still held)" row.
            windowControl.setFrame(candidate.originalFrame, of: candidate.window)
            onMainRunLoop { [overlay] in overlay.hide() }
            state = .idle

        case .anchored(let candidate, let anchor):
            let finalRect = coveringRect(candidate: candidate, anchor: anchor, at: point)
            windowControl.setFrame(finalRect, of: candidate.window)
            onMainRunLoop { [overlay] in overlay.hide() }
            state = .idle

        case .freeResize(let candidate, let anchorPoint):
            let finalRect = GridEngine.freeResizeRect(from: anchorPoint, to: point)
            windowControl.setFrame(finalRect, of: candidate.window)
            onMainRunLoop { [overlay] in overlay.hide() }
            state = .idle
        }
    }

    /// §3 table's `flagsChanged` rows. Per §3's "Distinguishing" note, this
    /// is purely a function of (current Option bit, current state) — no
    /// separate tap-vs-hold timing logic. Only the state+bit combinations
    /// the table lists as real transitions do anything; every other
    /// combination (e.g. Option still held while already `.gridActive`,
    /// or still released while already `.anchored`) is a no-op self-loop.
    private func handleFlagsChanged(optionHeld: Bool, at point: CGPoint) {
        switch state {
        case .idle:
            break

        case .dragging(let candidate):
            guard optionHeld else { return }
            state = .gridActive(candidate)
            let publicState = state.publicState
            let currentConfiguration = configuration
            onMainRunLoop { [overlay] in overlay.show(configuration: currentConfiguration, state: publicState) }

        case .gridActive(let candidate):
            guard !optionHeld else { return }
            // Lock screenFrame to the screen under the cursor at this
            // instant (§9's screen-locking rule) — GestureCandidate's
            // fields are all `let`, so anchoring produces a new value
            // rather than mutating the existing one.
            let lockedScreenFrame = screenFrame(containing: point)
            let lockedCandidate = GestureCandidate(
                window: candidate.window,
                originalFrame: candidate.originalFrame,
                screenFrame: lockedScreenFrame
            )
            let anchor = GridEngine.cell(at: point, in: configuration, screenFrame: lockedScreenFrame)
            state = .anchored(lockedCandidate, anchor: anchor)

        case .anchored(let candidate, let anchor):
            guard optionHeld else { return }
            // Anchor point := anchor cell's rect origin, for geometric
            // continuity (§9) — deliberately not the current cursor point,
            // so the selection doesn't jump when toggling into free-resize.
            let anchorCellRect = GridEngine.cellRect(
                column: anchor.column,
                row: anchor.row,
                in: configuration,
                screenFrame: candidate.screenFrame
            )
            state = .freeResize(candidate, anchorPoint: anchorCellRect.origin)

        case .freeResize(let candidate, let anchorPoint):
            guard optionHeld else { return }
            // Toggle back: re-derive the anchor cell from the anchor point
            // captured when we entered free-resize, against the same
            // locked screenFrame — round-trips to the original anchor cell.
            let anchor = GridEngine.cell(at: anchorPoint, in: configuration, screenFrame: candidate.screenFrame)
            state = .anchored(candidate, anchor: anchor)
        }
    }

    // MARK: - Shared rect math (§6)

    /// Used by both the live-resize `leftMouseDragged` branch and the
    /// snap-on-release commit in `leftMouseUp`, so the exact same
    /// computation feeds both — guaranteeing the last applied frame is
    /// always the fully-settled final rect (§6), even if a live-resize
    /// call and the mouse-up event raced in an unexpected order.
    private func coveringRect(candidate: GestureCandidate, anchor: GridCell, at point: CGPoint) -> CGRect {
        let currentCell = GridEngine.cell(at: point, in: configuration, screenFrame: candidate.screenFrame)
        return GridEngine.coveringRect(from: anchor, to: currentCell, in: configuration, screenFrame: candidate.screenFrame)
    }

    // MARK: - Force reset (§7 panic hotkey, and stop())

    private func forceResetToIdle() {
        if case .dragging(let candidate) = state { restore(candidate) }
        if case .gridActive(let candidate) = state { restore(candidate) }
        if case .anchored(let candidate, _) = state { restore(candidate) }
        if case .freeResize(let candidate, _) = state { restore(candidate) }
        onMainRunLoop { [overlay] in overlay.hide() }
        state = .idle
    }

    private func restore(_ candidate: GestureCandidate) {
        windowControl.setFrame(candidate.originalFrame, of: candidate.window)
    }
}

/// Workaround for a Swift existential limitation: `PermissionsProviding`
/// inherits `ObservableObject`, which declares `objectWillChange` in terms
/// of an associated type (`Self.ObjectWillChangePublisher`, defaulted to
/// `ObservableObjectPublisher` but not fixed by a `where` clause on
/// `PermissionsProviding` itself). Calling `permissions.objectWillChange`
/// directly on a plain `PermissionsProviding`-typed value (an existential —
/// exactly what `InputEngine.init`'s parameter is) fails to compile with
/// "property 'objectWillChange' requires the types
/// 'Self.ObjectWillChangePublisher' and 'ObservableObjectPublisher' be
/// equivalent". Routing the same call through a generic function lets
/// Swift "open" the existential into a concrete conforming type at the
/// call site, where the associated type is fully known and the property
/// resolves fine. `PermissionsProviding` itself is untouched — this is a
/// call-site-only workaround, confirmed to compile and run correctly.
private func subscribeToPermissionsChange<P: PermissionsProviding>(
    _ permissions: P,
    handler: @escaping () -> Void
) -> AnyCancellable {
    permissions.objectWillChange.sink { _ in handler() }
}
