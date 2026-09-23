# Core Contracts (`MacGriddleCore`)

Chunk 2 of 10. Covers the `MacGriddleCore` target: the shared protocols/types every other
module codes against. No dependencies — this is the one target every other target may
depend on, and it must never depend on them.

## A note on how this chunk was actually written

The original 10-chunk run crashed after 7 of 10 completed (`project-structure.md`,
`permissions-model.md`, `window-control-and-coordinates.md`, `overlay-rendering.md`,
`app-shell-and-lifecycle.md`, `preferences-ui.md`, `statusbar-menu.md`). This chunk —
along with `grid-engine.md` and `input-engine-and-state-machine.md` — is being written to
fill the gap, **with full visibility into all 7 completed chunks**, rather than in
parallel/blind the way the original plan intended. That changes this document's job: instead
of an independent best-guess later reconciled by a combiner, this is written as the
**authoritative, reconciled** version, chosen specifically to match what the 7 existing
chunks already assumed and wrote code against wherever they agreed, and to make an explicit,
flagged call wherever they didn't. Section 8 ("Reconciliation") lists every point where an
existing chunk's code needs a small, mechanical fixup (a rename, an added method) to line up
with what's defined here — none of it requires rethinking any existing chunk's design.

---

## 1. `GestureState`

```swift
/// The phase of an in-progress (or not-in-progress) grid gesture, as seen
/// by modules that only need to react to *which phase*, not the private
/// details of how Input got there. This is deliberately minimal — Input's
/// own internal state machine (input-engine-and-state-machine.md) carries
/// much richer data (which window, its original frame, the anchor cell);
/// none of that belongs here because Overlay — the only other consumer —
/// never unpacks anything beyond the case itself.
public enum GestureState: Equatable {
    case idle
    case dragging
    case gridActive
    case anchored
    case freeResize
    case committed
    case cancelled
}
```

**Why no associated values.** `overlay-rendering.md` (chunk 7) was written against exactly
this case list and explicitly designed to "never unpack associated values... all geometry
`Overlay` needs arrives pre-computed via the `rect:` parameter on `updateSelection`." Adding
associated values here would cost real complexity (e.g. forcing `WindowHandle` to be
`Equatable` just so `GestureState` itself could be — see §3) for zero benefit to the one
module that consumes this type. `input-engine-and-state-machine.md` (chunk 4) has its own
private, richer state representation and translates to this public enum only at the two
seams that need it (calls into `Overlay`).

**Why `.committed`/`.cancelled` exist despite `Overlay.hide()` taking no state parameter.**
`overlay-rendering.md`'s `GridOverlayRendering` protocol is `show(configuration:state:)`,
`updateSelection(rect:state:)`, `hide()` — note `hide()` takes no `state:` argument at all.
Its own `shouldShowGridLines`/`isFreeResize` switches are still written to exhaustively cover
`.committed`/`.cancelled` as real cases (mapped to "don't show grid lines"). These two cases
are kept in the enum for exactly that exhaustiveness/lifecycle-documentation purpose;
`input-engine-and-state-machine.md`'s real implementation calls `overlay.hide()` directly on
both commit and cancel and never actually needs to construct a `GestureState.committed` or
`.cancelled` value to do so. Not a contradiction — just two cases that exist for a different
consumer's switch-completeness than for any live data flow.

---

## 2. `GridConfiguration` — **lives in `GridEngine`, not here**

`overview.md`'s chunk-2 description assigns `GridConfiguration` to this document. Overriding
that: it must live in the `GridEngine` target instead, defined in `grid-engine.md` (chunk 6).

**Why.** `project-structure.md` (chunk 1) fixed `GridEngine`'s `Package.swift` dependencies as
`[]` — deliberately zero, not even `MacGriddleCore` — specifically so `GridEngineTests` can
exercise pure grid math with nothing else in the graph. `GridEngine`'s own public API
(`cellRect(column:row:in:screenFrame:)`, per `overlay-rendering.md`'s already-written call
site) takes a `GridConfiguration` as a parameter. A type used in a zero-dependency target's
public API must be declared inside that same target — if `GridConfiguration` lived here in
`MacGriddleCore`, `GridEngine` would need to depend on `Core` to see it, contradicting the
fixed, deliberate "zero dependencies" decision in `project-structure.md`. Moving the type,
not the dependency, is the smaller change: `GridConfiguration` is plain data
(`columns: Int, rows: Int`) with no reason to need anything `Core` provides.

