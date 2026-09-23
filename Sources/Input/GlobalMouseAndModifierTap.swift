import CoreGraphics
import Foundation

/// Wraps exactly one CGEventTap: session-wide, listen-only, watching the
/// four mouse events plus flagsChanged and keyDown. Owns nothing about
/// gesture semantics — `InputEngine`'s dispatch (see InputEngine.swift) is
/// the only thing that interprets what these callbacks mean.
///
/// See docs/architecture/chunks/input-engine-and-state-machine.md §1.
final class GlobalMouseAndModifierTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    typealias EventHandler = (CGEventType, CGEvent) -> Void
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
            options: .listenOnly, // never .defaultTap — must not be able to swallow/alter input
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tapSelf = Unmanaged<GlobalMouseAndModifierTap>.fromOpaque(refcon).takeUnretainedValue()
                tapSelf.handle(type: type, event: event)
                // Listen-only taps ignore the return value, but the callback
                // signature still requires returning the (unmodified) event.
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

    private func handle(type: CGEventType, event: CGEvent) {
        // RESEARCH.md §B.2.2: macOS can disable a tap it judges slow or
        // misbehaving; both disable reasons arrive as event *types*
        // delivered to this same callback, not as an error. Re-enabling
        // immediately is the documented self-heal — without this, a single
        // timeout silently and permanently kills gesture detection until
        // the next app relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        handler(type, event)
    }
}
