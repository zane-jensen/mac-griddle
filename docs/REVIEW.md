# MacGriddle Independent Review

**Reviewer stance:** independent re-verification. Nothing in this document is taken on the
integration pass's word — every build/test claim below was re-run from a clean `.build/`
directory by this reviewer, and every code claim was checked by reading the actual source
line cited, not by trusting a prior summary. All 36 Swift files under `Sources/` (35) and
`Tests/` (1) were read in full, plus `Package.swift` and all 11 files in
`docs/architecture/chunks/` (the original 10-chunk plan plus the later
`composition-root-wiring-fixups.md`).

Scope note: only `docs/REVIEW.md` was written. No file under `Sources/` or `Tests/` was
modified.

---

## 1. Build and test verification

Re-run independently from a clean `.build/` (`rm -rf .build` first) on
Swift 6.4 (swiftlang-6.4.0.34.1), macOS 26.6.2, arm64.

| Command | Result |
|---|---|
| `swift build` | **Build complete! (9.10 sec)**. 0 errors. 12 warning call sites (see below). |
| `swift build -c release` | **Build complete! (6.39 sec)**. 0 errors. Same warning categories. |
| `swift test` | **Executed 15 tests, with 0 failures (0 unexpected)** in `GridEngineTests`, plus an empty (0-test) Swift Testing run. All 15 pass. |

The integration pass's "build is clean" claim is **confirmed independently**, not just
repeated.

### Warnings beyond the two accepted categories

Ran `swift build 2>&1 | grep -i warning` and separately grepped the full clean-build log for
every unique `warning:` site. **12 total warning call sites, all falling into exactly the two
pre-accepted categories — no other warning type exists in the project.**

`#ExistentialAny` (bare protocol type used instead of `any PermissionsProviding`) — 8 sites:
- `Sources/Input/InputEngine.swift:16`, `:27`
- `Sources/StatusBar/StatusBarController.swift:24`, `:92`
- `Sources/MacGriddle/AppDelegate.swift:38`
- `Sources/MacGriddle/OnboardingCoordinator.swift:36`, `:41`, `:120`

`ClosedRange`/global `min`/`max` shadowing (`#deprecation`) — 4 sites, all in
`Sources/Preferences/SettingsStore.swift:219` (×2, `min`/`max`) and `:223` (×2, `min`/`max`).

**Verdict: PASS.** Build and tests are genuinely clean; no undisclosed warning class exists.

---

## 2. Gesture state machine fidelity (`Sources/Input/InputEngine.swift`)

Cross-checked `handle(type:event:)` (lines 82–98) and its five per-event handlers against
`docs/RESEARCH.md` Part A's 8-step spec and `input-engine-and-state-machine.md` §3's
transition table, transition by transition.

- **Cancel path** (`handleMouseUp`, `.gridActive` case, lines 175–181): on mouse-up while
  Option is still held, calls `windowControl.setFrame(candidate.originalFrame, of:
  candidate.window)` — `candidate.originalFrame` is captured once at `handleMouseDown`
  (line 116, `windowControl.frame(of: window)`) and is never overwritten before this point
  (no `setFrame` call touches the real window between mouse-down and this cancel path in any
  `.dragging`/`.gridActive` state). **Verified correct**: restores the pristine pre-gesture
  frame exactly, matching RESEARCH.md Part A.3 step 6.
- **Commit path** (`handleMouseUp`, `.anchored`/`.freeResize` cases, lines 183–193): computes
  `finalRect` via the shared `coveringRect(candidate:anchor:at:)` helper (lines 258–261) or
  `GridEngine.freeResizeRect`, then calls `windowControl.setFrame` **exactly once**, then
  `overlay.hide()`, then `state = .idle`. Even when `liveResizeEnabled` has already been
  calling `setFrame` continuously during the drag (line 152, 159), the commit call still fires
  unconditionally on top of that, so the last-applied frame is always this single,
  fully-settled computation — matches §6's "guaranteeing the last applied frame is always the
  fully-settled final rect... even if a live-resize call and the mouse-up event raced."
  **Verified correct.**
- **`flagsChanged` anchor-vs-toggle disambiguation** (`handleFlagsChanged`, lines 203–249):
  checked all five `InternalState` cases. `.dragging` requires `optionHeld` to advance to
  `.gridActive` (line 209); `.gridActive` requires `!optionHeld` to advance to `.anchored`
  (line 214, "release ⌥ to anchor"); `.anchored` requires `optionHeld` to advance to
  `.freeResize` (line 229, "tap ⌥ again"); `.freeResize` **also** requires `optionHeld` to
  toggle back to `.anchored` (line 242). This means every subsequent Option **press** edge
  (not release edge) toggles between `.anchored`/`.freeResize` once past the initial anchor —
  release edges in those two states are no-op self-loops. This exactly matches
  `input-engine-and-state-machine.md` §3's own stated rule ("in `.anchored`/`.freeResize`, an
  Option-*pressed* `flagsChanged` means toggle") and is internally consistent for every state.
  **Verified correct** — confirmed this is the documented design, not an accidental asymmetry.
