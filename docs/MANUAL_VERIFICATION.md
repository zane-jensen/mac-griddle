# Manual Verification Checklist

Everything up to this point (10 architecture docs, full Swift implementation across 8
modules, integration, independent code review) was built and verified by agents. What's
below **cannot** be — granting macOS permissions and physically performing a mouse gesture
require a human, on this machine, with a mouse/trackpad. This is the last step.

## 1. Run it

```bash
cd /Users/zane.jensen/github/work/mac-griddle
./Scripts/build-app.sh
open .build/MacGriddle.app
```

It's unsigned (expected for local dev — see `docs/architecture/chunks/project-structure.md`
§5). If Gatekeeper blocks it, right-click → Open, or `System Settings → Privacy & Security →
Open Anyway`.

## 2. First-run onboarding

- [ ] A "Welcome to MacGriddle" window appears, explaining both permissions.
- [ ] Click **Get Started** → the Accessibility screen appears.
- [ ] Click **Grant Accessibility Access…** → the system permission dialog appears (or, if
      already granted from a prior run, the screen should auto-advance).
- [ ] Grant it in System Settings → Privacy & Security → Accessibility, then switch back to
      MacGriddle. The screen should auto-advance to Input Monitoring within ~1 second (no
      button click needed — this is the polling/notification behavior described in
      `permissions-model.md` §3).
- [ ] Click **Grant Input Monitoring Access…**, grant it the same way.
- [ ] The window shows "You're All Set" and closes on its own. A grid icon (⊞) should now
      appear in the menu bar.
- [ ] **If you close the welcome window early** (before granting both), the app should quit
      entirely — confirm this happens (it's intentional; nothing else exists yet to quit
      from otherwise).

## 3. The core gesture

Try this against a few different apps (Finder, Safari/browser, Terminal, and if you have it,
something Electron-based like VS Code/Slack — those are the ones with historically flaky AX
support per `docs/RESEARCH.md` §B.1.5).

- [ ] Left-click and hold a window's title bar (as if starting a normal drag).
- [ ] While still holding the mouse button, hold **⌥ Option** → a grid overlay should appear
      on every connected screen.
- [ ] Move the cursor — a single highlighted cell should follow it.
- [ ] **Release ⌥ Option** (keep the mouse button held) → that cell becomes the anchor.
- [ ] Move the cursor to a different cell — a rectangle spanning from the anchor to the
      current cell should highlight, growing/shrinking as you move.
- [ ] Release the mouse button → the window should snap to exactly that rectangle.
- [ ] **Top-row / menu-bar check**: repeat the gesture snapping to a cell in the *top* row of
      the grid. The window should land flush with the grid line, not pushed down away from
      the menu bar (this was a real bug — the grid used to include the menu bar's area as
      usable space).
- [ ] **Cancel test**: repeat the gesture, but release the mouse button *while ⌥ is still
      held*, before ever releasing Option to anchor. The window should stay exactly where it
      started — nothing should move.
- [ ] **Free-resize test**: after anchoring (step above), tap ⌥ again (press and release
      quickly). The grid lines should disappear and the selection outline should turn dashed
      — you should now be able to drag to an arbitrary rectangle, not just grid-aligned ones.
      Tap ⌥ again to toggle back to grid-snapped.
- [ ] **Panic hotkey**: mid-gesture (grid overlay visible), press **⌃⌥⇧Esc**. The overlay
      should disappear immediately and the window should return to wherever it was before
      the gesture started.

## 4. Multi-monitor (skip if you only have one display)

- [ ] Start the gesture (hold mouse + Option) on monitor A — the grid should appear on
      *every* connected screen simultaneously.
- [ ] Move the cursor to monitor B before anchoring — the highlighted cell should follow you
      across the boundary onto monitor B's grid.
- [ ] Anchor on monitor B and complete the gesture there — the window should snap to
      monitor B's grid, not monitor A's.

## 5. Menu bar & Preferences

