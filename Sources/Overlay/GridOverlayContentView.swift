import AppKit
import QuartzCore
import MacGriddleCore
import GridEngine

/// Layer-backed content view hosted by each `OverlayWindow`. Draws grid
/// lines (rare updates) and the selection highlight (hot path) as two
/// independent `CAShapeLayer`s so the hot path never touches `draw(_:)` or
/// SwiftUI.
///
/// See docs/architecture/chunks/overlay-rendering.md §3.
final class GridOverlayContentView: NSView {
    private let gridLinesLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// Makes this view's (and therefore its backing layer's) coordinate
    /// system top-left-origin, Y-down — matching Quartz/global-display
    /// space exactly. With this in place, converting a GridEngine/Input
    /// rect (already in that same space) into this layer's local space is
    /// a pure translation (subtract this screen's Quartz origin) — no axis
    /// flip math anywhere in this view.
    override var isFlipped: Bool { true }

    private func commonInit() {
        wantsLayer = true
        gridLinesLayer.fillColor = nil // stroke-only
        selectionLayer.fillRule = .nonZero
        layer?.addSublayer(gridLinesLayer)
        layer?.addSublayer(selectionLayer)
    }

    /// Cosmetic-only update — safe to call whenever appearance settings
    /// change, independent of grid/selection geometry.
    func applyAppearance(_ appearance: OverlayAppearance) {
        gridLinesLayer.strokeColor = appearance.cellStrokeColor.cgColor
        gridLinesLayer.lineWidth = 1
        selectionLayer.fillColor = appearance.selectionFillColor.cgColor
        selectionLayer.strokeColor = appearance.selectionStrokeColor.cgColor
        selectionLayer.lineWidth = 2
        window?.alphaValue = appearance.opacity
    }

    /// COLD PATH — called from show(configuration:state:), and again only
    /// if GridConfiguration changes mid-gesture. Never called from the
    /// per-mouse-move hot path. This is the only place this target calls
    /// into GridEngine.
    func rebuildGridLines(configuration: GridConfiguration, screenFrame: CGRect, quartzOrigin: CGPoint) {
        let path = CGMutablePath()
        for row in 0..<configuration.rows {
            for column in 0..<configuration.columns {
                let cellRect = GridEngine.cellRect(column: column, row: row, in: configuration, screenFrame: screenFrame)
                path.addRect(cellRect.offsetBy(dx: -quartzOrigin.x, dy: -quartzOrigin.y))
            }
        }
        gridLinesLayer.path = path
    }

    func setGridLinesVisible(_ visible: Bool) {
        gridLinesLayer.isHidden = !visible
    }

    /// HOT PATH — called on every updateSelection. O(1): one CGPath, one
    /// property assignment. No GridEngine call, no view redraw, no layout.
    func setSelection(_ rect: CGRect?, quartzOrigin: CGPoint) {
        guard let rect else {
            selectionLayer.path = nil
            return
        }
        let localRect = rect.offsetBy(dx: -quartzOrigin.x, dy: -quartzOrigin.y)
        selectionLayer.path = CGPath(rect: localRect, transform: nil)
    }

    /// See docs/architecture/chunks/overlay-rendering.md §5.
    func setFreeResizeStyle(_ isFreeResize: Bool) {
        selectionLayer.lineDashPattern = isFreeResize ? [6, 4] : nil
    }
}
