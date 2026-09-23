# MacGriddle — Research

This document seeds the design and implementation of MacGriddle, a macOS port of the
WindowGrid "hold-a-modifier-while-dragging" grid window-snapping gesture. It has two parts:

- **Part A** — the interaction mechanics of the original WindowGrid and its Windows 11
  successor WinGrid11, and the macOS gesture adaptation that MacGriddle implements.
- **Part B** — macOS feasibility research: which APIs make this possible, their exact
  signatures, their permission/sandboxing requirements, the coordinate-system trap that
  causes most window-manager bugs, and a validation pass against existing open-source
  macOS window managers.

---

## Part A — WindowGrid Mechanics

### A.1 Original WindowGrid (windowgrid.net, Joshua Wilding)

WindowGrid was a free Windows utility (C#/WPF + a native hook component) released around
2014 and last updated in December 2015 before development quietly stopped. It gave "the
normally useless right mouse button" a job during a window drag:

1. Left-click and hold a window's title bar — a normal drag start.
2. While still holding the left button, press and hold the **right** mouse button. A grid
   overlay appears on every monitor (default 12x6, configurable, e.g. 4x4).
3. Hover the cell that should be the window's start corner.
4. Release the right button to **anchor** that corner.
5. Continue moving the mouse to the end corner — the window resizes to the rectangle
   spanning start-to-end, snapped to grid lines (live-resize or snap-on-release, depending
   on settings).
6. Release the left button to commit the new size/position.

Configurable: grid dimensions, live-resize vs. snap-on-release, grid colors/opacity
(`Settings.xml`), showing window contents while dragging, portable or installed mode,
transposed grid on portrait monitors. Known weaknesses by the end of its life: DPI-scaling
drift when moving windows between monitors with different scaling factors, a DLL-injection
architecture (`WindowGrid32.dll`) that modern antivirus/EDR products flag, and general
inconsistency on Windows 11 with newer (Electron/Chromium, WPF-successor) app frameworks.
Development stopped around 2016; the project's Bitbucket issue tracker went unanswered
for years afterward.

### A.2 WinGrid11 (github.com/jreeseiii-tech/WinGrid11) — 2026 spiritual successor

WinGrid11 reimplements the same gesture as a single-process, non-DLL-injection .NET 8
app, specifically to fix the failure modes above. Its own README states the gesture
identically to the summary above:

> You hold left-click on a window's title bar like you're about to drag it. While still
> holding, you tap right-click. A grid pops up over every monitor. You drag from one
> corner of the rectangle you want to the other corner. You release left-click. The
> window snaps to that rectangle.

Additional documented behaviors:

- **Cancel**: releasing the left button *while the right button is still held* cancels the
  gesture entirely.
- **Free-resize toggle**: tapping the right button *again* after the start corner is
  anchored flips the gesture into a free-resize mode — an arbitrary rectangle, no grid
  snapping. This is reversible mid-gesture.
- **Panic hotkey**: `Ctrl+Alt+Shift+Q`, registered via `RegisterHotKey`, force-resets the
  internal state machine if it ever gets stuck (e.g. a missed mouse-up event).

**Why WinGrid11 changed the resize model.** The original WindowGrid live-resized the
window on every grid-line crossing. This is what corrupts Electron/Chromium apps' redraw
paths (VS Code, Discord, Slack, Obsidian) — the constant resize storms during a drag
produce visual corruption, black render regions, or content shifting inside the window.
WinGrid11's fix: keep the real window untouched and stationary, show only a *preview*
rectangle in the overlay, and apply exactly one clean resize on mouse-up. Live-resize is
kept as an opt-in toggle for apps that handle it fine.

**Architecture notes (directly informative for a from-scratch reimplementation):**

- Single process, no DLL injection.
- Drag detection via `SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART/END, ..., WINEVENT_OUTOFCONTEXT)`
  — out-of-process, doesn't trip AV/EDR heuristics, and doesn't break apps like Stardock
  Groupy2 that wrap tab groups in a host window.
- `WH_MOUSE_LL` (low-level mouse hook) purely to detect the right-mouse-button trigger;
  runs only inside WinGrid11's own process.
- The panic hotkey uses `RegisterHotKey` instead of the mouse/keyboard hook, so the
  process never has to intercept arbitrary keystrokes just to catch one combo.
- Per-Monitor v2 DPI awareness baked into the app manifest; **all grid math is done in
  physical pixels of the monitor under the cursor**, and each overlay window is positioned
  with `SetWindowPos` in physical coordinates — this is what fixes the original app's
  mixed-DPI drift.
- `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` compensation, so the *visible* window
  edges (not the invisible resize-border rect Win32 reports by default) line up with the
  chosen grid cells.
- Snap-on-release is implemented by exiting the OS's modal move loop early (a synthesized
  `SendInput(ESC + LBUTTONUP)`) and applying a single `SetWindowPos` on the real
  `WM_LBUTTONUP`.