**Confirmed unaffected by this move:** every target that needs `GridConfiguration`
already depends on `GridEngine` directly per the fixed table (`Overlay`: Core+GridEngine;
`Input`: Core+GridEngine+...; the `MacGriddle` executable: everything). `Preferences` never
needs the type itself — it only stores raw `gridColumns`/`gridRows` integers
(`preferences-ui.md` §2); the composition root builds the real `GridConfiguration` value.
No target's dependency list needs to change — only the type's physical location, and only
one chunk (`overlay-rendering.md`) ever wrote a call site against it, which already assumed
correctly that it comes from `GridEngine`'s neighborhood, not `Core`'s.

---

## 3. `WindowHandle` and `WindowControlling`

Adopted essentially verbatim from `window-control-and-coordinates.md` (chunk 5), which
designed this in the most detail of any of the 7 completed chunks and is the target that
actually implements it. Two of that chunk's own open questions are settled explicitly below.

```swift
import ApplicationServices

/// Opaque, cross-module reference to a single window, owned by whichever
/// application exposes it. `WindowControl` is the only target that should
/// ever read `.axElement`; every other target treats `WindowHandle` as an
/// opaque value it passes around, not something it introspects.
public struct WindowHandle: Equatable {
    public let axElement: AXUIElement

    public init(axElement: AXUIElement) {
        self.axElement = axElement
    }

    /// `AXUIElement` does not conform to `Equatable` on its own — it is a
    /// `CFTypeRef` under the hood, and `CFEqual` is the correct way to
    /// compare two references for referring to the same accessibility
    /// object. Needed by `input-engine-and-state-machine.md`'s state
    /// machine to confirm "the window I started this gesture on is still
    /// the one I'm about to commit a resize on" — window-control-and-
    /// coordinates.md flagged this as worth deciding explicitly rather than
    /// guessing; this is that decision.
    public static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
}

/// Every function operates in Quartz (global-display, top-left-origin,
/// Y-down) screen coordinates — the same space `AXUIElement` and
/// `CGEventTap` both already agree on natively. See §7.
public protocol WindowControlling {
    func window(at point: CGPoint) -> WindowHandle?
    func frame(of window: WindowHandle) -> CGRect?

    @discardableResult
    func setFrame(_ frame: CGRect, of window: WindowHandle) -> Bool
}
```

Decisions on `window-control-and-coordinates.md`'s open questions (its "Consolidated open
questions for `core-contracts.md`" section):

1. **Method names/labels**: confirmed exactly as that chunk wrote them —
   `window(at:)`, `frame(of:)`, `setFrame(_:of:)`. (`app-shell-and-lifecycle.md` guessed
   `windowUnderCursor(at:)` instead — see §8, a one-line rename.)
2. **Failure signaling**: confirmed `Bool`, not `throws` — matches `RESEARCH.md`'s own
   sample code and every AX call site already written in chunk 5.
3. **`WindowHandle`'s shape**: confirmed bare wrapper, single `AXUIElement`, public
   initializer (chunk 5's own reasoning: `WindowControl` mints instances from freshly
   resolved elements; other targets only ever receive and pass existing ones).
4. **`pid_t` caching**: not added. Nothing in any of the 7 completed chunks' designs needs
   it; adding unused state is exactly the kind of premature generality this project's own
   `preferences-ui.md` and `overlay-rendering.md` chunks both explicitly declined elsewhere.
   If a future feature needs "is this the same app," `AXUIElementGetPid` is cheap to call
   on-demand from the wrapped `axElement` — no need to cache it now.
5. **`Equatable`/`Hashable`**: `Equatable` added (above), via `CFEqual`, for the reason
   given. `Hashable` is **not** added — nothing in any of the 7 completed chunks, nor the two
   chunks being written alongside this one, needs to put a `WindowHandle` in a `Set` or use
   it as a dictionary key. Add it later, the same way, with `CFHash`, if that need arises.
6. **Opaque-handle redesign**: not adopted, per chunk 5's own recommendation — the added
   encapsulation isn't worth the live-handle-cache complexity nothing here calls for.

---

## 4. `PermissionsProviding`

This is the one contract where the 7 completed chunks genuinely disagree, not just guess at
unconfirmed names. Three different chunks assumed three different shapes:

