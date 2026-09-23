import Combine
import Foundation
import SwiftUI

extension SettingsStore {
    /// Shared by both grid dimensions. 1 rules out a degenerate zero-column
    /// or zero-row grid (a real crash/nonsense-math risk downstream in
    /// GridEngine, not just a UI concern). 12 caps cell count at something
    /// still usable on a laptop display — WindowGrid's own default topped
    /// out at 12x6.
    public static let dimensionRange = 1...12

    /// Floor of 0.1 (not 0.0) so the overlay can never be dialed to fully
    /// invisible-but-still-active mid-gesture, which would be confusing.
    public static let opacityRange = 0.1...1.0
}

/// Single source of truth for every user-configurable setting in MacGriddle.
/// `ObservableObject` so SwiftUI views update live; every property also has
/// a manual `didSet` that clamps (where relevant) and persists to
/// `UserDefaults`. Hand-written instead of `@AppStorage` because
/// `@AppStorage` can neither validate/clamp on write nor hand a Combine
/// publisher to plain (non-View) code — both of which the composition root
/// needs.
///
/// Owned by the composition root as a single long-lived instance for the
/// app's lifetime — not a singleton, just constructed once and injected
/// wherever it's needed.
public final class SettingsStore: ObservableObject {

    // MARK: Grid

    @Published public var gridColumns: Int {
        didSet { persistGridColumns() }
    }

    @Published public var gridRows: Int {
        didSet { persistGridRows() }
    }

    // MARK: Behavior

    /// `false` = snap-on-release (the v1 default): the window stays put
    /// until mouse-up, then one clean resize is applied. `true` =
    /// continuously resize the real window during the drag — opt-in, since
    /// this is what corrupts Electron/Chromium redraw paths.
    @Published public var liveResizeEnabled: Bool {
        didSet { userDefaults.set(liveResizeEnabled, forKey: Keys.liveResizeEnabled) }
    }

    /// Persists intent *and* makes the real `SMAppService` call — per
    /// project-structure.md §4, that call belongs here (triggered directly
    /// by the settings toggle changing), never in the composition root.
    @Published public var launchAtLoginEnabled: Bool {
        didSet { persistLaunchAtLogin() }
    }

    // MARK: Appearance

    /// Thin grid-line color, drawn for every cell boundary. Default: a
    /// mostly-transparent white, so lines read clearly on both light and
    /// dark desktop backgrounds without dominating the screen.
    @Published public var cellStrokeColor: Color {
        didSet { userDefaults.set(cellStrokeColor.toHexString(), forKey: Keys.cellStrokeColor) }
    }

    /// Fill for the live selection/preview rectangle. Default: translucent
    /// blue — the alpha baked into this color is its *own* translucency,
    /// independent of `overlayOpacity` below.
    @Published public var selectionFillColor: Color {
        didSet { userDefaults.set(selectionFillColor.toHexString(), forKey: Keys.selectionFillColor) }
    }

    /// Border stroke for the selection/preview rectangle. Default: a
    /// near-opaque version of the same blue, so the covering rectangle's
    /// edges stay crisp even when the fill is very translucent.
    @Published public var selectionStrokeColor: Color {
        didSet { userDefaults.set(selectionStrokeColor.toHexString(), forKey: Keys.selectionStrokeColor) }
    }

    /// Master opacity dial for the *entire* overlay, multiplied on top of
    /// each color's own alpha by the Overlay renderer. Lets a user dim the
    /// whole grid with one slider instead of re-tuning three color pickers.
    @Published public var overlayOpacity: Double {
        didSet { userDefaults.set(overlayOpacity, forKey: Keys.overlayOpacity) }
    }

    // MARK: Read-only

    /// Not user-editable in this release (registered in `Input`). Surfaced
    /// here purely so the About tab can display it. Deliberately a plain
    /// `let`, not `@Published`: it never changes at runtime, so it isn't
    /// part of the persisted/observable settings surface.
    public let panicHotkeyDisplayString = "⌃⌥⇧Escape"

    // MARK: Storage

    private let userDefaults: UserDefaults