- **Panic hotkey** (`handleKeyDown`, lines 103–106; `forceResetToIdle`, lines 265–272):
  `isPanicHotkey` gates on `⌃⌥⇧Escape` exactly (`PanicHotkey.swift:12,14-17`). Unconditionally
  calls `forceResetToIdle()`, which pattern-matches all four candidate-carrying states
  (`.dragging`/`.gridActive`/`.anchored`/`.freeResize`), restores `candidate.originalFrame` for
  whichever one is active, unconditionally calls `overlay.hide()` (a no-op if already hidden,
  per `GridOverlayController.hide()`'s own `guard isVisible`), and sets `state = .idle`. From
  `.idle` itself, none of the four `if case` branches match, so it degrades to a harmless
  `overlay.hide()` + `state = .idle` no-op. **Verified correct: resets cleanly from every
  state**, matching the transition table's explicit self-loop row for `.idle`.
- **Live-resize vs. snap-on-release** (lines 148–161 for drag, 183–193 for commit): the
  `liveResizeEnabled` flag gates only the *continuous* `setFrame` calls during
  `leftMouseDragged`; the commit-time `setFrame` on mouse-up is unconditional in both modes.
  **Verified correct** per §6.
- **Screen-locking at anchor time, not mouse-down time** (see §7 below — same finding,
  cross-referenced there since it's also one of the checklist-7 questions).

One faithfully-implemented-but-worth-noting nuance: the transition table's `gridActive →
anchored` and `anchored → freeResize` rows list no `overlay` side effect (lines 224, 228 of
`input-engine-and-state-machine.md`'s table), and the real code matches that exactly — neither
`handleFlagsChanged`'s `.gridActive` case (locks screen + sets `.anchored`) nor its `.anchored`
case (sets `.freeResize`) calls into `overlay` at all. The overlay's visual state only catches
up on the *next* `leftMouseDragged` event. This produces no observable glitch today only
because `GridOverlayController.shouldShowGridLines(for:)` treats `.gridActive`/`.anchored`
identically (both show grid lines) — but the anchored→freeResize gap is real: for one frame's
worth of time, the overlay can visually still show a solid, grid-snapped stroke immediately
after the state machine has already moved to `.freeResize`, until the next mouse move.
This matches the letter of the transition table, so it is not a deviation from spec — flagging
only because it's a real (if cosmetic, sub-frame, one-shot) lag inherited directly from the
architecture document's own omission, not something an implementer introduced.

**Verdict: PASS.** No behavioral deviation from either `RESEARCH.md` or the transition table
found.

---

## 3. Coordinate-space correctness

Checked every `CGRect`/`CGPoint` crossing a module boundary in `Sources/WindowControl/`,
`Sources/Overlay/`, and `Sources/Input/`.

- `Sources/MacGriddleCore/ScreenSpace.swift:19`: `primaryScreenHeight()` is
  `NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0`. Grepped the
  entire `Sources/` tree for `NSScreen.main` — **this is the only occurrence in the whole
  codebase**, and it is only a last-resort fallback behind `.screens.first`, triggered only if
  `NSScreen.screens` is literally empty. This is a byte-for-byte match of `RESEARCH.md`
  §B.3.1's own reference implementation, not a violation of the "never use `NSScreen.main`"
  rule — the rule is about using it as the *primary* source, which nothing here does.
  **Verified correct.**
- `Sources/Input/ScreenResolution.swift`: `screen(containing:)` (lines 8–12) converts the
  incoming Quartz point to Cocoa via `ScreenSpace.quartzToCocoa` before comparing against
  `NSScreen.screens` (Cocoa-space `.frame`s) — correct, no space-mixing.
  `screenFrame(containing:)` (lines 19–25) converts the resulting Cocoa frame back to Quartz
  before returning. Every call site in `InputEngine.swift` (mouse-down capture, line 123;
  `.gridActive` hover, line 138; anchor-time lock, line 219) treats the result as Quartz and
  feeds it straight into `GridEngine` calls, which are Quartz-native. **Verified correct.**
- `Sources/Overlay/OverlayWindow.swift:56-58`: `quartzFrame` flips `NSWindow.frame` (always
  Cocoa) through `ScreenSpace.flippedRect`/`ScreenSpace.primaryScreenHeight()` exactly once —
  no double-flip, no direct use of the un-flipped Cocoa frame anywhere else in the type.
  **Verified correct.**
- `Sources/Overlay/GridOverlayContentView.swift`: `isFlipped = true` (line 32) makes the
  view's local space top-left/Y-down, matching Quartz. `rebuildGridLines` (line 61-62) and
  `setSelection` (line 79) both convert a global Quartz rect to local space via a **pure
  translation** (`offsetBy(dx: -quartzOrigin.x, dy: -quartzOrigin.y)`) — no axis flip, which is
  only correct because `isFlipped` already aligned the two spaces' Y direction. **Verified
  correct**, and matches the file's own reasoning in its doc comment.
- `Sources/WindowControl/`: neither `AXWindowController.swift` nor
  `AXWindowController+Frame.swift` references `NSScreen` or performs any Cocoa conversion —
  both work exclusively with AX-native (already-Quartz) points/rects. No mixing risk.
  **Verified correct.**
- `core-contracts.md` §8's reconciliation item ("delete `WindowControl`'s local `ScreenSpace`
  enum... it now lives in `Core`") was checked: **no duplicate `ScreenSpace` definition exists
  anywhere in `Sources/WindowControl/`** — confirmed fully applied.

**Verdict: PASS.** No Cocoa/Quartz mixing found anywhere in the reviewed targets.

---

## 4. AXError / defensive coding discipline (`Sources/WindowControl/`)

Grepped the whole `Sources/` tree for `AXUIElement`/`AXValueGetValue`/`AXValueCreate` — all
real usage is confined to `Sources/WindowControl/AXWindowController.swift` and
`AXWindowController+Frame.swift` (the two other matches, in `MacGriddleCore`, are just the
`AXUIElement` *type* reference on `WindowHandle.axElement` and doc comments — no AX calls
there). This confirms the module-boundary rule ("only `WindowControl` should ever read AX
directly") is respected everywhere else in the codebase.

Every `AXUIElementCopyAttributeValue`/`AXUIElementCopyElementAtPosition`/
`AXUIElementSetAttributeValue`/`AXUIElementIsAttributeSettable` call site is wrapped in a
`guard ... == .success` or `if ... == .success` before its out-parameter is touched:
- `AXWindowController.swift:37-46` (`resolvedWindowElement`), `:67-71`, `:79-82`, `:90-93`,
  `:97-101` (`resolveToWindow`'s three-step walk).
- `AXWindowController+Frame.swift:20-22` (`frame(of:)`'s two attribute reads), `:57-58`
  (`setFrame`'s two attribute writes, both executed unconditionally and combined with `&&`
  only for the return value — matches the documented "don't leave the window in an ambiguous
  partially-applied state" rationale), `:78-79` (`isFrameSettable`).

Grepped for every `as!` in the project — **exactly 4, all in `WindowControl`, all preceded by
a success check on the same statement or the immediately-enclosing `if`/`guard`**:
- `AXWindowController.swift:81`: `(window as! AXUIElement)` — inside
  `if AXUIElementCopyAttributeValue(...) == .success, let window = windowRef { ... }`.
- `AXWindowController.swift:94`: `current = parent as! AXUIElement` — inside
  `guard AXUIElementCopyAttributeValue(...) == .success, let parent = parentRef else { return nil }`.
- `AXWindowController+Frame.swift:26-27`: `positionRef as! AXValue` / `sizeRef as! AXValue` —
  both only reached after the `guard ... == .success` at lines 20-22 already succeeded (Apple's
  documented contract is that a `.success` `AXUIElementCopyAttributeValue` call leaves its
  out-parameter populated and non-nil). This is a verbatim match of `RESEARCH.md` §B.1.3's own
  reference snippet, not an implementation deviation.

No `try!`, and the codebase's one `fatalError` (`PreferencesWindowController.swift:41`, inside
`init?(coder:)`) is the standard, `@available(*, unavailable)`-guarded pattern for disabling
NSCoder-based init on a type with no storyboard/XIB in this project — not a runtime hazard.

**Verdict: PASS.** No unguarded `AXUIElementCopy.../SetAttributeValue` result, and no
force-cast without a preceding success check, anywhere in the project.

---

## 5. Thread-safety / actor-isolation — **CONCERN**

**`GlobalMouseAndModifierTap`'s CGEventTap callback:** the `@convention(c)` callback
(`GlobalMouseAndModifierTap.swift:42-49`) never touches AppKit directly — it retrieves `self`
via `Unmanaged.fromOpaque(refcon).takeUnretainedValue()` (an unretained, non-owning reference,
correct for C-interop) and calls `tapSelf.handle(type:event:)`, which either self-heals a
disabled tap (lines 80-85) or forwards to `InputEngine`'s `handler` closure. Verified the whole
delivery chain runs on the **main thread**, not an arbitrary background thread: the tap's run
loop source is added via `CFRunLoopAddSource(CFRunLoopGetCurrent(), ...)` inside `start()`
(line 56), and `start()` is only ever called from `InputEngine.start()`, which is only ever
called from `AppDelegate.proceedPastPermissions()` (main thread, since `AppDelegate` is
`@MainActor`) or from `InputEngine`'s own permission-retry subscriber — which itself only
fires on the main thread, since `PermissionsMonitor`'s `@Published` properties are only ever
mutated from `didBecomeActiveNotification` (AppKit-delivered on main) or a `RunLoop.main`
timer. So `CFRunLoopGetCurrent()` is always the main run loop in practice, and every
downstream AppKit call this triggers (`Overlay`'s `NSWindow`/`NSAnimationContext` work) does
in fact happen on the main thread today. **No observed off-main-thread UI mutation.**

**`@MainActor` consistency:** grepped for every `@MainActor` in `Sources/` — it appears in
exactly 4 files: `StatusBarController.swift`, `AppDelegate.swift`, `OnboardingCoordinator.swift`
(covering both `OnboardingViewModel` and `OnboardingCoordinator`, declared in the same file),
and `main.swift` (the `MainActor.assumeIsolated { AppDelegate() }` call site). These four are
internally consistent with each other — `AppDelegate` and `StatusBarController` are both
`@MainActor`, so `AppDelegate`'s synchronous calls into `StatusBarController` need no `await`;
same for `AppDelegate`↔`OnboardingCoordinator`.

However, two other types that construct or directly drive AppKit UI are **not** annotated,
unlike the pattern the integration pass otherwise applied:

- **`Sources/Overlay/GridOverlayController.swift`** (no `@MainActor` anywhere in the file):
  this type constructs `OverlayWindow` (an `NSWindow` subclass) N-per-screen on every
  `show()`/`rebuildWindows()` (line 107), drives `NSAnimationContext.runAnimationGroup` for
  fade in/out (lines 127-130, 140-145), and subscribes to
  `NSApplication.didChangeScreenParametersNotification`. It has no `NSObject`/AppKit
  superclass of its own (`final class GridOverlayController: GridOverlayRendering`), so unlike
  `OverlayWindow`/`GridOverlayContentView` (which subclass `NSWindow`/`NSView` and may inherit
  isolation from Apple's own SDK annotations on those base classes), it gets **no implicit
  actor isolation from anywhere**. `GridOverlayRendering` itself (`GridOverlayRendering.swift`)
  is also not `@MainActor`-constrained, so nothing in the type graph stops a future caller from
  invoking `show`/`updateSelection`/`hide` off the main thread and silently corrupting AppKit
  state — there is no compiler safety net here, only the current, undocumented invariant that
  every caller happens to run on the main thread today.
- **`Sources/Permissions/PermissionsMonitor.swift`**: touches `NotificationCenter`/`Timer`/
  `RunLoop.main` but not `NSWindow`/`NSStatusItem` directly, so this is a softer case than
  `GridOverlayController` — noting it for completeness, not as the primary finding.

This is not a bug that manifests today (the CGEventTap's main-run-loop attachment makes the
current call graph safe in practice), but it is a genuine inconsistency: the task brief itself
says the integration pass added `@MainActor` "in several places to fix real actor-isolation
compile errors," and `GridOverlayController` is exactly the kind of NSWindow-constructing type
that pattern should have covered but didn't. Worth fixing before this code is refactored by
someone who doesn't know the CGEventTap-attaches-to-main-run-loop invariant by heart.

**Verdict: CONCERN.** Behaves correctly today; no compiler-enforced safety net protects it if
that changes. `GridOverlayController` should be `@MainActor` for consistency with
`StatusBarController`/`AppDelegate`/`OnboardingCoordinator`/`OnboardingViewModel`.

---

## 6. Permission gating

Checked every path that can run before both permissions are granted.

- `InputEngine.handleMouseDown` (line 115): if Accessibility isn't granted,
  `windowControl.window(at:)` fails safely (returns `nil` via `AXWindowController`'s
  `guard error == .success`), so `state` simply never leaves `.idle` — no crash, no
  force-unwrap.
- `InputEngine.start()`/`GlobalMouseAndModifierTap.start()`: if Input Monitoring isn't
  granted, `CGEvent.tapCreate` returns `nil` (documented, silent failure), caught by
  `guard let tap = ... else { return false }` (`GlobalMouseAndModifierTap.swift:51`) — `start()`
  returns `false`, no tap is installed, no events are ever delivered, gesture machinery stays
  permanently idle. No crash.
- `AppDelegate.setEngineEnabled(true)` can be invoked via the StatusBar toggle even with no
  permissions granted (by design — `statusbar-menu.md` §3's "StatusBar only displays and
  toggles the user's *intent*"); this safely no-ops per the two points above, and
  `engineEnabled` correctly reports `false` back to the UI via `engineEnabledSubject`.
- `AppDelegate.proceedPastPermissions()` (which constructs `AXWindowController`,
  `GridOverlayController`, and `InputEngine`, and calls `engine.start()`) is only ever invoked
  once both permissions are confirmed: at launch (`applicationDidFinishLaunching`, gated by
  `permissions.isFullyPermitted`) or from `OnboardingCoordinator`'s completion callback, which
  only fires once `OnboardingViewModel.stage == .readyToUse` (`OnboardingCoordinator.swift:143-147`).
  Grepped for every call to `presentOnboarding()`/`proceedPastPermissions()` — each is called
  from exactly one place. No double-construction, no early construction.

No crash, no force-unwrap of a nil AX result, and no partial-functionality state was found
anywhere in the pre-permission paths — the "both or neither" model from
`permissions-model.md` §5 is faithfully honored.

**One completeness gap worth flagging**, separate from crash-safety: `permissions-model.md`
§4 specifies a `degraded(missing:)` onboarding UX that should reappear "even when the
onboarding window isn't on screen" after a *runtime* revocation (not just first-run). The
`OnboardingViewModel`/`OnboardingView` machinery to render this **is** fully implemented
(`OnboardingCoordinator.swift:85-97`, `OnboardingView.swift:89-119`) and correctly computes
`.degraded` from the two live booleans — but nothing in `AppDelegate` ever calls
`presentOnboarding()` a second time. `AppDelegate.handlePermissionsChanged()`
(`AppDelegate.swift:186-189`) only calls `setEngineEnabled(false)` on a revocation; it never
re-shows the onboarding window. The user's only in-app signal that something is wrong is
`StatusBarController`'s own independent permission subscription (which **does** correctly
re-show the "Grant Accessibility/Input Monitoring Access…" menu items and dim the icon, per
`StatusBarController.swift:236-274`) — so the user isn't left with zero recourse, but the
richer, explanatory "MacGriddle lost access to X" window the architecture describes never
reappears once dismissed. This is a scope/UX gap, not a safety gap.

**Verdict: PASS** on crash-safety (the checklist's actual ask). **CONCERN** noted on UX
completeness relative to `permissions-model.md` §4's degraded-state re-presentation.

---

## 7. Cross-module API consistency beyond what compiles

- **`GestureCandidate.screenFrame` locked at anchor time, not mouse-down time**
  (`input-engine-and-state-machine.md` §9): confirmed by tracing the field through
  `InputEngine.swift`. At `handleMouseDown` (line 123), the candidate's `screenFrame` is set
  from `screenFrame(containing: point)` at the mouse-down point — but this value is **never
  read** while in `.dragging`/`.gridActive` (the `.gridActive` branch of `handleMouseDragged`,
  lines 137-146, re-resolves the screen fresh on every move via its own
  `screenFrame(containing: point)` call, ignoring `candidate.screenFrame` entirely — correctly
  implementing "before anchoring... the user is free to choose which monitor to start on").
  The *only* place `screenFrame` is actually consumed by grid math is after anchoring
  (`coveringRect`, line 259; the anchored→freeResize/freeResize→anchored toggles, lines
  233-237, 246) — and the value used there is `lockedCandidate.screenFrame`, a **freshly
  rebuilt** `GestureCandidate` constructed at `handleFlagsChanged`'s `.gridActive` case (lines
  219-224) using `screenFrame(containing: point)` evaluated **at that instant** — i.e., at
  anchor time. **Verified correct**: the mouse-down-time value is vestigial/unused for any
  actual math; the real locked value is computed fresh at anchoring, exactly per §9.
- **`Overlay.updateAppearance` wired to live Preferences changes**: traced
  `AppDelegate.observeSettingsChanges()` (lines 217-252) end to end. `CombineLatest4` over
  `settingsStore.$cellStrokeColor/$selectionFillColor/$selectionStrokeColor/$overlayOpacity`,
  `.dropFirst()` (correctly skips only the one combined emission representing the
  already-applied initial values — `@Published`'s projected publisher emits its current value
  synchronously on subscribe, so `dropFirst()` here drops exactly that first, redundant
  snapshot and nothing else), `.receive(on: .main)`, then
  `overlayController?.updateAppearance(OverlayAppearance(...))` with `Color→NSColor`
  conversion done at this exact seam (never inside `Overlay`, matching the Core/Overlay
  boundary). `GridOverlayController.updateAppearance` (line 65-67) stores the new value; it is
  picked up by the next `show()`'s `applyConfiguration` (line 110-119). Given a grid overlay is
  only ever visible during an active drag (and a user cannot simultaneously operate a
  Preferences color picker and hold a window drag with the same pointer), "applied on the next
  gesture" is the only realistic interpretation of "live," and matches it. **Verified
  correct**, no gap.
- The equivalent grid-size/live-resize chain (`CombineLatest3` over
  `$gridColumns/$gridRows/$liveResizeEnabled`, lines 218-231) was traced the same way and is
  equally correct.

**Verdict: PASS.**

---

## 8. Duplicate/dead code from parallel agents — **CONCERN**

Beyond the already-fixed `OnboardingStage` duplicate (confirmed: it is defined exactly once,
in `Sources/Permissions/OnboardingStage.swift`, and imported — not redeclared — everywhere
else), two more instances were found:

**(a) Three independent, redundant fixes for the same Swift existential problem.**
`PermissionsProviding` inherits `ObservableObject`, and calling `.objectWillChange` directly on
a `PermissionsProviding`-typed (existential) value doesn't compile. Three different modules
independently invented a workaround for this:
- `Sources/MacGriddleCore/PermissionsChangePublisher.swift:20-25` — a protocol-extension
  computed property, `changePublisher`. Used by `AppDelegate.swift:181` and
  `OnboardingCoordinator.swift:47`.
- `Sources/Input/InputEngine.swift:293-298` — a private free generic function,
  `subscribeToPermissionsChange<P: PermissionsProviding>(_:handler:)`, used only at line 39.
- `Sources/StatusBar/StatusBarController.swift:198-207` — a private generic method,
  `liveGrantedPublisher<P: PermissionsProviding>(from:reading:)`, used only at lines 210-215.

All three compile and work (confirmed by the clean build in §1) — this is not a functional
bug. But `PermissionsChangePublisher.swift`'s own doc comment (lines 13-19) asserts "a free
generic function... does *not* reliably resolve this when called with an already-existential-
typed argument," which is what motivated adding the `changePublisher` extension in the first
place — yet `Input` and `StatusBar` both use exactly that "unreliable" free-generic-function
shape, and both compile and run correctly. Either the doc comment's claim is overstated (the
failure mode is narrower than stated — plausibly specific to reading through an
implicitly-unwrapped-optional stored property, which is exactly `AppDelegate`'s situation and
not `InputEngine`'s or `StatusBarController`'s), or three separate people solved the same
problem three different ways without any of them consolidating on the one already-exported,
public fix living in `MacGriddleCore` that `Input` and `StatusBar` both already transitively
depend on. Either way, this is duplicated engineering effort and an inconsistent codebase
idiom for future maintainers, not a currently-observable defect.

**(b) `WindowControl`'s capture/restore helpers are dead code.**
`Sources/WindowControl/CapturedWindowFrame.swift` defines `CapturedWindowFrame`,
`captureForRestore(_:using:)` (line 20-23), and `restore(_:using:)` (line 30-33) —
specifically, per `window-control-and-coordinates.md` §5, as "the pattern this module
provides" for gesture-cancellation restore, and `input-engine-and-state-machine.md` §5 asserts
"[Input] is the one chunk that actually calls them." **It does not.** Grepped every call site
of `restore(`/`captureForRestore(` in the project: the only matches outside
`CapturedWindowFrame.swift` itself are `InputEngine.swift:265-268` and `:273`, which are calls
to `InputEngine`'s **own**, differently-typed **private** method
`restore(_ candidate: GestureCandidate)` (line 274-276) — a same-named but unrelated function
operating on `Input`'s own `GestureCandidate`, not `WindowControl`'s `CapturedWindowFrame`.
`InputEngine` captures the original frame directly via `windowControl.frame(of:)` inline at
mouse-down (line 116) and restores directly via `windowControl.setFrame(...)` inline at every
cancel/panic point, never touching `CapturedWindowFrame`/`captureForRestore`/`restore` at all.
This traces back to an inconsistency already present in the architecture document itself —
`input-engine-and-state-machine.md` §5's prose claims these helpers are used, but that same
section's own illustrative code sample doesn't call them either, inlining the equivalent logic
instead — so the real implementation faithfully followed the spec's *code*, leaving the spec's
*helper functions* (and the public API surface `WindowControl` exports for them) unused.
**`CapturedWindowFrame`, `captureForRestore`, and `restore` are unreachable dead code.**

**Verdict: CONCERN.** Neither issue causes incorrect behavior, but both are real,
citable instances of exactly the "redundant type definitions... or logic that's written twice
in slightly different ways" pattern this checklist item asks about, beyond the one
`OnboardingStage` case already fixed.

---

## 9. Memory / retain cycles

Grepped every `.sink` and closure-based `NotificationCenter`/`Timer` registration in
`Sources/` and checked each one's capture list:

| Site | Capture | Cycle risk |
|---|---|---|
| `PermissionsMonitor.swift` — `didBecomeActiveNotification` observer | `[weak self]` | None |
| `PermissionsMonitor.swift` — poll `Timer` | `[weak self]` | None |
| `GridOverlayController.swift` — `didChangeScreenParametersNotification` observer | `[weak self]` | None (also long-lived by design) |
| `InputEngine.swift:39-42` — permission-retry subscription | `[weak self]` on the outer closure passed to `subscribeToPermissionsChange` | None |
| `InputEngine.swift:296` — inner `.sink` inside `subscribeToPermissionsChange` | captures `permissions` (forward reference only) and the already-weak `handler`; does not capture any `self` of its own | None — `permissions` (the `PermissionsMonitor`) holds no reference back to `InputEngine`, so this is a one-directional strong reference, not a cycle |
| `InputEngine.swift:59-61` — `GlobalMouseAndModifierTap` handler | `[weak self]` | None — breaks the `InputEngine → tap → handler → InputEngine` cycle that a strong capture would otherwise create |
| `GlobalMouseAndModifierTap.swift:42-49` — CGEventTap C callback | `Unmanaged.passUnretained` (not a Swift capture at all) | None by construction — C callbacks can't capture, and `passUnretained` deliberately does not bump the retain count |
| `AppDelegate.swift:182,224,240` — permission/settings subscriptions | `[weak self]`, stored in `self.permissionsSubscription`/`self.settingsSubscriptions` | None — correctly breaks the self-referential cycle that storing the cancellable on `self` would otherwise create |
| `OnboardingCoordinator.swift:48` (`OnboardingViewModel`) | `[weak self]` | None |
| `OnboardingCoordinator.swift:142` (`stageCancellable`) | `[weak self]` | None — same self-referential-cancellable pattern as AppDelegate, correctly broken |
| `StatusBarController.swift:225` (`cancellables`) | `[weak self]` | None — same pattern, correctly broken |

Every closure that is stored *on the same object it captures* (the pattern that actually
causes a leak: `self → cancellable → closure → self`) uses `[weak self]`. The one `.sink`
that does *not* use `[weak self]` (`InputEngine.swift:296`) doesn't need to, because it isn't
stored on the object it would otherwise strongly reference — it only strongly captures the
`permissions` argument, which has no reference back to `InputEngine`.

**Verdict: PASS.** No retain cycles found.

---

## 10. Settings persistence roundtrip (`Sources/Preferences/SettingsStore.swift`)

Every field's load path (constructor, lines 120-138) reads from `UserDefaults` with a
type-checked cast and a `Defaults`-value fallback, and every field's save path (`didSet`) writes
back to the same key. Checked all eight fields — `gridColumns`/`gridRows` (clamped both ways),
`liveResizeEnabled`, `launchAtLoginEnabled`, `cellStrokeColor`/`selectionFillColor`/
`selectionStrokeColor` (via `Color(hex:)`/`.toHexString()`, `Color+Hex.swift`), `overlayOpacity`
(clamped both ways) — each has a matching `Keys.*` constant used symmetrically on both the read
and write side. `resetToDefaults()` reassigns all eight through their real setters (so
`didSet`/persistence/Combine-publishing all fire identically to a manual UI edit). Round-trip
is faithful for every field.

**`persistLaunchAtLogin()` (lines 177-193) vs. `persistGridColumns`/`persistGridRows`
(lines 159-175) — the claimed shared recursion-safety pattern is not quite the same shape,
though it is safe.**

`persistGridColumns`/`persistGridRows` validate *before* persisting: compute the clamped value,
and if it differs from the current one, reassign (triggering exactly one re-entrant `didSet`
call) and `return` **without** touching `UserDefaults` on this pass — the re-entrant call is
what actually persists, once, because on that second pass the value is already clamped and the
`if clamped != gridColumns` check is now false.

`persistLaunchAtLogin()` does the reverse ordering: it persists to `UserDefaults`
**unconditionally first** (line 178), *then* attempts the side-effecting `LaunchAtLogin.setEnabled(...)`
call (line 180), and only on failure reads back the real system state and reassigns (line
188-191) if it disagrees. Because that reassignment re-enters `didSet` → `persistLaunchAtLogin()`
a second time, the second pass **persists again** (correctly, with the corrected value) but
also **re-attempts `LaunchAtLogin.setEnabled(...)` a second time** — calling `register()`/
`unregister()` again with whatever value was just read back as "actual," which is redundant
(the system already reports that state) in a way the grid-columns pattern never does (that
pattern's second pass never repeats a side-effecting call, only a plain `UserDefaults.set`).
This is bounded and safe — the recursion cannot loop more than twice, because the second
pass's own catch block compares against a value that was *just* re-read from the live system,
so the `if actual != launchAtLoginEnabled` guard can only fire once more before the two values
necessarily agree — but it is not the identical "re-enters once, then settles" mechanism the
in-file comment (`SettingsStore.swift:184-187`) claims by direct comparison to
`persistGridColumns`/`persistGridRows`'s "established pattern in the same file": the grid
pattern never repeats its corrective action, this one does.

Concretely: on a persistent `SMAppService` failure (e.g. this project's own noted "not signed,
not notarized" dev-build TCC churn from `RESEARCH.md` §B.1.1/`project-structure.md` §5, which
plausibly extends to `SMAppService` registration too on an ad-hoc dev build), toggling
`launchAtLoginEnabled` would perform **two** `SMAppService` calls per user click instead of one,
both of which fail, before settling — not incorrect, not a crash, not an infinite loop, just a
literal doubling of a fallible side-effecting system call relative to what the cited pattern
actually does.

**Verdict: PASS** on roundtrip fidelity for every field. **CONCERN (minor)** on the specific
claim that `persistLaunchAtLogin()` follows the *same* recursion-safety shape as
`persistGridColumns`/`persistGridRows` — it is safe, but structurally different in a way that
causes one avoidable extra `SMAppService` call on the failure path.

---

## Summary table

| # | Checklist item | Verdict |
|---|---|---|
| 1 | Build & tests, independently re-run | **PASS** |
| 2 | Gesture state machine fidelity | **PASS** |
| 3 | Coordinate-space correctness | **PASS** |
| 4 | AXError / defensive coding discipline | **PASS** |
| 5 | Thread-safety / actor-isolation | **CONCERN** — `GridOverlayController` not `@MainActor` |
| 6 | Permission gating (crash-safety) | **PASS**; UX-completeness gap noted (not crash-safety) |
| 7 | Cross-module API semantic consistency | **PASS** |
| 8 | Duplicate/dead code | **CONCERN** — triplicated existential workaround + dead `CapturedWindowFrame` API |
| 9 | Memory / retain cycles | **PASS** |
| 10 | Settings persistence roundtrip | **PASS**; minor pattern-fidelity note on `persistLaunchAtLogin` |

**No FAIL-level findings.** Every CONCERN is a latent robustness/maintainability issue or a
scope gap, not an observed crash, data-loss, or incorrect-output defect. The build and test
claims from the integration pass hold up under independent re-verification.

---

## Rework pass (post-review)

Every CONCERN above was addressed:

- **§5 (`@MainActor` gap)**: `GridOverlayController` is now `@MainActor`. The
  `NSNotificationCenter` observer closure (not itself actor-isolated) uses
  `MainActor.assumeIsolated` at its one call site, matching `main.swift`'s existing pattern.
  Marking the whole `GridOverlayRendering` protocol `@MainActor` was tried and reverted — it
  breaks every synchronous call from `Input`'s non-isolated `handle(type:event:)` dispatch
  chain, which is a much larger, riskier change than this finding warrants. Instead, the
  class's conformance is declared `@preconcurrency GridOverlayRendering`, which fully silences
  the "conformance crosses into main-actor-isolated code" warning without any `Input` changes
  and without introducing any new warning category (verified: a clean rebuild shows only the
  two originally-accepted categories, `#ExistentialAny` and `#deprecation`).
- **§6 (degraded-state re-presentation gap)**: `AppDelegate.handlePermissionsChanged()` now
  calls `presentDegradedNoticeIfNeeded()`, which re-presents the same onboarding window
  (`OnboardingCoordinator`, now with a `startingFromDegraded` flag so it renders `.degraded`
  immediately instead of `.welcome`) without re-running `proceedPastPermissions()` — on
  completion it just calls `setEngineEnabled(true)` to resume the already-constructed engine.
  A new `terminatesAppOnEarlyClose` flag (default `true`, `false` for this path) stops the
  window's existing "quit the app if closed early" behavior from firing when the rest of the
  app is already running.
- **§8a (triplicated existential workaround)**: `PermissionsChangePublisher.swift`'s doc
  comment was corrected — it no longer claims free generic functions "do not reliably
  resolve" categorically; it now states precisely that the failure is specific to reading
  through an implicitly-unwrapped-optional stored property (`AppDelegate`'s case), which is
  why `Input`/`StatusBar`'s own local generic-method workarounds (reading plain `let`s) work
  correctly. `Input`/`StatusBar`'s working code was left alone rather than churned to match.
- **§8b (dead `CapturedWindowFrame` API)**: deleted
  `Sources/WindowControl/CapturedWindowFrame.swift` entirely — confirmed zero call sites
  outside the file itself.
- **§10 (minor `persistLaunchAtLogin` pattern-fidelity note)**: added an
  `isReconcilingLaunchAtLogin` guard so the failure-path reassignment persists the corrected
  value without re-attempting the fallible `LaunchAtLogin.setEnabled(...)` system call a
  second time.

Post-rework verification (clean `.build/`): `swift build`, `swift build -c release`, and
`swift test` (15/15) all pass; `Scripts/build-app.sh` produces a valid `MacGriddle.app`. Full
warning inventory unchanged from §1's original two accepted categories — no new category
introduced by any of the above fixes.

---

## Post-manual-testing fix: the `@MainActor` fix above caused a real crash-on-launch-of-gesture

Manual testing (the step this whole review was building toward) caught what static
review and compilation could not: **holding ⌥ Option during a drag crashed the entire app**,
every time, with `Fatal error: Incorrect actor executor assumption; Expected same executor as
MainActor`.

Root cause: `@preconcurrency` conformance to a nonisolated protocol from an `@MainActor`
type doesn't just silence the compiler warning — it inserts a **runtime** isolation check
(functionally equivalent to wrapping every call in `MainActor.assumeIsolated`) at each call
into that type. `Input`'s `CGEventTap` callback runs on the physical main thread, but is
invoked directly by CoreFoundation's `CFRunLoopRun()`, bypassing GCD — Swift's concurrency
runtime does not recognize that call stack as "on MainActor" even though it physically is,
so the very first call from that callback into `GridOverlayController` (which happens on the
`.dragging → .gridActive` transition — i.e. the moment Option is held) hit the runtime
assertion and crashed the process.

**Fix**: reverted `@MainActor`/`@preconcurrency` on `GridOverlayController` entirely, back to
its original, pre-review-rework state — which the review itself already confirmed "behaves
correctly today" (no crash), just without a compile-time isolation guarantee. That absence of
a compiler safety net was accurately characterized as low-urgency in §5 above; the attempted
fix for it was not — it turned a latent, harmless gap into an active, 100%-reproducible crash.
**Lesson recorded for future rework passes on this codebase**: any `@MainActor` addition to a
type reachable from `Input`'s `CGEventTap` callback chain must be verified by an actual
gesture, not just a clean compile — the crash was invisible to every build/test/warning check
run during this review and only surfaced once a human held the mouse button and Option key.

Re-verified after the revert: `swift build`, `swift build -c release`, `swift test` (15/15),
and `Scripts/build-app.sh` all still pass, with the same two originally-accepted warning
categories and no others.

---

## Second post-manual-testing fix: a different, pre-existing crash unmasked by the first fix

Reverting the `@MainActor` issue above stopped the "Incorrect actor executor assumption"
crash, but the user's very next test still crashed on the same trigger (holding ⌥ Option
during a drag) — with a **different** signature. A real macOS crash report
(`~/Library/Logs/DiagnosticReports/MacGriddle-*.ips`) gave the exact stack, which static
review, compilation, and `swift test` never could:

```
InputEngine.handleFlagsChanged(optionHeld:at:)
  → protocol witness for GridOverlayRendering.show(configuration:state:)
  → GridOverlayController.show(configuration:state:)
  → GridOverlayController.rebuildWindows()
  → OverlayWindow.init(screen:) → -[NSWindow initWithContentRect:styleMask:backing:defer:screen:]
  → TRAP (EXC_BREAKPOINT / SIGTRAP)
```

Root cause, unrelated to Swift concurrency this time: `InputEngine` was calling
`overlay.show(...)` — which constructs brand-new `NSWindow`s — **synchronously from inside
the `CGEventTap` C callback**. That callback is invoked reentrantly from deep inside
`NSApplication`'s own live event-fetching machinery (`_DPSNextEvent` was on the same stack in
the crash report). AppKit's window-creation path is not safe to re-enter from that specific
nested calling context, even though it is, in fact, running on the main thread — this is a
structural AppKit reentrancy hazard, not a data-dependent bug, which is why it was
100%-reproducible on literally the first Option-hold every time.

**Fix**: added `InputEngine.onMainRunLoop(_:)`, which wraps a closure in
`DispatchQueue.main.async`. Every call into `overlay` (`show`/`updateSelection`/`hide` — the
only methods that touch `NSWindow`) now goes through it instead of being called directly from
the `handle...` methods, so the actual window creation/teardown always runs on a fresh main
run loop turn, decoupled from the tap callback's own call stack. Internal gesture-state
transitions (`state = ...`) and `WindowControl` calls (Accessibility API, not AppKit, not
subject to this specific hazard) remain synchronous/immediate — only the `NSWindow`-touching
side effects are deferred, so the state machine's own correctness is unaffected; the only
observable difference is a sub-16ms delay between a state transition and the overlay visually
catching up, which is imperceptible.

Verified after this fix: `swift build`, `swift build -c release`, `swift test` (15/15), and
`Scripts/build-app.sh` all pass, same two warning categories, no others.

**Second lesson recorded**: this bug was already present in the *original* build, before
either the `@MainActor` addition or its revert — it was masked by the actor-isolation crash
firing first on the exact same trigger. When a fix for one crash on a given trigger doesn't
fully resolve the user's report, check whether a *second*, independent bug shares the same
trigger before assuming the first fix was incomplete. Reading the actual macOS crash report
(`~/Library/Logs/DiagnosticReports/`) resolved in one step what several more rounds of
hypothesis-and-static-analysis would have taken much longer to find — prefer this over
continued reasoning-from-first-principles when a crash is reproducible.

---

## Third post-manual-testing fix: `OverlayWindow` missing one of `NSWindow`'s two designated initializers

Found by the user running the app under Xcode's own debugger instead of the bundled `.app` —
Xcode surfaced the exact fatal error immediately: `Fatal error: Use of unimplemented
initializer 'init(contentRect:styleMask:backing:defer:)' for class 'Overlay.OverlayWindow'`.

`NSWindow` has two designated initializers: `init(contentRect:styleMask:backing:defer:)` and
`init(contentRect:styleMask:backing:defer:screen:)`. `OverlayWindow` only ever implemented the
`screen:`-taking one (all it needs for its own normal construction via
`GridOverlayController.rebuildWindows()`). Swift's rule for subclassing a class with multiple
designated initializers: every one of them needs *some* implementation in the subclass, or
the compiler silently synthesizes a body for the missing one that just calls `fatalError`.
Something — plausibly Xcode's own debug-run launch path, or macOS window-state restoration,
since this only reproduced running under Xcode's debugger and never through the properly
bundled `.build/MacGriddle.app` — really does call the other signature.

**Fix**: added the missing `override init(contentRect:styleMask:backing:defer:)`, resolving
a screen from `contentRect`'s origin (falling back to `NSScreen.main`, then the first
available screen) and behaving identically to `init(screen:)` from there, instead of
trapping.

Also worth noting for anyone testing this way: several benign `NSCocoaErrorDomain`/`linkd`/
"missing main bundle identifier" warnings appear when running under Xcode's debugger that do
not appear when launching the properly bundled `.build/MacGriddle.app` — these are artifacts
of Xcode's debug-launch context lacking a full bundle identity, not bugs in this project.
Recommend `.build/MacGriddle.app` (via `Scripts/build-app.sh`) as the primary way to exercise
real end-to-end behavior; Xcode's Run button is genuinely useful for exactly what it just
did here (surfacing a fatal error immediately with a precise message) but note that
Accessibility/Input Monitoring TCC grants are tied to a specific binary path, so testing via
Xcode's debugger may require granting both permissions again for that separate binary path.

Verified after this fix: `swift build`, `swift build -c release`, `swift test` (15/15), and
`Scripts/build-app.sh` all pass.

---

## Fourth post-manual-testing fix: the onboarding "loop" — Launch Services never knew the app existed

User got stuck: grant Accessibility, close the System Settings window, nothing happens;
clicking "Grant Accessibility Access…" again just reopens the same prompt, indefinitely.

Root cause, confirmed directly rather than guessed: `tccutil reset Accessibility
com.macgriddle.app` failed with `No such bundle identifier`, and both `mdfind
"kMDItemCFBundleIdentifier == 'com.macgriddle.app'"` and `lsregister -dump` returned zero
results — **Launch Services had never registered this `.app` bundle at all**, despite it
existing on disk with a correct `Info.plist`. `.build/` gets `rm -rf`'d and rebuilt by every
`Scripts/build-app.sh` run, and Launch Services apparently never picked up the fresh bundle
at that path automatically. Without a Launch-Services-known identity, TCC's own
bundle-identity tracking for Accessibility/Input Monitoring became unreliable — the
System Settings checkbox the user was toggling didn't reliably bind to the actual running
process, so grants silently didn't take effect.

**Fix, in two parts**:
1. One-time: `lsregister -f .build/MacGriddle.app` (force-register), then `tccutil reset
   Accessibility com.macgriddle.app` + `tccutil reset ListenEvent com.macgriddle.app` to
   clear whatever broken/stale grant state had accumulated. Both `tccutil` calls succeeded
   immediately once the bundle was registered — confirming this was the actual cause, not a
   coincidence.
2. Permanent: `Scripts/build-app.sh` now calls `lsregister -f` on the assembled `.app` as its
   last step, every time. This should prevent the same class of bug from recurring on any
   future rebuild during this project's development.

**Third lesson recorded**: when a permission-granting UI loop doesn't respond to the expected
actions at all (not a crash, not wrong behavior — just *nothing happens*), suspect the
OS-level bundle/identity-tracking layer (Launch Services) before the app's own permission
logic. `tccutil reset <service> <bundle-id>` failing with "No such bundle identifier" is a
direct, checkable signal for exactly this class of problem, and resolves in one command once
diagnosed — much faster than trying to debug the app's own `PermissionsMonitor` polling logic
for a bug that was never there.

---

## Fifth post-manual-testing fix: real crash — infinite recursion in `OverlayWindow`'s two designated initializers

User report: app crashes again on Option-hold, after onboarding now succeeds. Crash report
(`~/Library/Logs/DiagnosticReports/MacGriddle-*.ips`) said `"Thread stack size exceeded due to
excessive recursion"` (`EXC_BAD_ACCESS`/`SIGSEGV`). Parsing the full (untruncated) frame list
showed the exact cycle, repeating dozens of times until the stack overflowed:

```
OverlayWindow.init(contentRect:styleMask:backing:defer:)   [our override, calls super.init(...screen:)]
  -> -[NSWindow initWithContentRect:styleMask:backing:defer:screen:]   [Apple's base impl]
    -> (dynamically, on self) -[NSWindow initWithContentRect:styleMask:backing:defer:]
      -> @objc OverlayWindow.init(contentRect:styleMask:backing:defer:)   [our override again]
        -> super.init(...screen:) -> ... (repeats)
```

Root cause: `OverlayWindow` overrode **both** of `NSWindow`'s designated initializers (as
Swift requires, once you override either one — see the old doc comment this replaced), and
each override's `super.init` call targeted the *other* arity to resolve a screen. AppKit's own
base implementations of the 4-arg and 5-arg designated initializers dynamically call back into
*each other* on `self` as part of their own setup — confirmed empirically by the trace, not
just from docs. Any subclass override that also calls into the other arity's `super.init`
closes the loop.

**Fix**: stopped overriding either designated initializer. `OverlayWindow` now defines no
custom `init` at all (its only stored property, `overlayContentView`, is an implicitly
unwrapped optional with an implicit `nil` default), so Swift auto-inherits `NSWindow`'s
initializers completely unchanged. All custom per-screen setup (creating the content view,
`configureWindow(for:)`, assigning `contentView`) moved into a `static func make(for
screen:) -> OverlayWindow` factory that runs strictly *after* construction has already fully
completed — no override, no cross-call, no recursion possible. Updated the one call site
(`GridOverlayController.rebuildWindows()`) from `OverlayWindow(screen:)` to
`OverlayWindow.make(for:)`.

**Fourth lesson recorded**: don't trust "the two NSWindow designated initializers just call
`super` independently" as a safe mental model. If a subclass has any reason to override both
(which Swift forces once you override either with custom stored-property setup), and either
override's `super.init` call crosses over to the *other* arity, treat it as a live infinite-
recursion risk — verified here by full crash-frame inspection, not by reasoning about Apple's
documentation alone. The robust fix is almost always to avoid overriding either designated
initializer in the first place, doing custom setup via a factory method after `init` instead.

**Also reported alongside this**: onboarding does not complete when running via Xcode's Run
button (separate from the packaged `.app`). This is expected, not a new bug: Xcode's Run
action for a plain SPM `executableTarget` launches the raw, unbundled Mach-O binary straight
from `DerivedData` — there is no `.app` wrapper, no `Info.plist`, no bundle identifier for
Launch Services or TCC to track. Accessibility/Input Monitoring permissions are fundamentally
bundle-identity-based, so a bundle-less process cannot participate in that system at all,
regardless of anything in this app's own code. Xcode's Run button remains genuinely useful for
reproducing crashes (exact `fatalError` messages, immediately) but should not be used to test
onboarding/permissions/the live gesture — use `.build/MacGriddle.app` (via
`Scripts/build-app.sh`) for that.

---

## Sixth fix: live-resize fighting the OS's own native window-drag

User report: with "Resize live while dragging" enabled, the real window was "REALLY shaky...
like it keeps dragging and shifting back to the top left corner."

Diagnosis (from reading the actual code, not guessed): `InputEngine`'s `coveringRect` is a
pure function of a fixed anchor, the current cursor point, and a locked `screenFrame` — no
feedback loop. `WindowControl.setFrame` writes position before size, correctly. Neither of
MacGriddle's own computations was the bug.

The real cause: `GlobalMouseAndModifierTap` was deliberately `.listenOnly` — it can *observe*
a drag but never stop it. Left-clicking a title bar starts a completely independent native
window-drag inside WindowServer that continuously moves the window to follow the cursor. With
live-resize on, `InputEngine` was *also* calling `AXUIElementSetAttributeValue` on every
`leftMouseDragged` tick to move/resize that same window to the grid-cell rect. Two independent
forces fighting over one window's frame, every frame — that's the shakiness and the pull
toward a corner.

Three remediation options were presented to the user (best-effort throttling only; drop
real-window live movement and keep just the overlay preview; or take over the drag entirely).
**Chosen: take over the drag.**

**Fix**: `GlobalMouseAndModifierTap` switched from `.listenOnly` to `.defaultTap` (active).
`InputEngine.handle(type:event:)` now returns `CGEvent?` — the event to pass through, or `nil`
to swallow — and only ever swallows a `.leftMouseDragged` event, and only when
`handleMouseDragged(to:)` reports it just took over the window's frame (state
`.anchored`/`.freeResize`, live-resize on, `setFrame` returned `true`). Every other event type,
and every other outcome, always passes through unmodified. The condition is derived live from
`state` on every single event rather than a separately-managed flag, so there is no lifecycle
to get wrong — suppression starts and stops exactly when `state` says it should, with nothing
to leak if a gesture ends abnormally (panic hotkey, `stop()`, permission revocation).

