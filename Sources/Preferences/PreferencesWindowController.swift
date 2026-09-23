import AppKit
import SwiftUI

/// Owns the Preferences window for the app's lifetime. Constructed once by
/// the composition root and reused for every subsequent "Preferences…"
/// invocation — never recreated from scratch. Not a singleton: callers
/// (e.g. `StatusBar`) receive this instance via constructor injection.
///
/// A real `NSWindow`, deliberately not a popover (settings with color
/// pickers and steppers should behave like an ordinary, closable, resizable
/// window a user can leave open) and not the SwiftUI `Settings` scene
/// (that requires the SwiftUI `App` lifecycle; MacGriddle uses a standard
/// `NSApplicationDelegate`, so the window is constructed and shown by hand).
public final class PreferencesWindowController: NSWindowController {

    public init(settings: SettingsStore) {
        let hostingController = NSHostingController(rootView: PreferencesView(settings: settings))
        // macOS 13+ API (an exact match for our deployment target): let the
        // SwiftUI content's own ideal size drive the window's initial size,
        // instead of hand-computing a CGSize.
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacGriddle Preferences"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        // Keep the same NSWindow/NSHostingController/PreferencesView alive
        // across close/reopen cycles rather than rebuilding them — `show()`
        // below just re-fronts this one instance.
        window.isReleasedWhenClosed = false
        window.center()
        // Deliberately leave `window.level` at the AppKit default (.normal).
        // Unlike the grid-overlay windows, which need an elevated level to
        // float above every other app, this is a normal, standalone app
        // window and should behave like one.

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesWindowController does not support NSCoder-based init")
    }

    /// Brings the Preferences window to the front and activates the app.
    /// Required specifically because MacGriddle is `.accessory` — there is
    /// no Dock icon to click, so nothing else activates the app when the
    /// status-bar menu's "Preferences…" item fires. Skipping this line is a
    /// realistic bug: the window would open, but behind whatever app was
    /// already frontmost, with no keyboard focus.
    ///
    /// Calling this on an already-open window is safe and idempotent —
    /// `isReleasedWhenClosed = false` means the same window/controller/view
    /// survive being closed, so a second call just re-fronts the existing
    /// window rather than creating a duplicate.
    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
