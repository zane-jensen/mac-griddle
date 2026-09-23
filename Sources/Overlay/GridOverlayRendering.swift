import CoreGraphics
import GridEngine
import MacGriddleCore

/// The seam `Input` codes against to drive the grid overlay. `Overlay` owns
/// this contract's shape.
///
/// Deliberately **not** `@MainActor` on the protocol, and its one
/// conformer (`GridOverlayController`) is deliberately not `@MainActor`
/// either: `Input`'s entire `handle(type:event:)` dispatch chain calls
/// these methods synchronously from the `CGEventTap` C callback, which
/// runs on the physical main thread but is invoked directly by
/// CoreFoundation, bypassing GCD — Swift's concurrency runtime does not
/// recognize that context as "on MainActor." Marking either the protocol
/// or the conformer `@MainActor` (tried during a review rework pass and
/// reverted) inserts a runtime isolation check that crashes with
/// "Incorrect actor executor assumption" the moment a gesture calls into
/// this type. AppKit's own thread-safety requirement (everything happens
/// on the main thread) is still satisfied in practice — this just isn't
/// something Swift's actor system can verify given how the tap callback is
/// invoked. See docs/REVIEW.md's rework-pass addendum for the fix history.
///
/// See docs/architecture/chunks/overlay-rendering.md §4.
public protocol GridOverlayRendering: AnyObject {
    func show(configuration: GridConfiguration, state: GestureState)
    func updateSelection(rect: CGRect, state: GestureState)
    func hide()
}
