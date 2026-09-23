/// The phase of an in-progress (or not-in-progress) grid gesture, as seen
/// by modules that only need to react to *which phase*, not the private
/// details of how Input got there. Deliberately minimal — Input's own
/// internal state machine carries much richer data (which window, its
/// original frame, the anchor cell); none of that belongs here because
/// Overlay, the only other consumer, never unpacks anything beyond the
/// case itself.
///
/// `.committed`/`.cancelled` exist purely for Overlay's own switch
/// exhaustiveness (its `GridOverlayRendering.hide()` takes no state
/// parameter at all) — Input's real implementation never actually
/// constructs these two cases, it just calls `hide()` directly.
///
/// See docs/architecture/chunks/core-contracts.md §1.
public enum GestureState: Equatable {
    case idle
    case dragging
    case gridActive
    case anchored
    case freeResize
    case committed
    case cancelled
}