**Verified**: clean build, 15/15 GridEngine tests still pass, packaged app rebuilds cleanly.
**Not yet verified**: the actual smoothness fix and — just as important — that ordinary
window dragging is completely unaffected once a suppressed gesture ends. This is exactly the
kind of change that can't be confirmed by build/unit tests; see `docs/MANUAL_VERIFICATION.md`'s
updated live-resize section for the specific regression checks added for this.

**Fifth lesson recorded**: this reverses a previously deliberate, explicitly-commented safety
decision ("never `.defaultTap` — must not be able to swallow/alter input"). That comment is
now updated to explain exactly how narrowly the new swallow behavior is scoped, specifically
so a future session doesn't "fix" this back to listen-only thinking it's an accidental
regression — see the addendum in `docs/architecture/chunks/input-engine-and-state-machine.md`.

---

## Seventh fix: menu bar not excluded from the grid, and a mouse-up race in live-resize

User report after retesting the drag-takeover fix: live-resize is much smoother, but two
issues remained. (1) Snapping to the top row of the grid (in *any* mode, not just live-resize)
pushed the window down slightly instead of landing flush. (2) With live-resize on, releasing
the mouse jumped the resized window toward the cursor instead of staying at the final rect.

**Issue 1 root cause**: `screenFrame(containing:)` (`Input/ScreenResolution.swift`) and
`OverlayWindow.make(for:)` both used `NSScreen.frame` — the *full* screen bounds, including
the menu bar (and Dock, if visible). Grid cells were computed across that entire area, so the
top row's cells physically overlapped the menu bar. macOS silently pushes any window
positioned to overlap the menu bar down and away from it, so a window "snapped" to a top-row
cell always landed a few pixels off from where the grid showed it.