- Every `HWND` seen by the WinEvent watcher is resolved via `GetAncestor(GA_ROOT)` before
  being snapped, so a wrapped tab-host window (Groupy2) moves as a whole instead of just
  its inner tab.

Configurable via `%AppData%\WinGrid11\settings.json`: grid dimensions, live vs.
snap-on-release, free-resize on/off and "right-click again switches to free", keep
windows on-screen when a minimum size would push them off, block cursor interaction with
background apps during the gesture, cell/highlight/stroke colors, and launch on Windows
startup.

*(These mechanics were verified directly against the WinGrid11 GitHub README and multiple
independent descriptions/reviews of the original WindowGrid; both sources are consistent
with the summary given above.)*

### A.3 The macOS Adaptation — MacGriddle's target gesture

Magic Mouse and trackpads have no reliable way to hold a secondary click *while* a
primary-button drag is already in flight (no physical second button, and trackpad
"right-click" is itself a modifier/gesture, not a hardware button held independently of the
first). MacGriddle therefore replaces the right-mouse-button trigger with **holding the
Option key (⌥)**. Every other mechanic ports directly:

1. Left-click and hold a window's title bar (drag start).
2. While still holding the mouse button, hold **⌥ Option** — a grid overlay appears on
   every screen.
3. Hover the start cell; **release ⌥ Option** to anchor it (mirrors "release RMB to
   anchor" from WinGrid11).
4. Move to the end cell — live preview of the covering rectangle.
5. Release the mouse button — the window snaps to that rectangle via the Accessibility
   API (mirrors WinGrid11's snap-on-release default, for the same Electron/Chromium
   redraw-corruption reason).
6. Release the mouse button *while ⌥ is still held*, before anchoring — cancels the
   gesture (mirrors "release LMB while RMB still held" cancel).
7. Tap ⌥ again *after* anchoring — toggles free-resize mode (mirrors "tap RMB again").
8. A global panic hotkey, e.g. **Ctrl+Option+Shift+Escape**, force-resets the state
   machine (mirrors `Ctrl+Alt+Shift+Q`).

The state machine is therefore: `idle → dragging → gridActive(unanchored) →
gridActive(anchored) → resizing → committed`, with `dragging + optionReleaseBeforeAnchor
→ cancelled` and `anchored + optionTap → freeResize` as side branches, and a hotkey that
forces any state back to `idle`. This maps almost mechanically onto Part B's
`CGEventTap` callback (Section B.2) as a flags-changed/mouse-event-driven state machine.

---

## Part B — macOS Feasibility Research

**Bottom line up front:** every mechanic above is implementable on macOS 13+ using only
Apple's *public* Accessibility API (`AXUIElement`) and Quartz Event Services
(`CGEventTap`), the same combination used by Rectangle, AeroSpace, and (for its core
window operations) yabai. See Section B.5. The app **cannot be sandboxed** and therefore
**cannot ship on the Mac App Store**; it must be distributed directly (Developer
ID–signed + notarized). This is a hard constraint, not a risk — every comparable tool
made the same trade.

### B.1 Accessibility API (AXUIElement / ApplicationServices)

The Accessibility API lets a trusted process inspect and drive the UI object tree of
*every other running application* — this is the only way, short of private/undocumented
SPIs, to read or set another app's window frame on macOS.

#### B.1.1 Requesting trust

```swift
import ApplicationServices

/// Returns true only if the user has already granted Accessibility access.
/// Never prompts.
func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// Returns current trust state, and if not yet trusted, prompts the user
/// (shows the system "would like to control this computer" dialog, or
/// deep-links to System Settings > Privacy & Security > Accessibility).
func requestAccessibilityTrust() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options: NSDictionary = [promptKey: true]
    return AXIsProcessTrustedWithOptions(options)
}
```

Notes confirmed via Apple's own docs and numerous independent sources:

- `kAXTrustedCheckOptionPrompt` is an `Unmanaged<CFString>!` global — always unwrap with
  `.takeUnretainedValue()`.
- The prompt is **one-shot per code identity**: once denied, macOS will not re-show the
  system dialog on a later call; you must send the user to System Settings manually (e.g.
  via `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)`).
- Re-signing the binary (including plain Xcode rebuilds during development) can be seen
  by TCC as a new code identity, forcing the permission to be re-granted. This is a known
  developer-experience papercut, not a bug in your code.
- `AXIsProcessTrustedWithOptions` requires the app **not be sandboxed** to actually show
  the checkbox/add the app to the Accessibility list; a sandboxed app can call it but it
  will just keep returning `false`.

#### B.1.2 Finding the window under the mouse cursor

The building block is `AXUIElementCopyElementAtPosition`, called on a special
*system-wide* accessibility object, **not** on any particular app's element:

```swift
import ApplicationServices

enum AXQuery {
    /// A single, process-wide system element used as the root for
    /// position-based hit-testing across every other application.
    static let systemWide = AXUIElementCreateSystemWide()
}

/// Returns the AXUIElement window at the given point, in global
/// top-left-origin ("Quartz"/CoreGraphics) screen coordinates.
/// See Section B.3 for why this coordinate space matters.
func windowElement(at point: CGPoint) -> AXUIElement? {
    var hitElement: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(
        AXQuery.systemWide,
        Float(point.x),
        Float(point.y),
        &hitElement
    )
    guard err == .success, let element = hitElement else { return nil }
    return resolveToWindow(element)
}

/// AXUIElementCopyElementAtPosition returns the *deepest* element at that
/// point (e.g. a button, a text field, a title-bar control) — not
/// necessarily the window itself. Walk up to the owning window.
private func resolveToWindow(_ element: AXUIElement) -> AXUIElement? {
    // Fast path: is this element itself a window?
    var roleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
       let role = roleRef as? String,
       role == kAXWindowRole as String {
        return element
    }

    // Otherwise most elements expose kAXWindowAttribute: a direct pointer
    // to their containing window, without needing to walk kAXParentAttribute
    // by hand. (Apple's header docs: "Required for any element that has an
    // element of role kAXWindowRole somewhere in its parent chain.")
    var windowRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef)
    if err == .success, let window = windowRef {
        return (window as! AXUIElement)
    }

    // Fallback for the rare element that has neither: walk kAXParentAttribute
    // manually until role == kAXWindowRole or the chain ends.
    var current = element
    while true {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef else { return nil }
        current = parent as! AXUIElement
        var parentRoleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &parentRoleRef) == .success,
           let parentRole = parentRoleRef as? String,
           parentRole == kAXWindowRole as String {
            return current
        }
    }
}
```

This exact "role check, then `kAXWindowAttribute`, then walk `kAXParentAttribute` as a
last resort" pattern is the one used in real window-manager codebases (e.g. the
`kwm`/yabai lineage). `kAXTopLevelUIElementAttribute` looks like a shortcut for the same
purpose but is documented to return `nil` for some floating/panel-style windows, so prefer
`kAXWindowAttribute` and keep the parent-walk as the final fallback, not the primary path.

