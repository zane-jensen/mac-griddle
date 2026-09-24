import CoreGraphics
import Foundation

/// Wraps exactly one CGEventTap: session-wide, watching the four mouse
/// events plus flagsChanged and keyDown. Owns nothing about gesture
/// semantics — `InputEngine`'s dispatch (see InputEngine.swift) is the only
/// thing that interprets what these callbacks mean; this class only relays
/// `handler`'s verdict back to CGEventTap (pass the event through, or
/// swallow it).
///
/// **Active tap, not listen-only — deliberately, as of the live-resize
/// drag-takeover fix.** Originally this was `.listenOnly` ("must not be
/// able to swallow/alter input"), and for every event type except
/// `leftMouseDragged` that's still effectively true today: `InputEngine`
/// only ever returns `nil` (swallow) for a `leftMouseDragged` event, and
/// only in the narrow window where it just took over a window's frame via
/// Accessibility (`.anchored`/`.freeResize`, live-resize enabled, the AX
/// write succeeded) — see `InputEngine.handle(type:event:)`. That
/// suppression is what stops WindowServer's own native drag-follow from
/// fighting MacGriddle's AX-driven repositioning every frame (the "shaky,
/// keeps shifting back to a corner" bug). Every other event, and every
/// other state, always passes through completely unmodified.
///
/// Real, accepted trade-off from this: an active tap can — in principle —
/// block system-wide mouse input if its callback ever hangs, where a
/// listen-only tap could not. The `tapDisabledByTimeout` self-heal below
/// (unchanged) is the safety net; it matters more now than it used to.
///
/// See docs/architecture/chunks/input-engine-and-state-machine.md §1.
final class GlobalMouseAndModifierTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Returns the event to pass it through unmodified, or `nil` to swallow
    /// it (prevent WindowServer / the target app from ever seeing it).
    typealias EventHandler = (CGEventType, CGEvent) -> CGEvent?
    private let handler: EventHandler

    init(handler: @escaping EventHandler) {
        self.handler = handler
    }

    /// Returns false if Input Monitoring isn't granted (`CGEvent.tapCreate`
    /// returns nil silently in that case — RESEARCH.md §B.2.2) or tap
    /// creation otherwise fails. Safe to call again later — e.g. after the
    /// user grants Input Monitoring during onboarding — since it holds no
    /// state that would make a second call unsafe if the first one failed.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true } // already running

        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) // panic hotkey only, see PanicHotkey.swift

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // active: see the class doc comment for exactly how
                                   // narrowly this is allowed to swallow events
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tapSelf = Unmanaged<GlobalMouseAndModifierTap>.fromOpaque(refcon).takeUnretainedValue()
                guard let passthroughEvent = tapSelf.handle(type: type, event: event) else {
                    return nil // swallow — see handle(type:event:) for exactly when this happens
                }
                return Unmanaged.passUnretained(passthroughEvent)
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

    /// Needed by `InputEngine.stop()` (app termination / permission-loss
    /// paths). Safe to call when not running (idempotent).
    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        // RESEARCH.md §B.2.2: macOS can disable a tap it judges slow or
        // misbehaving; both disable reasons arrive as event *types*
        // delivered to this same callback, not as an error. Re-enabling
        // immediately is the documented self-heal — without this, a single
        // timeout silently and permanently kills gesture detection until
        // the next app relaunch. This matters even more now that the tap
        // is active rather than listen-only: while disabled, macOS stops
        // delivering these event types system-wide, not just to us.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return event
        }
        return handler(type, event)
    }
}