**Fix**: both switched to `NSScreen.visibleFrame` (excludes the menu bar and Dock). Verified
by hand-checking the Cocoa→Quartz flip math against the unchanged `primaryScreenHeight`
reference: a `visibleFrame` with a 25px menu bar and no Dock correctly flips to a Quartz rect
with `origin.y = 25`, i.e. starting exactly below the menu bar. `screen(containing:)` (used
only to identify *which* screen a point is on) deliberately still uses `.frame` — hit-testing
screen membership should still count the menu bar/Dock area as part of that screen.

**Issue 2 root cause**: the live-resize drag-takeover fix (previous section) deliberately never
suppressed the *final* `leftMouseUp` — reasoning that the native drag should always get an
unmodified event to end its own tracking cleanly. In practice, because every *intermediate*
`leftMouseDragged` had been suppressed, WindowServer's native drag-tracking had a backlog of
unseen cursor movement; on that final, unsuppressed mouse-up it performed one last native
"catch up to the cursor" repositioning — landing right after (and overwriting) the correct
final frame `handleMouseUp` had just set via Accessibility.

**Fix**: `handleMouseUp` now returns `Bool` (mirroring `handleMouseDragged`), and
`InputEngine.handle(type:event:)` swallows the final `.leftMouseUp` too, under the exact same
condition (`.anchored`/`.freeResize`, live-resize on, `setFrame` succeeded). Every other
mouse-up case (idle/dragging/cancel, or a commit with live-resize off) is untouched — those
paths never suppressed the drag either, so their native tracking still needs a normal,
unmodified mouse-up to terminate cleanly.