**Coordinate space warning:** `AXUIElementCopyElementAtPosition` explicitly takes
"top-left relative screen coordinates" — i.e. Quartz/global-display space, not AppKit's
`NSScreen`/`NSEvent` space. See Section B.3.

#### B.1.3 Reading a window's frame

Position and size come back as `AXValue`-boxed `CFTypeRef`s that must be unboxed with
`AXValueGetValue` into a `CGPoint`/`CGSize`:

```swift
func frame(of window: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?

    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
    else { return nil }

    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    else { return nil }

    return CGRect(origin: origin, size: size)
}
```

`AXValueGetValue(_:_:_:)` returns `Bool` (success/failure of the unbox), separate from the
`AXError` returned by the `AXUIElementCopy...` call that fetched the boxed value in the
first place — both must be checked.

#### B.1.4 Moving / resizing another app's window

Setting works the same way in reverse: box a `CGPoint`/`CGSize` into an `AXValue` with
`AXValueCreate`, then `AXUIElementSetAttributeValue`:

```swift
@discardableResult
func setFrame(_ frame: CGRect, of window: AXUIElement) -> Bool {
    var origin = frame.origin
    var size = frame.size

    guard let positionValue = AXValueCreate(.cgPoint, &origin),
          let sizeValue = AXValueCreate(.cgSize, &size)
    else { return false }

    // Apple's own sample code and multiple window managers set position
    // before size — matters when shrinking a window that's pinned to the
    // bottom/right of a screen, since setting size first can clip it.
    let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

    return positionResult == .success && sizeResult == .success
}
```