- [ ] Click the menu bar icon — confirm the menu shows: header, an Enabled/Disabled toggle,
      Preferences…, About MacGriddle, Quit (no "Grant Access…" items, since both permissions
      are already granted at this point).
- [ ] Click **Enabled/Disabled** to toggle it off, then try the gesture again — it should do
      nothing while disabled. Toggle back on to resume.
- [ ] Open **Preferences…** — change the grid size (try 4×3), one of the three colors, and
      the opacity slider. Close Preferences and try the gesture again — the new grid size,
      colors, and opacity should all be visible immediately (no restart needed).
- [ ] Toggle **live-resize** on in the Behavior tab, then try the gesture again — the real
      window should now visibly resize continuously as you drag, **smoothly, matching the
      overlay preview exactly with no jitter or pull toward a corner** (this used to fight the
      OS's own native window-drag — see REVIEW.md's live-resize drag-takeover entry — confirm
      it's actually fixed, not just less bad).
  - [ ] **Regression check (important)**: immediately after that live-resize gesture ends
        (mouse-up), drag the *same* window normally by its title bar with no gesture active
        (no Option, live-resize irrelevant). It must behave exactly like ordinary macOS window
        dragging — no lag, no residual suppression.
  - [ ] **Release check**: right when you release the mouse button, the window must stay
        exactly at the final rect it was already tracking — it should NOT visibly jump toward
        the cursor's position on release (a brief, sub-50ms settle is expected and fine; a
        persistent jump is not).
  - [ ] **Next-click check (important)**: right after a live-resize gesture ends, click on a
        *different*, unrelated window elsewhere on screen. That window must NOT move to where
        you clicked (this was a real bug: swallowing the final mouse-up left WindowServer's
        drag-tracking for the resized window stuck open, and the next click anywhere resolved
        it by moving whatever it landed on).
  - [ ] **Panic hotkey mid-drag**: with live-resize on, start the gesture, anchor, and while
        still dragging press **⌃⌥⇧Esc**. The window should release cleanly and immediately —
        then confirm the regression check above still holds right after.
  - [ ] A small flash/disappear-for-an-instant right on release is a known, currently
        unresolved cosmetic issue (see `docs/REVIEW.md`'s tenth/eleventh fix entries — one
        attempted fix made things worse and was fully reverted, so this is intentionally left
        alone for now rather than risking another regression).
  - [ ] Toggle live-resize back off afterward (snap-on-release is the recommended default —
      see `docs/architecture/chunks/preferences-ui.md` for why).
- [ ] Toggle **Launch MacGriddle at Login** on. Open System Settings → General → Login Items
      and confirm MacGriddle appears there. Toggle it off in MacGriddle's Preferences and
      confirm it disappears from Login Items.
- [ ] Click **Restore Defaults** in Preferences — confirm grid size/colors/opacity all reset.

## 6. Permission revocation while running

This exercises a real gap the code review found and a fix specifically added for.

- [ ] With MacGriddle fully running (menu bar icon visible, gesture working), open
      System Settings → Privacy & Security → Accessibility and **uncheck** MacGriddle.
- [ ] Switch back to MacGriddle (or wait ~1 second) — you should see: the menu bar icon dims,
      the menu shows "Grant Accessibility Access…" again, **and** a window reappears
      explaining "MacGriddle Needs Attention" with a re-grant button (this is the
      newly-added `presentDegradedNoticeIfNeeded()` behavior — confirm it actually shows up,
      since this exact gap was found and fixed during review).
- [ ] Re-grant Accessibility from that window (or via the menu bar) — confirm the app resumes
      automatically (gesture works again) without needing to relaunch.

## 7. Quit and relaunch

- [ ] Quit MacGriddle from the menu (Quit MacGriddle).
- [ ] Relaunch it (`open .build/MacGriddle.app` again) — it should go straight to the running
      state (no onboarding window) since both permissions are already granted, and your
      Preferences changes from step 5 should have persisted.

---

Report back anything that didn't match the expected behavior above — that's the next (and
final) thing to fix.