**Verified**: clean build, 15/15 tests, packaged app rebuilds cleanly. **Not yet verified**:
the actual fix on-device, and specifically whether swallowing the final mouse-up leaves any
"stuck click" residue in the target app — added as an explicit check in
`docs/MANUAL_VERIFICATION.md`'s live-resize section.

---

## Eighth fix: unsigned builds meant TCC forgot every grant on every single rebuild

User report: after rebuilding for the seventh/menu-bar fixes, onboarding appeared to complete
but nothing actually worked afterward — no menu bar icon, gesture non-functional. Confirmed
via `ps aux`/`log show` that the process was alive and not crashing (no new `.ips` report, no
fatal errors — just ordinary `linkd.autoShortcut` noise already known to be benign). The
process being fine but "nothing works" pointed at the permission layer again, but this turned
out to be a **third, distinct** cause in that same family — not a repeat of the fourth fix
(Launch Services never registered the bundle) or the seventh (two conflicting registrations).

**Root cause**: `Scripts/build-app.sh` never signed the app at all — not even ad-hoc. Both
fully unsigned and ad-hoc (`codesign --sign -`) binaries get a designated requirement keyed to
the exact hash of their own bytes (confirmed against multiple independent real-world reports
of the identical failure mode). Since every rebuild produces different bytes, **every rebuild
is a brand-new app to TCC** — every previously granted Accessibility/Input Monitoring
permission silently stops applying, immediately, with zero error surfaced anywhere. This had
been happening the entire session; it just hadn't been isolated from the other two
Launch-Services-related causes until now.