| Chunk | Assumed shape |
|---|---|
| `permissions-model.md` (chunk 3 — the actual implementer) | `ObservableObject`-conforming protocol; `isAccessibilityGranted`/`isInputMonitoringGranted` properties; `requestAccessibility()`/`requestInputMonitoring()`/`refreshStatus()` methods (request methods return `Void`, deliberately — see that chunk's §3 callout) |
| `statusbar-menu.md` (chunk 10) | Class-bound protocol; same two boolean names; **no** request methods (explicitly declined to guess them); a separate `AnyPublisher<Bool, Never>` per flag instead of relying on `ObservableObject` |
| `app-shell-and-lifecycle.md` (chunk 8) | Different property names (`isAccessibilityTrusted`/`isInputMonitoringTrusted`); an additional `isFullyPermitted` computed property; a single combined `permissionsChanged: AnyPublisher<Void, Never>` instead of per-flag publishers |

**Resolution: chunk 3's shape is authoritative** (it is the chunk that actually implements
`PermissionsMonitor` against it, with working, detailed polling/observing logic already
written) — **extended, not replaced**, with two small protocol-extension additions that let
chunk 8 and chunk 10 each get what they need without contradicting chunk 3's design or
requiring its `PermissionsMonitor` implementation to change at all:

```swift
import Combine

public protocol PermissionsProviding: ObservableObject {
    var isAccessibilityGranted: Bool { get }
    var isInputMonitoringGranted: Bool { get }

    /// Void by design, not Bool — see permissions-model.md §3's callout.
    /// The underlying AXIsProcessTrustedWithOptions/CGRequestListenEventAccess
    /// calls return a Bool that reflects trust state at the instant of the
    /// call, before the user has acted on the system prompt it just
    /// triggered. Exposing that value here would invite callers to
    /// misinterpret it as "the user granted it." The real answer arrives
    /// later, through isAccessibilityGranted/isInputMonitoringGranted.
    func requestAccessibility()
    func requestInputMonitoring()
    func refreshStatus()
}

extension PermissionsProviding {
    /// Added for app-shell-and-lifecycle.md's composition-root gate
    /// ("if permissions.isFullyPermitted { proceedPastPermissions() }
    /// else { presentOnboarding() }") and permissions-model.md §5's own
    /// stated rule that partial-grant states are exactly as non-functional
    /// as no grant at all. A default implementation on the protocol, not a
    /// stored property PermissionsMonitor has to maintain separately —
    /// it can never drift out of sync with the two booleans it derives from.
    public var isFullyPermitted: Bool {
        isAccessibilityGranted && isInputMonitoringGranted
    }
}
```

For statusbar-menu.md's per-flag publisher need and app-shell-and-lifecycle.md's combined
publisher need: rather than adding either shape directly to the protocol (which would force
every conformer, including test doubles, to hand-build Combine publishers), both are covered
by requiring `ObservableObject` conformance and letting callers derive what they need from
the standard `objectWillChange`/`$property` machinery that conformance already provides for
free:

