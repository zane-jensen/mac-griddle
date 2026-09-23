import Carbon.HIToolbox // kVK_Escape — a virtual keycode constant, not the deprecated
                         // RegisterEventHotKey API; safe to import just for the constant.
import CoreGraphics

/// ⌃⌥⇧Escape (overview.md's panic-hotkey suggestion). Folded into
/// `GlobalMouseAndModifierTap`'s own event mask (`.keyDown`) rather than a
/// second hotkey-registration mechanism — see
/// docs/architecture/chunks/input-engine-and-state-machine.md §7 for why:
/// Input Monitoring already covers observing keyDown the same way it
/// covers mouse events, this keeps exactly one event-handling path, and as
/// a listen-only tap it can't consume the Escape press either way.
private let panicModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]

func isPanicHotkey(_ event: CGEvent) -> Bool {
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    return keycode == Int64(kVK_Escape) && event.flags.contains(panicModifiers)
}
