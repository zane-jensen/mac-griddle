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
    ///
    /// Returns the event to pass it through unmodified, or `nil` to swallow
    /// it. Only ever swallows `.leftMouseDragged` or the gesture-ending
    /// `.leftMouseUp`, and only when the corresponding handler reports it
    /// just took exclusive control of the window's frame via Accessibility
    /// — see `handleMouseDragged`'s and `handleMouseUp`'s doc comments.
    /// Every other event type, and every other outcome, always passes
    /// through: mouse-down, flagsChanged, and the panic hotkey's keyDown
    /// are never suppressed, and ordinary dragging (live-resize off, or
    /// before anchoring) is completely unaffected.
    private func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        switch type {
        case .keyDown:
            handleKeyDown(event)
        case .leftMouseDown:
            handleMouseDown(at: event.location)
        case .leftMouseDragged:
            if handleMouseDragged(to: event.location) {
                return nil // took over this tick's frame via AX — don't let
                            // WindowServer's native drag fight us for it
            }
        case .leftMouseUp:
            if handleMouseUp(at: event.location) {
                return nil // same reason as above, for the final tick —
                            // otherwise WindowServer's native drag does one
                            // last "catch up to the cursor" jump right after
                            // we set the correct final frame
            }
        case .flagsChanged:
            handleFlagsChanged(optionHeld: event.flags.contains(.maskAlternate), at: event.location)
        default:
            break // tapDisabledByTimeout/ByUserInput are already handled and
                   // swallowed inside GlobalMouseAndModifierTap itself.
        }
        return event
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
    ///
    /// Returns whether MacGriddle just took exclusive control of the
    /// window's frame for this tick — `true` only when live-resize is on
    /// AND `windowControl.setFrame` actually succeeded. `handle(type:event:)`
    /// uses this to decide whether to swallow the event (see that method's
    /// doc comment, and `GlobalMouseAndModifierTap`'s, for why: this is what
    /// stops WindowServer's native drag-follow from fighting our own
    /// AX-driven repositioning every frame). Only suppressing on an actual
    /// `setFrame` success matters here — if the write failed (non-resizable
    /// window, dead AX reference), leave the native drag alone rather than
    /// stranding the window with neither side actually moving it.
    private func handleMouseDragged(to point: CGPoint) -> Bool {
        switch state {
        case .idle, .dragging:
            return false // no row for these — the native OS drag continues untouched

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
            return false

        case .anchored(let candidate, let anchor):
            let rect = coveringRect(candidate: candidate, anchor: anchor, at: point)
            let publicState = state.publicState
            onMainRunLoop { [overlay] in overlay.updateSelection(rect: rect, state: publicState) }
            guard liveResizeEnabled else { return false }
            return windowControl.setFrame(rect, of: candidate.window)

        case .freeResize(let candidate, let anchorPoint):
            let rect = GridEngine.freeResizeRect(from: anchorPoint, to: point)
            let publicState = state.publicState
            onMainRunLoop { [overlay] in overlay.updateSelection(rect: rect, state: publicState) }
            guard liveResizeEnabled else { return false }
            return windowControl.setFrame(rect, of: candidate.window)
        }
    }

    /// §3 table's `leftMouseUp` rows: the ordinary-click discard, the
    /// cancel path, and the two commit paths (§5).
    ///
    /// Returns whether to swallow this final event — mirrors
    /// `handleMouseDragged`'s return, and for the same reason, but only
    /// matters here for `.anchored`/`.freeResize` with live-resize on: for
    /// the entire drag we've been suppressing `leftMouseDragged` so
    /// WindowServer's native drag-follow can't fight our AX writes (see
    /// that method's doc comment). Real bug found via manual testing: since
    /// the *final* mouse-up was never suppressed, WindowServer would
    /// perform one last native repositioning on it — jumping the window
    /// toward the cursor's current position — immediately undoing the
    /// correct final frame we'd just set below. Swallowing it too, under
    /// the exact same condition, closes that gap. Every other case here
    /// (idle/dragging/cancel, or commit with live-resize off) never
    /// suppresses: the native drag was never interrupted for those, so it
    /// needs its own unmodified mouse-up to end its tracking cleanly.
    private func handleMouseUp(at point: CGPoint) -> Bool {
        switch state {
        case .idle:
            return false

        case .dragging:
            // Ordinary click/drag the OS already handled; discard candidate.
            state = .idle
            return false

        case .gridActive(let candidate):
            // Cancel: leftMouseUp arriving in .gridActive means Option is
            // still held (an Option release would already have moved us to
            // .anchored) — exactly the table's "leftMouseUp (⌥ still held)" row.
            windowControl.setFrame(candidate.originalFrame, of: candidate.window)
            onMainRunLoop { [overlay] in overlay.hide() }
            state = .idle
            return false

        case .anchored(let candidate, let anchor):
            let finalRect = coveringRect(candidate: candidate, anchor: anchor, at: point)
            let tookOverFrame = windowControl.setFrame(finalRect, of: candidate.window)
            onMainRunLoop { [overlay] in overlay.hide() }
            state = .idle
            return liveResizeEnabled && tookOverFrame

        case .freeResize(let candidate, let anchorPoint):
            let finalRect = GridEngine.freeResizeRect(from: anchorPoint, to: point)
            let tookOverFrame = windowControl.setFrame(finalRect, of: candidate.window)
            onMainRunLoop { [overlay] in overlay.hide() }
            state = .idle
            return liveResizeEnabled && tookOverFrame
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