Some windows report `kAXSizeAttribute`/`kAXPositionAttribute` as not settable (check with
`AXUIElementIsAttributeSettable`) — e.g. some non-resizable utility panels — and the call
simply fails with a non-`.success` `AXError` rather than crashing; always check the
return value and skip that window rather than force-unwrapping.

#### B.1.5 AXError handling pattern

`AXError` is a C enum bridged to Swift; **never force-unwrap an `AXUIElementCopy...`
call's out-parameter without checking the returned `AXError` first** — a failed call
leaves the `CFTypeRef?` out-parameter in an undefined/nil state. The common cases you will
actually hit in this project:

| Case | Meaning |
|---|---|
| `.success` | Call succeeded, out-parameter is valid. |
| `.apiDisabled` | Accessibility is not (or no longer) trusted for this process — re-check `AXIsProcessTrusted()`. |
| `.invalidUIElement` | The `AXUIElement` refers to a window/app that has since closed/quit — drop your cached reference. |
| `.cannotComplete` | The target app is unresponsive/not playing along (common with some Electron apps mid-animation) — retry once, then give up gracefully. |
| `.attributeUnsupported` / `.noValue` | The element doesn't have this attribute (e.g. asking a non-window element for `kAXPositionAttribute`) — not a bug, just means "try the fallback path." |

Every `AXUIElementCopyAttributeValue`/`AXUIElementSetAttributeValue`/
`AXUIElementCopyElementAtPosition` call site in MacGriddle should follow the same
`guard ... == .success else { return / continue }` shape shown in the snippets above —
there is no scenario in this app where force-unwrapping an AX call is safe, because the
window on the other end is owned by a process MacGriddle does not control and can
disappear or misbehave at any time.

---

### B.2 CGEventTap (Quartz Event Services)

MacGriddle needs one global, **listen-only** tap watching `leftMouseDown`,
`leftMouseDragged`, `leftMouseUp`, and `flagsChanged` (for the Option key) across *every*
application, not just its own windows.

