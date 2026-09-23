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
func screenFrame(containing quartzPoint: CGPoint) -> CGRect {
    let height = ScreenSpace.primaryScreenHeight()
    let cocoaFrame = screen(containing: quartzPoint)?.frame
        ?? NSScreen.screens.first?.frame
        ?? .zero
    return ScreenSpace.cocoaToQuartz(cocoaFrame, primaryScreenHeight: height)
}