**Fix**: created a stable, local, self-signed code-signing certificate ("MacGriddle Local
Dev") in the login keychain (`openssl req -x509` with the `codeSigning` extended key usage,
imported via `security import -T /usr/bin/codesign`, trusted for code signing via
`security add-trusted-cert -p codeSign`). `Scripts/build-app.sh` now signs the assembled
bundle with this identity as part of every build. Verified empirically, not just asserted:
built twice in a row (touching a source file between builds to force a real rebuild) and
confirmed `codesign -d -r-` produced the **identical** designated requirement both times —
`identifier "com.macgriddle.app" and certificate leaf = H"60ca5cbe…"` — anchored to the
certificate, not the binary's content. This survives every future rebuild unchanged.

Hit one codesign wrinkle along the way: `codesign --force --deep --sign` failed with
`errSecInternal Component` when re-signing over a previous ad-hoc signature. Signing the
bundle directly (no `--deep`) worked immediately — and `--deep` was never actually needed
here anyway, since this bundle has no nested frameworks/helpers to recurse into.

One-time cost of switching signing strategy: `tccutil reset Accessibility`/`ListenEvent`
for `com.macgriddle.app` (the identity changed once more, from adhoc to properly signed) —
after this, no more resets should ever be needed for a rebuild again.

**Sixth lesson recorded**: three different, real bugs (Launch Services registration, duplicate
registrations, and now unsigned-binary identity instability) all present nearly identically
from the user's side — "granted the permission, nothing happens." Each time, the fix was to
check a different specific thing (`tccutil reset`'s error message; `lsregister -dump`'s
registration count; `codesign -d -r-`'s designated-requirement stability across two builds)
rather than guessing which of the three it was. This eighth fix is the first of the three that
prevents its entire *class* of bug from recurring at all, rather than clearing one bad state.

---

## Ninth fix: swallowing the final mouse-up broke the *next*, unrelated click

User report: live-resize itself now works great, but the first click made on *any* window
right after a live-resize gesture moved that window to the click location.

**Root cause**: the eighth fix (mouse-up race, two sections up) swallowed the gesture's final
`leftMouseUp` to stop WindowServer's native drag from performing one last "catch up to cursor"
jump. That worked, but had a side effect not caught by build/tests: WindowServer's own
drag-tracking for the resized window never received a mouse-up matching the mouse-down that
started the drag, leaving it "open." The *next* mouse-down+mouse-up anywhere — on a completely
unrelated window — got interpreted as resolving that still-open drag, moving whatever it
landed on. Swallowing an input event has consequences beyond this gesture's own state machine;
this is exactly the "stuck click" risk flagged (but not yet confirmed) when that fix landed.

**Fix**: stopped suppressing `leftMouseUp` entirely — it's now never swallowed, even during
live-resize. `handleMouseUp` no longer returns a suppression signal at all (reverted to
`Void`). Instead, `handleMouseUp` now calls the existing `windowControl.setFrame(finalRect,
...)` as before, then separately calls a new `reapplyFrameAfterNativeDragSettles(_:of:)`,
which — only when live-resize is on — re-applies that same final frame again 50ms later via
`DispatchQueue.main.asyncAfter`. The real mouse-up reaches WindowServer normally now (so its
drag-tracking always closes out cleanly), and if it performs its own "catch up" jump as a
side effect, the deferred re-apply corrects it moments later — short enough to read as one
settle rather than two visible steps, long enough to reliably land after WindowServer's own
handling rather than racing it.

**Verified**: clean build, 15/15 tests, packaged app rebuilds and re-signs cleanly with the
same stable identity from the eighth fix (confirmed via `codesign -dv` — no TCC reset needed
this time, since the signing identity didn't change, only the code — which is exactly what
that fix was for). **Not yet verified on-device**: added an explicit "next-click check" to
`docs/MANUAL_VERIFICATION.md`'s live-resize section for this specific regression.

**Seventh lesson recorded**: when a fix involves swallowing/suppressing an OS input event,
the blast radius isn't limited to the gesture that swallowed it — always explicitly check
what happens to the *next*, unrelated interaction afterward, not just whether the original
bug is gone.

---

## Tenth fix (cosmetic): reduced a brief flash right after a live-resize gesture ends

User report: functionally everything now works, but the window briefly "disappears" right
after releasing the mouse during a live-resize gesture.

Best-justified fix without being able to reproduce this live: `reapplyFrameAfterNativeDragSettles`
(added in the ninth fix, above) unconditionally re-applied the final frame 50ms after every
live-resize gesture, regardless of whether WindowServer's own mouse-up handling had actually
disturbed it. That means most gestures ended with *two* `setFrame` calls in quick succession
— and some apps visibly redraw/flash for an instant on every `setFrame`, so an unconditional
second write is a plausible, easy-to-fix contributor even without pinning down the exact
rendering mechanism.

**Fix**: `reapplyFrameAfterNativeDragSettles` now re-reads the window's actual current frame
first (`WindowControlling.frame(of:)`) and only re-applies if it's actually off by more than a
tight tolerance (0.5pt, via a new `CGRect.isApproximatelyEqual(to:)` — loose enough to absorb
AX/coordinate-conversion floating-point noise, tight enough to still catch a real native
"catch-up" jump). Skips the redundant write entirely on whatever fraction of gestures
WindowServer didn't actually disturb.

**Caveat, stated plainly**: this is a well-justified reduction in unnecessary work, not a
confirmed fix for a root-caused rendering mechanism — that would need live reproduction this
session couldn't do. If the flash persists after this, the next step is to look at whether
the *first*, immediate `setFrame` call's own position-then-size two-step (documented in
`AXWindowController+Frame.swift`) is itself the source, independent of this second call.