```swift
import CoreGraphics

final class GlobalMouseAndModifierTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,       // session-wide, sees events for every app
            place: .headInsertEventTap,
            options: .listenOnly,          // NEVER .defaultTap: we must not be able
                                            // to swallow/alter other apps' input.
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                let tapSelf = Unmanaged<GlobalMouseAndModifierTap>
                    .fromOpaque(refcon!).takeUnretainedValue()
                tapSelf.handle(type: type, event: event)
                // Listen-only taps ignore whatever is returned, but the
                // callback signature still requires returning the event.
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // event.location is already in Quartz/top-left global screen space —
        // the SAME space AXUIElementCopyElementAtPosition expects. No
        // coordinate conversion needed for this part. See Section B.3.
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            let point = event.location
            // feed `point` directly into the AX lookup / state machine
            _ = point
        case .flagsChanged:
            let optionHeld = event.flags.contains(.maskAlternate)
            _ = optionHeld
        default:
            break
        }
    }
}
```

#### B.2.1 Permissions — the biggest surprise in this research

This is the single most important, and least obvious, finding: **a listen-only
`CGEventTap` is gated by Input Monitoring, not Accessibility.** Apple engineering has
confirmed this directly on the developer forums: *"Specifying `defaultTap` triggers the
Accessibility permission request, while specifying `listenOnly` triggers the Input
Monitoring permission request."* MacGriddle's design explicitly calls for a listen-only
tap (the plan is correct not to want an active/filtering tap), which means:

- The AX window manipulation (Section B.1) is gated by **Accessibility**
  (`AXIsProcessTrusted`/`AXIsProcessTrustedWithOptions`).
- The global mouse/modifier tap (this section) is gated by a **separate** TCC permission,
  **Input Monitoring**, checked/requested with its own pair of functions:

```swift
import CoreGraphics

func hasInputMonitoringAccess() -> Bool {
    CGPreflightListenEventAccess()
}

/// Triggers the system "would like to receive keystrokes/pointer events
/// from other applications" prompt on first call. Like the Accessibility
/// prompt, this is effectively one-shot — if denied, send the user to
/// System Settings > Privacy & Security > Input Monitoring instead of
/// calling this again.
func requestInputMonitoringAccess() -> Bool {
    CGRequestListenEventAccess()
}
```

MacGriddle's onboarding therefore needs **two** separate permission requests/checks, not
one — first-run UX should explain both (Accessibility for "move other apps' windows",
Input Monitoring for "notice when you hold Option while dragging"), since granting one
does not imply or grant the other. One more nuance worth designing around: unlike the
Accessibility API, Input Monitoring access is explicitly documented as available to
*sandboxed* apps, including ones on the Mac App Store — it is the AX control of other
apps' windows (Section B.1), not the event tap itself, that forces MacGriddle out of the
sandbox. If a future version of this app ever dropped the "move other apps' windows"
feature, the event-tap half alone would not require abandoning the sandbox.

#### B.2.2 Run loop and lifecycle

- `CGEvent.tapCreate` returns `nil` (not a thrown error) if permission is missing or tap
  creation otherwise fails — always `guard let`, never force-unwrap.
- The tap must be attached to a run loop that actually spins: `CFRunLoopAddSource(...,
  .commonModes)` on whichever thread will run `CFRunLoopRun()` (main thread's run loop is
  fine and is what every example above uses — a menu-bar-only app with no windows still
  runs the main run loop via `NSApplication`/`AppKit`, so no dedicated thread is required).
- macOS can disable an event tap it judges to be slow or misbehaving
  (`kCGEventTapDisabledByTimeout`/`...ByUserInput` show up as event types delivered *to
  your own callback*); production code should watch for those and call
  `CGEvent.tapEnable(tap:enable:true)` again to self-heal.
- If Accessibility/Input Monitoring is revoked while the tap is alive (user toggles the
  checkbox off mid-session), the tap silently stops delivering events rather than
  crashing — poll `AXIsProcessTrusted()`/`CGPreflightListenEventAccess()` periodically (or
  re-check on `NSApplication.didBecomeActiveNotification`) and prompt the user to
  re-grant if a permission was revoked.

#### B.2.3 Why this (combined with B.1) forces the app out of the sandbox