    /// `userDefaults` is an injectable dependency (defaulting to `.standard`)
    /// specifically so a future test target could construct a store against
    /// `UserDefaults(suiteName: "test")` instead of polluting the real
    /// domain — no test target exists for this chunk yet, but the seam
    /// costs nothing to leave in place.
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // NOTE: none of these properties have an inline default value at
        // declaration, and each is assigned exactly once below. That's
        // deliberate, not an oversight: Swift never calls willSet/didSet
        // for the assignment that satisfies an initializer's
        // definite-initialization requirement, but whether a *combination*
        // of an inline default and a later reassignment inside init fires
        // didSet is a genuinely murky corner of the language. Giving every
        // property no inline default and exactly one assignment here (with
        // clamping/defaulting folded into that single expression) makes the
        // behavior unambiguous by construction: didSet never fires while
        // loading, and always fires for every mutation afterwards (UI
        // edits, resetToDefaults(), or any other caller).
        gridColumns = Self.dimensionRange.clamped(
            userDefaults.object(forKey: Keys.gridColumns) as? Int ?? Defaults.gridColumns
        )
        gridRows = Self.dimensionRange.clamped(
            userDefaults.object(forKey: Keys.gridRows) as? Int ?? Defaults.gridRows
        )
        liveResizeEnabled = userDefaults.object(forKey: Keys.liveResizeEnabled) as? Bool
            ?? Defaults.liveResizeEnabled
        launchAtLoginEnabled = userDefaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool
            ?? Defaults.launchAtLoginEnabled
        cellStrokeColor = Color(hex: userDefaults.string(forKey: Keys.cellStrokeColor) ?? "")
            ?? Defaults.cellStrokeColor
        selectionFillColor = Color(hex: userDefaults.string(forKey: Keys.selectionFillColor) ?? "")
            ?? Defaults.selectionFillColor
        selectionStrokeColor = Color(hex: userDefaults.string(forKey: Keys.selectionStrokeColor) ?? "")
            ?? Defaults.selectionStrokeColor
        overlayOpacity = Self.opacityRange.clamped(
            userDefaults.object(forKey: Keys.overlayOpacity) as? Double ?? Defaults.overlayOpacity
        )
    }

    /// Restores every setting to its shipped default in one call — used by
    /// the "Restore Defaults" button in `PreferencesView`. Each assignment
    /// still goes through its own `didSet`, so this both re-persists to
    /// `UserDefaults` *and* re-notifies any Combine subscriber (e.g. the
    /// composition root's launch-at-login observer) exactly as if the user
    /// had changed each control by hand — no separate code path to keep in
    /// sync.
    public func resetToDefaults() {
        gridColumns = Defaults.gridColumns
        gridRows = Defaults.gridRows
        liveResizeEnabled = Defaults.liveResizeEnabled
        launchAtLoginEnabled = Defaults.launchAtLoginEnabled
        cellStrokeColor = Defaults.cellStrokeColor
        selectionFillColor = Defaults.selectionFillColor
        selectionStrokeColor = Defaults.selectionStrokeColor
        overlayOpacity = Defaults.overlayOpacity
    }

    private func persistGridColumns() {
        let clamped = Self.dimensionRange.clamped(gridColumns)
        if clamped != gridColumns {
            gridColumns = clamped // re-enters didSet once, then settles below
            return
        }
        userDefaults.set(gridColumns, forKey: Keys.gridColumns)
    }

    private func persistGridRows() {
        let clamped = Self.dimensionRange.clamped(gridRows)
        if clamped != gridRows {
            gridRows = clamped
            return
        }
        userDefaults.set(gridRows, forKey: Keys.gridRows)
    }

    /// Guards against a redundant second `LaunchAtLogin.setEnabled(...)`
    /// call on the reconciliation pass below — unlike
    /// `persistGridColumns`/`persistGridRows` (whose corrective re-entry
    /// only repeats a plain `UserDefaults.set`), this property's corrective
    /// re-entry would otherwise also repeat the fallible system call with a
    /// value that has already just been read back from the live system,
    /// which is a redundant no-op attempt, not a fix.
    private var isReconcilingLaunchAtLogin = false

    private func persistLaunchAtLogin() {
        userDefaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled)
        guard !isReconcilingLaunchAtLogin else { return }

        do {
            try LaunchAtLogin.setEnabled(launchAtLoginEnabled)
        } catch {
            // Registration can fail (e.g. the user removed it from Login
            // Items mid-session) — resync to whatever SMAppService actually
            // reports rather than trusting the just-attempted value. The
            // guard above ensures this reassignment's own re-entrant
            // didSet persists the corrected value but does not attempt
            // setEnabled(...) again.
            let actual = LaunchAtLogin.isEnabled
            if actual != launchAtLoginEnabled {
                isReconcilingLaunchAtLogin = true
                launchAtLoginEnabled = actual
                isReconcilingLaunchAtLogin = false
            }
        }
    }
}

private enum Keys {
    static let gridColumns = "gridColumns"
    static let gridRows = "gridRows"
    static let liveResizeEnabled = "liveResizeEnabled"
    static let launchAtLoginEnabled = "launchAtLoginEnabled"
    static let cellStrokeColor = "cellStrokeColorHex"
    static let selectionFillColor = "selectionFillColorHex"
    static let selectionStrokeColor = "selectionStrokeColorHex"
    static let overlayOpacity = "overlayOpacity"
}

private enum Defaults {
    static let gridColumns = 6
    static let gridRows = 4
    static let liveResizeEnabled = false
    static let launchAtLoginEnabled = false
    static let overlayOpacity = 1.0
    static let cellStrokeColor = Color.white.opacity(0.6)
    static let selectionFillColor = Color.blue.opacity(0.25)
    static let selectionStrokeColor = Color.blue.opacity(0.9)
}

private extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int { min(max(value, lowerBound), upperBound) }
}

private extension ClosedRange where Bound == Double {
    func clamped(_ value: Double) -> Double { min(max(value, lowerBound), upperBound) }
}