**Update: it didn't help.** Confirmed via a targeted follow-up question — the flash does
*not* happen with live-resize off (ordinary snap-on-release), only with it on — which rules
out "any `setFrame` at mouse-up flashes" and confirms it's specific to live-resize's
drag-suppression architecture, not the tenth fix's redundant-write theory.

---

## Eleventh fix (higher risk, explicitly discussed with and approved by the user first): end the native drag early instead of at the end

Real mechanism, now well-supported rather than guessed: while `.anchored`/`.freeResize`
suppress `leftMouseDragged` (ninth fix), macOS still considers the window's *native* drag —
started by the original, unsuppressed `leftMouseDown` — to be continuously ongoing for the
entire suppressed span, since nothing ever tells it otherwise. When the real, final mouse-up
eventually arrives, macOS transitions that window out of its own internal "being natively
dragged" tracking, and that transition is what visibly flashes — independent of anything
this engine writes via Accessibility. Snap-on-release never shows this because it never
suppresses anything: native drag tracks the cursor continuously and ends via a completely
ordinary, on-time mouse-up.

**Fix**: post a synthetic `leftMouseUp` (via `CGEvent(mouseEventSource:mouseType:
mouseCursorPosition:mouseButton:)` + `.post(tap: .cghidEventTap)`) right when suppression
begins — the `.gridActive` → `.anchored` transition — at the cursor's current position.
Native drag has been tracking normally right up to that instant, so ending it there should
have no visible jump of its own, and macOS's native tracking for this window closes out
cleanly and on time instead of at the real mouse-up much later. Tagged via
`CGEventField.eventSourceUserData` with an arbitrary recognizable marker so
`InputEngine.handle(type:event:)` — which sees everything posted to this pipeline, including
its own synthetic event — passes it straight through without reprocessing it through the
gesture state machine as if it were a real user action.