App Sandbox blocks two things MacGriddle fundamentally needs at the same time:
`AXUIElementCopyElementAtPosition`/`AXUIElementSetAttributeValue` targeting *other*
processes' UI (confirmed directly on Apple's own developer forums: sandboxed apps get
`AXError` failures, not success, even with the Accessibility checkbox checked), and,
separately, some of the same low-level input capabilities in stricter combinations. In
practice every non-trivial macOS window manager (Section B.5) ships **unsandboxed,
Developer-ID-signed and notarized**, distributed outside the Mac App Store. MacGriddle
should plan for the same distribution model from day one rather than discovering the
sandbox conflict late.

---

### B.3 Coordinate System Mismatch (the #1 source of "wrong monitor" bugs)

Two different global coordinate systems are in play, and mixing them without converting
is, by a wide margin, the most common bug class in hand-rolled macOS window managers:

| | Origin | Y direction | Used by |
|---|---|---|---|
| **Cocoa** (AppKit) | Bottom-left of the *primary* screen | Increases **upward** | `NSScreen.frame`/`.visibleFrame`, `NSEvent.mouseLocation`, `NSWindow.frame`/`setFrameOrigin` |
| **Quartz** (CoreGraphics / Accessibility) | Top-left of the *primary* screen | Increases **downward** | `AXUIElementCopyElementAtPosition`, `kAXPositionAttribute`/`kAXSizeAttribute`, `CGEvent.location`, `CGWindowListCopyWindowInfo`, `CGDisplayBounds` |

