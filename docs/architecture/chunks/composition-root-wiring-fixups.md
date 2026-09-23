# Composition-Root Wiring Fixups

Discovered while briefing implementation workers for the 7 remaining modules (everything
except `MacGriddleCore` and `GridEngine`, both already implemented directly — see
`core-contracts.md` and `grid-engine.md`). These are wiring-level mismatches between what
`app-shell-and-lifecycle.md` (chunk 8) *guessed* other modules' constructors look like and
what those modules' own chunks actually specify. None of them are Core-protocol conflicts
(those are already resolved in `core-contracts.md` §8) — these are all in the composition
root's own construction code, discovered by tracing each `AppDelegate` call site against its
real target.

**Resolution principle**: the module that owns a type (Permissions owns `PermissionsMonitor`,
`Overlay` owns `GridOverlayController`, etc.) is authoritative for that type's real shape.
`MacGriddle` (the executable/composition root) is the one that adapts — it's the only chunk
that guessed at everyone else's API, so it's the only one with real fixup work here. The two
exceptions (marked below) require a small, additive change on the *other* module's side too.

## 1. `PermissionsMonitor`, not `SystemPermissionsProvider`

`permissions-model.md` §3's real concrete class is `PermissionsMonitor`, `public init()`
(zero-arg — matches). App-shell's guessed name (`SystemPermissionsProvider`) was just wrong;
use `PermissionsMonitor()`.

## 2. `permissions.objectWillChange`, not a guessed `permissionsChanged` publisher

`PermissionsProviding` requires `ObservableObject` conformance (`core-contracts.md` §4), which
gives every conformer `objectWillChange` for free. App-shell-and-lifecycle.md §4's
`observePermissionChanges()` already `.sink`s on a publisher with the right shape
(`AnyPublisher<Void, Never>`-compatible usage) — only the source needs to change:

```swift
permissionsSubscription = permissions.objectWillChange
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.handlePermissionsChanged() }
```

No `Publishers.CombineLatest` construction needed. Also rename `isAccessibilityTrusted`/
`isInputMonitoringTrusted` → `isAccessibilityGranted`/`isInputMonitoringGranted` everywhere
in chunk 8's code (already listed in `core-contracts.md` §8, repeated here since it's in the
same neighborhood).

## 3. `OnboardingCoordinator` doesn't exist anywhere yet — build it in `MacGriddle`

`permissions-model.md` explicitly declines to own "onboarding screen sequencing," leaving it
to "whichever chunk ends up owning the actual enum" (its own words, §4). Nobody claimed it.
**The `MacGriddle` worker must build a minimal one** — a small SwiftUI view + hosting
`NSWindow`, driven directly by:
- `permissions-model.md` §4's `OnboardingStage`/`MissingPermission` enums and its state table
  (`welcome` → `requestingAccessibility` → `requestingInputMonitoring` → `readyToUse`, plus
  `degraded(missing:)`).
- `PermissionsMonitor`'s `isAccessibilityGranted`/`isInputMonitoringGranted`/
  `requestAccessibility()`/`requestInputMonitoring()` to drive transitions and button actions.
- `permissions-model.md` §4's confirmed deep-link URLs (`SystemSettingsDeepLink.accessibility`/
  `.inputMonitoring`) for the "Open System Settings" fallback buttons.

Keep it simple: one view that switches on the current stage, one button per stage doing the
one action that stage calls for. This does not need to be polished — it needs to exist and be
functionally correct; visual polish is not this milestone's job.

## 4. `GridOverlayController` requires an `OverlayAppearance` at construction, not zero-arg

`overlay-rendering.md`'s real type is `GridOverlayController(appearance: OverlayAppearance)`
— not the zero-arg `OverlayController()` chunk 8 guessed. Build the initial `OverlayAppearance`
from `settingsStore`'s color/opacity fields (exactly as `preferences-ui.md` §6's own
illustrative snippet already shows) *before* constructing it. For live updates when
Preferences changes, call `.updateAppearance(_:)` — a small addition
`input-engine-and-state-machine.md` already flags as needed on `GridOverlayController`; the
**`Overlay` worker should add this one method**:

```swift
// Addition to GridOverlayController (overlay-rendering.md's real type):
func updateAppearance(_ appearance: OverlayAppearance) {
    self.appearance = appearance
}
```

## 5. `InputEngine` takes no `settings:` parameter

Already fully resolved in `input-engine-and-state-machine.md` §9's own Reconciliation
section: real signature is `InputEngine(windowControl:overlay:permissions:)` (no `settings:`
— `Input` doesn't depend on `Preferences`), plus a separate
`configure(gridConfiguration:liveResizeEnabled:)` call the composition root makes once at
launch and again whenever those specific `SettingsStore` fields change.

## 6. `StatusBarController` — real init shape, plus one added parameter

`statusbar-menu.md`'s real signature is:

```swift
init(
    permissionsProvider: PermissionsProviding,
    engineControl: EngineControlBridge,
    openAccessibilitySettings: @escaping () -> Void,
    openInputMonitoringSettings: @escaping () -> Void
)
```

— not chunk 8's guessed `(permissions:settings:initialEngineEnabled:onOpenPreferences:onToggleEngineEnabled:onQuit:)`.
Three things to fix, split between the two workers:

**a) No `.install()` call.** Constructing `StatusBarController` already makes the status item
appear (statusbar-menu.md §5: "constructing an `NSStatusItem`... already makes it appear").
Drop the guessed `.install()` call entirely.

**b) `openPreferences()`'s singleton guess needs to become a real, injected instance —
`StatusBar` worker: add a `preferencesWindowController: PreferencesWindowController`
parameter to `StatusBarController.init`, and change `openPreferences()` to call
`preferencesWindowController.show()`.** `statusbar-menu.md`'s own text already flags this
exact call site as its lowest-confidence guess (`PreferencesWindowController.shared.show()`,
a singleton) — `preferences-ui.md`'s real `PreferencesWindowController` is instance-based
(`init(settings:)`, constructed and owned by the composition root per that chunk's §6), not a
singleton. `MacGriddle` worker: construct `PreferencesWindowController` once, and pass that
same instance into `StatusBarController`'s init — both the composition root and `StatusBar`
end up sharing ownership of it, which is fine (ordinary ARC shared ownership).

**c) `EngineControlBridge.isEnabledPublisher` needs a real publisher, not an imperative
`setEngineEnabled(_:)` method call (which doesn't exist on the real `StatusBarController`).**
`MacGriddle` worker: back it with a `CurrentValueSubject`:

```swift
import Combine

let engineEnabledSubject = CurrentValueSubject<Bool, Never>(false)

let engineControl = EngineControlBridge(
    isEnabled: { engineEnabledSubject.value },
    isEnabledPublisher: engineEnabledSubject.eraseToAnyPublisher(),
    setEnabled: { [weak self] enabled in self?.setEngineEnabled(enabled) }
)
```

`setEngineEnabled(_:)` (chunk 8 §4's existing method, called both from the manual toggle and
from permission-loss handling) sets `engineEnabledSubject.value = engineEnabled` instead of
calling a `statusBarController?.setEngineEnabled(...)` that doesn't exist on the real type.

**d) No `onQuit` closure parameter.** `statusbar-menu.md`'s real quit item uses
`target = nil` so the action flows up the responder chain to `NSApplication.terminate(_:)`
automatically (§2 of that chunk) — there's nothing for the composition root to supply.

## Summary of who changes what

| Worker | Change |
|---|---|
| `MacGriddle` (App Shell) | All of §1, §2, §3 (build the onboarding UI), §4's construction-order fix, §5, §6's construction-order + `CurrentValueSubject` (§6c) |
| `Overlay` | Add `updateAppearance(_:)` (§4) |
| `StatusBar` | Add `preferencesWindowController: PreferencesWindowController` parameter, use it in `openPreferences()` (§6b) |
| `Permissions`, `WindowControl`, `Preferences`, `Input` | No changes beyond what their own chunks already specify |