**Real risk, explicitly discussed with and approved by the user before implementing** (not
assumed away): this tells macOS the mouse button is "up" while the user is still physically
holding it down. Every subsequent real `leftMouseDragged`/`leftMouseUp` is still handled by
this engine's own state machine exactly as before (unchanged) — only macOS's own native
drag-tracking perception of this one window's gesture end changes. What was *not* verifiable
without live testing: how macOS or the target app's own event handling reacts to receiving
further "dragged" events after being told the button already went up. Needs careful,
comprehensive retesting, not just a check for whether the flash is gone — see
`docs/MANUAL_VERIFICATION.md` for the added checks (stray drags on other windows, the target
window's own behavior right at the anchor moment, and re-confirming every earlier live-resize
fix — smoothness, correct final position, no stuck-click — still holds).

**Verified**: clean build, 15/15 tests, packaged app rebuilds and signs cleanly.

**REVERTED.** User testing found a real functional regression: releasing the mouse after a
live-resize gesture no longer completed the snap at all — it only completed on the user's
*next*, separate click. Root cause, exactly the risk flagged before implementing this:
telling macOS the button was "up" via the synthetic event actually desynced macOS's own
button-state tracking. When the user then *really* released the button, macOS's input layer
apparently didn't generate a new "up" transition — it already believed the button was up
from the synthetic event, so there was no state change left to report. The real mouse-up
event this engine depends on for `handleMouseUp` never arrived; `state` stayed `.anchored`
until the next click's mouse-up satisfied it instead (explaining exactly the "click again to
complete it" symptom).

This is a worse trade — a broken gesture completion — than the cosmetic flash it was meant to
fix. Fully reverted: `postSyntheticMouseUpToEndNativeDrag`, the `syntheticEarlyDragCloseMarker`
tag/check in `handle(type:event:)`, and the one call site in `handleFlagsChanged` are all
removed, not just disabled. Confirmed via `grep` that nothing referencing them remains.
Rebuilt, retested (15/15 tests, clean build/package) — back to the ninth/tenth fixes' behavior:
smooth drag, correct final position, no stuck-click, small cosmetic flash on release remains
unaddressed. `docs/MANUAL_VERIFICATION.md`'s "anchor-moment"/"stray-drag" checks added for this
attempt were removed along with the code they were testing for.

**Eighth lesson recorded**: synthesizing OS-level input events to manipulate a *different*
subsystem's (WindowServer's) internal tracking is fundamentally different from, and riskier
than, suppressing/observing real events — it can desync state in the OS layer itself, not just
this app's own state machine, in ways that are very hard to predict without live testing. The
explicit user sign-off obtained before attempting this was the right call; so is reverting
immediately and completely on the first sign of a real regression, rather than trying to
patch around a technique that's already shown it can silently break event delivery. The
cosmetic flash remains open with no attempted fix currently in place — see the tenth fix's
entry for the ruled-out theory and the note on where to look next (the *first*, immediate
`setFrame` call's own position-then-size two-step).