Both systems place monitors in the *same relative arrangement* (a monitor to the left of
the primary has negative X in both; the disagreement is purely about where Y=0 is and
which way Y grows), which is exactly why the bug is so easy to introduce and so confusing
to debug: X-only test cases work fine, and only multi-monitor Y-axis cases (or a
single-monitor setup where the two systems are numerically close enough to look "almost
right") expose the mismatch.

#### B.3.1 The conversion

```swift
import AppKit

/// Converts a rectangle from Cocoa (AppKit, bottom-left origin, Y-up)
/// screen space to Quartz (CoreGraphics/Accessibility, top-left origin,
/// Y-down) screen space, or vice versa — the transform is its own inverse.
///
/// CRITICAL: always flip relative to the height of the PRIMARY screen
/// (`NSScreen.screens[0]`), never `NSScreen.main` (which is whichever
/// screen currently contains the key window, and changes as focus moves).
/// Quartz's global origin is defined relative to the primary display, so
/// flipping against the wrong screen's height is what actually produces
/// "resizes onto the wrong monitor" / "off by one screen height" bugs on
/// multi-monitor setups — this exact confusion shows up repeatedly in
/// window-manager bug trackers and Stack Overflow threads.
func flippedRect(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(
        x: rect.origin.x,
        y: primaryScreenHeight - rect.origin.y - rect.height,
        width: rect.width,
        height: rect.height
    )
}

func primaryScreenHeight() -> CGFloat {
    // .screens[0] is documented to be the screen containing the menu bar /
    // whichever display is set as "primary" in System Settings > Displays
    // arrangement — this is the correct, stable reference for both
    // directions of the conversion. Do NOT use NSScreen.main here.
    NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
}
```

For a single point (e.g. converting `NSEvent.mouseLocation` into Quartz space to compare
against an AX frame): `quartzPoint.y = primaryScreenHeight - cocoaPoint.y`.

#### B.3.2 Where MacGriddle actually needs this (and where it doesn't)

This turns out to be narrower than it first appears, because of one convenient fact:

- **`CGEvent.location`**, read inside the `CGEventTap` callback (Section B.2), is
  **already in Quartz coordinates** — the same space `AXUIElementCopyElementAtPosition`
  and `kAXPositionAttribute` use. Since MacGriddle's entire mouse-tracking pipeline is
  built on a `CGEventTap`, the hot path (cursor position → hit-test → window frame math)
  needs **zero conversions** end to end.
- The conversion *is* required at the seams where AppKit enters the picture:
  - Positioning the **grid-overlay `NSWindow`s** (one per screen) — `NSWindow.setFrame`
    takes Cocoa coordinates, so grid geometry computed in Quartz space (to match the AX
    frames it's snapping windows to) must be flipped back before handing it to AppKit.
  - Enumerating `NSScreen.screens` to build per-monitor grids — each screen's `.frame` is
    in Cocoa space and must be flipped to line up with AX/Quartz window frames from
    Section B.1.
  - Anywhere `NSEvent.mouseLocation` is used instead of a `CGEventTap`-provided location
    (e.g. in incidental AppKit-level code, tooltips, etc.).
- **Not** needed: any pure AX-to-AX or `CGEventTap`-to-AX comparison, since both already
  live in Quartz space.

Making this seam explicit in the implementation (e.g. a `QuartzRect`/`CocoaRect` newtype
pair, or at minimum consistent naming and a single shared `flippedRect`/`primaryScreenHeight`
helper) is worth the small amount of ceremony — this is exactly the class of bug that is
easy to introduce once, ship, and then only notice when a user with a monitor arranged
above or to the side of their primary display reports "windows snap to the wrong screen."

---

### B.4 Launch at Login (SMAppService)

macOS 13 Ventura replaced the old `SMLoginItemSetEnabled`/helper-app-in-`LSSharedFileList`
pattern with `SMAppService`, which needs no separate helper bundle for the common
"launch this same app at login" case:

```swift
import ServiceManagement

enum LaunchAtLogin {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail (e.g. user removed it from Login Items
            // in System Settings mid-session) — surface this in the UI
            // rather than assuming the toggle silently succeeded.
        }
    }
}
```

`SMAppService.Status` cases worth handling explicitly: `.notRegistered`, `.enabled`,
`.requiresApproval` (registered, but the user must flip it on in System Settings >
General > Login Items — worth deep-linking there), and `.notFound`. Because the user can
remove the login item from System Settings at any time outside the app, the UI toggle
should read `SMAppService.mainApp.status` live rather than caching its own boolean.

---

### B.5 Prior Art Validation

A quick pass over four widely-used open-source macOS window managers, specifically to
confirm the AX-API + `CGEventTap` approach is the standard path (not something MacGriddle
would be pioneering) and to surface anything that needs *more* than that combination:

| Project | Sandboxed? | Core API | Anything beyond public AX? |
|---|---|---|---|
| **Rectangle** | No | Public Accessibility API only | No. Explicitly declined to add cross-Space window movement because "Apple never released a public API for doing this" — a useful signal that Space-switching is out of scope for an AX-only tool. |
| **AeroSpace** | No (states it will *never* require disabling SIP) | Public Accessibility API | One private call: `_AXUIElementGetWindow`, used only to resolve an `AXUIElement` to a `CGWindowID`. Everything else, including its virtual-workspace system, is built on public AX — it deliberately emulates workspaces itself instead of touching real macOS Spaces, specifically to avoid needing anything private/SIP-gated. |
| **yabai** | No | Public Accessibility API for standard window move/resize (no special privilege beyond the normal Accessibility grant) | Optional Screen Recording permission for window animations; and separately, a scripting addition injected into `Dock.app` (requiring a partial SIP disable) to get *window-server-level* control for advanced features like reliable cross-Space movement. This extra step is opt-in territory beyond MacGriddle's scope, not a baseline requirement. |
| **Amethyst** | No | Public Accessibility + CoreGraphics, wrapped in a vendored library ("Silica") | Some private `CGS*` (CoreGraphics Services) calls for Space-related queries (`SISpace`, `managedSpaceID`, on-screen window IDs) — again, only for Spaces-adjacent features, not for the core move/resize loop. |

**Synthesis for MacGriddle:**

1. The Accessibility API is confirmed, repeatedly and independently, as the standard,
   *supported* way to read/move/resize other applications' windows on macOS — this is not
   a workaround, it's the intended public mechanism, and it's exactly what Part B.1
   describes.
2. **No tool needed to disable SIP or ship a kernel/system extension just to move and
   resize windows within the current Space** — every SIP-adjacent or private-API step
   above (yabai's scripting addition, Amethyst's `CGS*` calls, AeroSpace's one private
   call) is specifically about **Spaces** (creating them, moving windows between them,
   querying which Space a window is "really" on) or, for yabai, deeper window-server
   ownership for advanced/optional features. MacGriddle's spec (Part A) never mentions
   Spaces or cross-Space snapping, so it can stay entirely on public API and remain
   SIP-untouched, matching Rectangle and AeroSpace's posture rather than yabai's.
3. If a future version *does* want "snap this window onto a grid cell on a different
   Space," expect to need at least one private call the way AeroSpace and Amethyst do —
   worth flagging now as a scoping decision rather than an implementation surprise later.
4. None of the four needed anything beyond Accessibility (+ the yabai/Amethyst
   Spaces-only exceptions above) — in particular, **none of them needed Input Monitoring**,
   because none of them use a `CGEventTap`; they all drive their hotkeys/triggers through
   higher-level mechanisms (global hotkey registration, or in yabai's case its own
   `skhd` companion process) rather than a raw event tap watching every mouse-drag +
   modifier-key combination system-wide the way MacGriddle's drag-triggered gesture
   requires. This makes MacGriddle's Input Monitoring requirement (Section B.2.1) a
   genuinely new wrinkle relative to this prior art, not something to expect users to
   already be primed for from using Rectangle/yabai/AeroSpace/Amethyst — onboarding copy
   should not assume familiarity with an Input Monitoring prompt the way it reasonably can
   for the Accessibility prompt.

---

## Summary — Architecture Implications for MacGriddle

- **Distribution**: unsandboxed, Developer ID signed + notarized, direct distribution
  only. No Mac App Store path. Decide this on day one; it affects project setup
  (entitlements, no App Sandbox capability), not just a later packaging step.
- **Permissions needed, and they are separately gated**:
  1. **Accessibility** (`AXIsProcessTrusted`/`AXIsProcessTrustedWithOptions`) — for all
     window read/move/resize via `AXUIElement` (Section B.1).
  2. **Input Monitoring** (`CGPreflightListenEventAccess`/`CGRequestListenEventAccess`) —
     for the listen-only `CGEventTap` that detects the drag + Option-key gesture
     (Section B.2). Granting one does not grant the other; onboarding must request/explain
     both, and should poll both periodically since either can be revoked independently at
     any time from System Settings.
- **Core building blocks, all public API**: `AXUIElementCreateSystemWide` +
  `AXUIElementCopyElementAtPosition` (hit-test) → resolve to `kAXWindowRole`/
  `kAXWindowAttribute` → `kAXPositionAttribute`/`kAXSizeAttribute` get/set via
  `AXValueCreate`/`AXValueGetValue`, driven by a `CGEventTap` state machine
  (`.listenOnly`, watching `leftMouseDown`/`leftMouseDragged`/`leftMouseUp`/
  `flagsChanged`).
- **Coordinate discipline**: keep the entire hit-test/frame-math pipeline in Quartz
  (top-left, Y-down) space end to end — `CGEvent.location` and all AX frames are already
  there natively. Convert only at the AppKit seams (positioning overlay `NSWindow`s,
  reading `NSScreen.screens`), and when doing so, always flip against
  `NSScreen.screens[0].frame.height` (the primary screen), never `NSScreen.main`.
- **Launch at login**: `SMAppService.mainApp` (macOS 13+), no helper bundle needed, read
  `.status` live rather than caching it.
- **Scope boundary confirmed by prior art**: stay off Spaces/cross-Space window movement
  to stay 100% on public API and SIP-untouched, matching Rectangle and AeroSpace rather
  than yabai. Revisit only if a future feature explicitly requires it.
- **No blockers found.** The Accessibility-API + `CGEventTap` approach is confirmed
  viable end to end for every mechanic in Part A, and is the same approach used by every
  comparable shipped tool investigated.