- **Per-flag** (`statusbar-menu.md`): a conforming class with
  `@Published private(set) var isAccessibilityGranted: Bool` (exactly what
  `permissions-model.md`'s `PermissionsMonitor` already declares) exposes
  `$isAccessibilityGranted` as a `Published<Bool>.Publisher` for free — callers that want
  `AnyPublisher<Bool, Never>` call `.eraseToAnyPublisher()` at the use site. No protocol
  requirement needed.
- **Combined** (`app-shell-and-lifecycle.md`): `Publishers.CombineLatest(provider.$isAccessibilityGranted, provider.$isInputMonitoringGranted).map { _ in () }.eraseToAnyPublisher()`
  built once at the composition root and named locally (e.g. `permissionsChanged`) — a
  one-line derivation, not a protocol requirement.

This keeps `PermissionsProviding` itself small (matching `permissions-model.md`'s original
design intent) while both consumers get what they wrote code against, via ordinary Combine
composition at the call site rather than new protocol surface. See §8 for the exact
call-site fixups this implies in chunks 8 and 10.

**Naming**: standardized on `isAccessibilityGranted`/`isInputMonitoringGranted` (two of the
three chunks already agree; `app-shell-and-lifecycle.md`'s `isAccessibilityTrusted`/
`isInputMonitoringTrusted` needs a rename — see §8).

---

## 5. `OverlayAppearance` — a gap discovered while reconciling, not in `overview.md`'s original chunk-2 list

Both `overlay-rendering.md` (chunk 7) and `preferences-ui.md` (chunk 9) reference an
`OverlayAppearance` type extensively — chunk 7 as a constructor parameter to
`GridOverlayController` and to `applyAppearance(_:)`; chunk 9 as something the composition
root builds from `SettingsStore`'s SwiftUI `Color` values. **Neither chunk actually defines
it** — chunk 7 explicitly guesses at its shape "from `preferences-ui.md`, sibling, not
visible," and chunk 9's own reference is an illustrative composition-root snippet, not a
declaration. Without this being defined somewhere both `Overlay` (depends on Core+GridEngine)
and the composition root (depends on everything) can reach, chunk 7's code as written does
not compile. Resolution: define it here, in `Core`, matching chunk 7's more detailed,
already-consumed field names (chunk 9's illustrative init call used slightly shorter labels —
see §8):

```swift
import AppKit

/// AppKit types only (NSColor, not SwiftUI Color) — Overlay has no SwiftUI
/// dependency and never should; the composition root does the Color→NSColor
/// conversion once, when reading from SettingsStore (preferences-ui.md §6).
public struct OverlayAppearance: Equatable {
    public let cellStrokeColor: NSColor
    public let selectionFillColor: NSColor
    public let selectionStrokeColor: NSColor

    /// Multiplies on top of each color's own alpha, as a single master
    /// dial. See overlay-rendering.md §1 (applied as the overlay NSWindow's
    /// own `alphaValue`) for how this is actually used, and
    /// preferences-ui.md §2 for its persisted bounds (0.1...1.0).
    public let opacity: Double

    public init(
        cellStrokeColor: NSColor,
        selectionFillColor: NSColor,
        selectionStrokeColor: NSColor,
        opacity: Double
    ) {
        self.cellStrokeColor = cellStrokeColor
        self.selectionFillColor = selectionFillColor
        self.selectionStrokeColor = selectionStrokeColor
        self.opacity = opacity
    }
}
```

Exactly the four fields chunk 7 assumed and no more (it explicitly avoided guessing at
additional fields like stroke widths, hardcoding those as internal constants instead — this
document does not add any either, for the same reason: nothing in any completed chunk asks
for them).

---

## 6. `ScreenSpace` — the Cocoa↔Quartz coordinate utility (relocated here from `WindowControl`)

`window-control-and-coordinates.md` (chunk 5) defined a `ScreenSpace` enum with this exact
utility, but declared it locally within the `WindowControl` target. That's a real problem:
`overlay-rendering.md` (chunk 7) also needs this conversion (to compute each overlay
window's `quartzFrame`/`quartzOrigin`), but `Overlay`'s fixed dependencies are `Core` +
`GridEngine` only — **not** `WindowControl`. If this utility stayed inside `WindowControl`,
chunk 7's code could not compile; there is no dependency edge from `Overlay` to
`WindowControl` in the fixed target table, and adding one isn't warranted just for this.

**Resolution: moved to `Core`**, since it's the only placement both `WindowControl` (which
already depends on `Core`) and `Overlay` (`Core` + `GridEngine`) can reach without a new
dependency edge. Chunk 5's exact API (both rect and point overloads, more complete than
`RESEARCH.md`'s single-function sketch) is kept verbatim, plus one addition: `RESEARCH.md`
§B.3.1 itself names this function `flippedRect(_:primaryScreenHeight:)`, and
`overlay-rendering.md` guessed exactly that name (just under the wrong enclosing namespace,
`CoordinateSpace` instead of `ScreenSpace`) — so `flippedRect` is kept as a same-namespace
alias, purely so chunk 7's existing call site needs only a one-word namespace fix (see §8),
not a function-name change too.

```swift
import AppKit

public enum ScreenSpace {
    /// The height of the PRIMARY screen (`NSScreen.screens[0]`) — Quartz's
    /// global coordinate origin is defined relative to this display, and it
    /// is NOT necessarily the screen under the cursor or the one with the
    /// key window. Deliberately not cached: screen arrangement can change
    /// at runtime, and a stale cached value is exactly the bug this type
    /// exists to prevent — every conversion function takes this as a
    /// required argument rather than defaulting it.
    public static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    public static func cocoaToQuartz(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The transform is its own inverse — identical arithmetic to
    /// `cocoaToQuartz`, kept as a separately named function so each call
    /// site reads correctly for the direction it means.
    public static func quartzToCocoa(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    public static func cocoaToQuartz(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    public static func quartzToCocoa(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Alias for `cocoaToQuartz(_:primaryScreenHeight:)` (rect overload),
    /// matching RESEARCH.md §B.3.1's own function name exactly. Exists so
    /// overlay-rendering.md's `CoordinateSpace.flippedRect(...)` call site
    /// needs only a namespace rename (`CoordinateSpace` → `ScreenSpace`),
    /// not a function-name change — the transform is the same either
    /// direction (see above), so there is no correctness difference between
    /// calling this or `cocoaToQuartz` directly.
    public static func flippedRect(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        cocoaToQuartz(rect, primaryScreenHeight: primaryScreenHeight)
    }
}
```

---

## 7. Coordinate-space contract, restated for this document's authority

Every type in §3–§6 operates in **Quartz** (global-display, top-left-origin, Y-down) screen
space: `WindowControlling`'s `CGPoint`/`CGRect` parameters, `WindowHandle`'s underlying AX
frame data, and the space `ScreenSpace` converts *into* from Cocoa. This is not a new
decision — it restates `overview.md`'s fixed cross-cutting choice and `RESEARCH.md` §B.3 —
stated here because `Core` is where every module reads the contract from.

---

## 8. Reconciliation — exact fixups needed in the 7 completed chunks

None of these require rethinking any existing chunk's design — every one is a rename or a
small addition, listed here so whoever integrates the full package can apply them
mechanically rather than re-deriving them:

| Chunk | Fixup needed |
|---|---|
| `app-shell-and-lifecycle.md` | Rename `isAccessibilityTrusted`/`isInputMonitoringTrusted` → `isAccessibilityGranted`/`isInputMonitoringGranted` (§4). Build `permissionsChanged` locally via `Publishers.CombineLatest` (§4) rather than expecting it on the protocol. Rename `windowUnderCursor(at:)` → `window(at:)` (§3, item 1). |
| `statusbar-menu.md` | Derive `isAccessibilityGrantedPublisher`/`isInputMonitoringGrantedPublisher` locally via `provider.$isAccessibilityGranted.eraseToAnyPublisher()` (§4) rather than expecting them on the protocol — the rest of that chunk's `Publishers.CombineLatest3` subscription code is unaffected, it just now sources two of its three inputs from a locally-erased publisher instead of a protocol-vended one. |
| `permissions-model.md` | No code changes — its assumed `PermissionsProviding` shape is the one this document adopted as authoritative. Its `PermissionsMonitor` class already satisfies the protocol in §4 as written. |
| `window-control-and-coordinates.md` | Delete its local `ScreenSpace` enum definition (§4 of that chunk) — it now lives in `Core` (§6 here) and `WindowControl` gets it via its existing `Core` dependency. No call-site changes: the API is identical, just relocated. |
| `overlay-rendering.md` | Rename `CoordinateSpace.flippedRect(...)` → `ScreenSpace.flippedRect(...)` (§6) — one word, same function. `GridEngine.cellRect(column:row:in:screenFrame:)` call site is unaffected (confirmed exact match — see `grid-engine.md`). |
| `preferences-ui.md` | Its illustrative composition-root snippet's `OverlayAppearance(cellStroke:selectionFill:selectionStroke:opacity:)` call uses shorter labels than §5's `cellStrokeColor`/`selectionFillColor`/`selectionStrokeColor` — update the illustrative call to match; not a design change, that snippet was always marked illustrative-only. |
| `project-structure.md` | None. Its `Package.swift` target/dependency graph is unchanged by anything in this document — `GridConfiguration` moving into `GridEngine` (§2) and `ScreenSpace`/`OverlayAppearance` living in `Core` (§5, §6) were already exactly where the fixed dependency edges expect these concerns to sit. |

---

## Handoff to the other two in-progress chunks

- **`grid-engine.md`**: owns `GridConfiguration` and a `GridCell` position type (§2) — both
  living in `GridEngine`, not here, for the reason given. Its `cellRect`/hit-test/covering-rect
  functions should take/return Quartz-space `CGRect`/`CGPoint` per §7, consistent with every
  other module.
- **`input-engine-and-state-machine.md`**: consumes `WindowControlling`/`WindowHandle` (§3),
  `PermissionsProviding` (§4, including the `isFullyPermitted` extension), translates its own
  richer internal state to the public `GestureState` (§1) at the two call sites into
  `Overlay`, and is the natural home for the `screen(containing:)` helper
  `window-control-and-coordinates.md` §4 sketched but didn't claim ownership of (it needs
  `ScreenSpace`, now in `Core`, to implement it).
