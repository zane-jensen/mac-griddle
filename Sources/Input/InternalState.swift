import CoreGraphics
import GridEngine
import MacGriddleCore

/// The window this gesture is acting on, captured once at mouseDown and
/// carried through every state until commit/cancel/idle.
///
/// Not marked `private` the way input-engine-and-state-machine.md §3's
/// illustrative snippet shows it — that would make it file-scoped, and
/// this type is deliberately factored into its own file for readability.
/// It is still invisible outside the `Input` module (never marked
/// `public`), which is the encapsulation the doc's `private` was actually
/// protecting: only `InputEngine`'s own dispatch logic ever touches this.
struct GestureCandidate {
    let window: WindowHandle
    let originalFrame: CGRect // Quartz space — captured verbatim for restore-on-cancel
    let screenFrame: CGRect   // Quartz space — the screen the gesture is locked to once anchored
}

/// Input's own state, richer than Core's public `GestureState` (which has
/// no associated values at all — core-contracts.md §1). Translated to the
/// public enum only at the two call sites into `Overlay` (see
/// `publicState` below).
enum InternalState {
    case idle
    case dragging(GestureCandidate)
    case gridActive(GestureCandidate)
    case anchored(GestureCandidate, anchor: GridCell)
    case freeResize(GestureCandidate, anchorPoint: CGPoint)
}

/// The only place this module's rich `InternalState` becomes
/// `Core.GestureState` — the two calls into `Overlay`'s
/// `GridOverlayRendering` protocol. `.committed`/`.cancelled` are never
/// constructed here; commit/cancel/panic paths call `overlay.hide()`
/// directly instead (see core-contracts.md §1's note on why those two
/// cases exist purely for `Overlay`'s own switch-exhaustiveness).
extension InternalState {
    var publicState: GestureState {
        switch self {
        case .idle: return .idle
        case .dragging: return .dragging
        case .gridActive: return .gridActive
        case .anchored: return .anchored
        case .freeResize: return .freeResize
        }
    }
}
