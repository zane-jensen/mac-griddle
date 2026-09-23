# MacGriddle Architecture — Overview

This is the light overview that seeds 10 parallel, independently-written architecture chunks. Every chunk author reads this file plus `docs/RESEARCH.md`, then writes ONLY their own file under `docs/architecture/chunks/`. A combiner agent later merges all 10 into `docs/architecture/MASTER_PLAN.md`.

## Product spec (recap — full detail in docs/RESEARCH.md)

MacGriddle is a macOS menu-bar utility that clones WindowGrid's grid-based window resizing, adapted for Magic Mouse/trackpad:

1. Left-click and hold a window's title bar (normal drag start).
2. While still holding the mouse button, hold ⌥ Option → a grid overlay appears on every connected screen.
3. Hover the cell that should be the start corner; **release ⌥ Option** to anchor it.
4. Move to the end cell — live preview of the covering rectangle.
5. Release the mouse button → the window snaps to that rectangle via the Accessibility API.
6. Release the mouse button while ⌥ is still held (before anchoring) → cancels, window returns untouched.
7. Tap ⌥ again after anchoring → toggles into free-resize mode (arbitrary rectangle, no grid snap).
8. A global panic hotkey force-resets the gesture state machine if it ever gets stuck.

## Fixed cross-cutting decisions (every chunk must follow these — do not re-litigate)

- **Min macOS target: 13.0 (Ventura)** — enables `SMAppService` for launch-at-login without a separate helper-app target.
- **Frameworks**: AppKit for the engine (event tap, AX, overlay windows, status item); SwiftUI (via `NSHostingController`) for Preferences/Onboarding UI.
- **No full Xcode on this dev machine** (Command Line Tools only) → no asset catalogs. The menu bar icon must be an SF Symbol (`NSImage(systemSymbolName:accessibilityDescription:)`), not a custom `.icns`/asset catalog entry.
- **Default grid: 6 columns × 4 rows**, user-configurable later via Preferences.
- **Default resize behavior: snap-on-release** — compute and apply the final frame once, on mouse-up. Live-resize-while-dragging is a later Preferences toggle, not required for v1 correctness.
- **Panic hotkey suggestion: ⌃⌥⇧Escape** (Ctrl+Option+Shift+Escape) — force-resets the gesture state machine.
- **Two independently-gated permissions** (critical finding from `docs/RESEARCH.md` — do not conflate them):
  - **Accessibility** — required for AX window read/move/resize (`AXUIElement*` APIs).
  - **Input Monitoring** — required for the listen-only `CGEventTap`.
  - Granting one does NOT grant the other. Every chunk touching either must treat them as two separate booleans with two separate system prompts/System Settings panes.
- **Coordinate space**: `CGEventTap` event locations and AX frames both live in **Quartz/global-display space** (top-left origin, Y increases downward, anchored to the *primary* display). AppKit's `NSScreen`/`NSEvent` live in **Cocoa space** (bottom-left origin, Y increases upward). Conversion is only needed at AppKit seams (placing overlay `NSWindow`s, enumerating `NSScreen`s) — the CGEventTap → AX hot path needs zero conversion since both already agree. **Always flip against `NSScreen.screens[0].frame.height`** (the primary screen), never `NSScreen.main` (which tracks keyboard focus and will produce "snapped to the wrong monitor" bugs if used).

## Fixed target project layout (chunks design *content* for these, not renaming/restructuring them)

Multi-target Swift Package Manager package, `platforms: [.macOS(.v13)]`:

| Target | Depends on | Concern |
|---|---|---|
| `MacGriddleCore` | — | shared protocols/types |
| `GridEngine` (+ `GridEngineTests`) | — | pure grid math, no AppKit import |
| `WindowControl` | Core | AX window lookup/read/write frame, coordinate conversion |
| `Overlay` | Core, GridEngine | per-screen grid overlay `NSWindow`s + rendering |
| `Permissions` | Core | Accessibility + Input Monitoring check/request/observe |
| `Preferences` | Core | SwiftUI settings window + `UserDefaults`-backed store |
| `StatusBar` | Core, Preferences | `NSStatusItem` + menu |
| `Input` | Core, GridEngine, WindowControl, Overlay, Permissions | `CGEventTap` + gesture state machine; orchestrates the others |
| `MacGriddle` (executable) | all of the above | app entry point, composition root |

## The 10 chunks

Each chunk author writes **only** `docs/architecture/chunks/<file>.md` — pure documentation (concrete Swift-flavored signatures/snippets and mermaid diagrams are expected and encouraged inside the markdown), **no code files, no `swift build`**.

1. `project-structure.md` — `Package.swift` target/dependency details exactly as the table above, directory conventions, `.app` bundle packaging strategy (`Scripts/build-app.sh`, `Info.plist` with `LSUIElement=1`), launch-at-login via `SMAppService`.
2. `core-contracts.md` — the actual protocol/type signatures for `GestureState`, `GridConfiguration`, `WindowHandle`, `WindowControlling`, `PermissionsProviding`, plus anything else needed for clean module boundaries. Heavy doc comments on coordinate spaces and units — this is the single most load-bearing chunk since every other module codes against it.
3. `permissions-model.md` — the Accessibility + Input Monitoring request/observe/check flow as its own concern: what `PermissionsProviding` (from chunk 2) looks like in practice, onboarding states exposed to the rest of the app, deep-linking to the right System Settings pane for each.
4. `input-engine-and-state-machine.md` — `CGEventTap` setup (listen-only, run loop wiring) and the full gesture state machine (mermaid diagram) per the product spec above, including exactly where each of the two permissions gates a transition, and the panic hotkey.
5. `window-control-and-coordinates.md` — AX window-under-cursor resolution (`AXUIElementCopyElementAtPosition` → walk to window ancestor), frame get/set (`kAXPositionAttribute`/`kAXSizeAttribute`), the Cocoa↔Quartz coordinate conversion utility, restore-on-cancel.
6. `grid-engine.md` — the pure grid math engine API only: cell rects for `(cols, rows)` over a screen frame, anchor+cursor → covering rectangle, free-resize passthrough. No AppKit, no rendering concerns — must be fully unit-testable.
7. `overlay-rendering.md` — per-screen grid overlay `NSWindow` design (window level, `ignoresMouseEvents`, show/hide, selection-rectangle highlight, free-resize visual variant). Consumes `GridEngine`'s output; does not compute it.
8. `app-shell-and-lifecycle.md` — `.accessory` activation policy, `main.swift`/`AppDelegate` shape, how the composition root wires `Input`/`Permissions`/`StatusBar`/`Preferences` together at launch, the launch-at-login call site (references chunk 1's `SMAppService` design).
9. `preferences-ui.md` — SwiftUI settings window fields (grid size, colors/opacity, live-vs-snap-on-release toggle, launch-at-login toggle, panic hotkey display), the `UserDefaults`-backed `SettingsStore` shape and defaults.
10. `statusbar-menu.md` — `NSStatusItem` icon/menu contents (Preferences…, permission status / grant shortcuts if either permission is missing, enable/disable toggle, About, Quit), how it observes and reflects live permission + engine-enabled state.

## Next steps after chunking

A combiner agent merges all 10 chunks + this overview into `docs/architecture/MASTER_PLAN.md`, reconciling any naming/interface mismatches between chunks (e.g. if two chunks assumed slightly different shapes for the same shared type). After that, the orchestrator scaffolds the real `Package.swift` + Core contract Swift files from the master plan, then dispatches 8 implementation worker agents (one per eventual module — `Preferences` and `StatusBar` chunks feed separate workers, `App Shell` chunk feeds its own worker, etc.) using the master plan as their shared source of truth.
