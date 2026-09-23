# MacGriddle

MacGriddle is a macOS menu-bar utility that snaps windows into place on a
configurable grid, cloning [WindowGrid](https://github.com/rickb/WindowGrid)'s
core gesture for Windows — adapted so it works with a Magic Mouse, which
can't reliably hold a right-click while dragging.

Instead of WindowGrid's **left-click + right-click-hold**, MacGriddle uses
**left-click + Option-hold**:

1. Left-click and hold a window's title bar (a normal drag start).
2. While still holding the mouse button, hold **⌥ Option** — a grid overlay
   appears on every connected screen.
3. Hover the cell that should be the start corner, then **release ⌥ Option**
   to anchor it.
4. Move to the end cell — you'll see a live preview of the covering
   rectangle.
5. Release the mouse button — the window snaps to that rectangle.
6. Release the mouse button *before* anchoring (while ⌥ is still held) to
   cancel — the window is untouched.
7. Tap **⌥** again after anchoring to toggle free-resize mode (an arbitrary
   rectangle, not snapped to the grid).

A global panic hotkey, **⌃⌥⇧Escape** (Ctrl+Option+Shift+Escape), force-resets
the gesture if it ever gets stuck.

MacGriddle lives entirely in the menu bar — no Dock icon, no main window.

## Requirements

- macOS 13 Ventura or later
- Xcode (or the Swift 5.9+ toolchain via Command Line Tools) to build — there
  are no signed releases yet, so it's built from source

## Installing (build from source)

```bash
git clone <this-repo-url>
cd mac-griddle
./Scripts/build-app.sh
open .build/MacGriddle.app
```

`build-app.sh` compiles a release build and assembles it into a proper
`.app` bundle at `.build/MacGriddle.app`. If you'd rather keep it around
permanently, drag that `.app` into `/Applications` after building.

The build is not code-signed or notarized, so this is intended for personal,
local use rather than distribution.

### First launch (permissions)

On first launch, MacGriddle walks you through granting two **separate**
macOS permissions — granting one does not grant the other:

- **Accessibility** — needed to read and move/resize windows.
- **Input Monitoring** — needed to detect the Option-hold gesture globally.

Follow the onboarding prompts and grant both in System Settings. If you ever
need to re-grant them manually: **System Settings → Privacy & Security →
Accessibility** / **Input Monitoring**.

## Preferences

Click the menu bar icon → Preferences to configure:

- **Grid size** — columns and rows, 1–12 each (default 6×4)
- **Resize behavior** — snap-on-release (default) or live-resize while
  dragging
- **Appearance** — grid line color, selection fill/border color, overlay
  opacity
- **Launch at login**

## Rebuilding / development

```bash
swift build          # debug build
swift test           # run the GridEngine unit tests
./Scripts/build-app.sh   # release build + .app packaging
```

See `docs/architecture/` for the module breakdown and design docs, and
`docs/MANUAL_VERIFICATION.md` for the manual test checklist.
