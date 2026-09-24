import AppKit
import MacGriddleCore

/// Sketched illustratively in window-control-and-coordinates.md §4 as
/// "more plausibly lives in Input... since it's the only other target
/// that depends on WindowControl" — this is that function, claimed by
/// this chunk (input-engine-and-state-machine.md §2).
func screen(containing quartzPoint: CGPoint) -> NSScreen? {
    let height = ScreenSpace.primaryScreenHeight()
    let cocoaPoint = ScreenSpace.quartzToCocoa(quartzPoint, primaryScreenHeight: height)
    return NSScreen.screens.first { $0.frame.contains(cocoaPoint) }
}

/// The Quartz-space frame of whichever screen contains `quartzPoint`, or
/// the primary screen's frame as a last-resort fallback (e.g. a point that
/// momentarily falls between displays during a resolution change) so grid
/// math always has *some* valid screenFrame rather than needing to handle
/// nil at every call site.
///
/// Uses `visibleFrame`, not `frame` — deliberately. `frame` includes the
/// menu bar (and Dock, if visible), and macOS silently pushes any window
/// positioned to overlap either of those down/away from it. Computing grid
/// cells against the full `frame` let the top row (and, with a visible
/// Dock, potentially an edge row) overlap those reserved areas, so a
/// window snapped there landed a few pixels away from where the grid
/// showed it — confirmed via manual testing. `visibleFrame` is exactly the
/// region a normal window can actually occupy.
func screenFrame(containing quartzPoint: CGPoint) -> CGRect {
    let height = ScreenSpace.primaryScreenHeight()
    let cocoaFrame = screen(containing: quartzPoint)?.visibleFrame
        ?? NSScreen.screens.first?.visibleFrame
        ?? .zero
    return ScreenSpace.cocoaToQuartz(cocoaFrame, primaryScreenHeight: height)
}
