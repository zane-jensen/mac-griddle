import CoreGraphics

/// Pure grid math: cell rects for (columns, rows) over a screen frame,
/// anchor+cursor -> covering rectangle, free-resize passthrough. No AppKit
/// import anywhere in this target. Every CGRect/CGPoint this module accepts
/// or returns is in Quartz (global-display, top-left-origin, Y-down) space
/// — callers are responsible for converting at the AppKit seams (see
/// MacGriddleCore.ScreenSpace).
///
/// See docs/architecture/chunks/grid-engine.md.
public enum GridEngine {

    // MARK: - Dimension safety

    /// SettingsStore clamps to 1...12 before a GridConfiguration is ever
    /// built — that's the primary defense. This is defense-in-depth only:
    /// GridEngine has no way to know a caller actually went through that
    /// clamp, and a 0-column/0-row grid would otherwise divide by zero.
    static func safeDimensions(_ configuration: GridConfiguration) -> (columns: Int, rows: Int) {
        (max(configuration.columns, 1), max(configuration.rows, 1))
    }

    static func clamp(_ value: Int, to range: Range<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound - 1)
    }

    // MARK: - cellRect

    /// The rectangle for the cell at (column, row), given a grid shape and
    /// the Quartz-space frame of the screen it's laid out on. Column/row
    /// outside 0..<columns / 0..<rows are clamped rather than producing a
    /// rect outside `screenFrame` or crashing.
    public static func cellRect(
        column: Int,
        row: Int,
        in configuration: GridConfiguration,
        screenFrame: CGRect
    ) -> CGRect {
        let (columns, rows) = safeDimensions(configuration)
        let clampedColumn = clamp(column, to: 0..<columns)
        let clampedRow = clamp(row, to: 0..<rows)

        let cellWidth = screenFrame.width / CGFloat(columns)
        let cellHeight = screenFrame.height / CGFloat(rows)

        // screenFrame.origin is the TOP-LEFT corner in Quartz space (Y-down),
        // so row 0 sits at screenFrame.minY and increasing row moves DOWN
        // the screen (origin.y increases).
        return CGRect(
            x: screenFrame.origin.x + CGFloat(clampedColumn) * cellWidth,
            y: screenFrame.origin.y + CGFloat(clampedRow) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    // MARK: - cell(at:)

    /// Which cell `point` falls in, clamped to the grid's bounds so a
    /// cursor slightly outside `screenFrame` (common during a fast drag
    /// right at a screen edge) still resolves to the nearest real cell
    /// instead of an out-of-range index.
    public static func cell(
        at point: CGPoint,
        in configuration: GridConfiguration,
        screenFrame: CGRect
    ) -> GridCell {
        let (columns, rows) = safeDimensions(configuration)
        let cellWidth = screenFrame.width / CGFloat(columns)
        let cellHeight = screenFrame.height / CGFloat(rows)

        let rawColumn = Int((point.x - screenFrame.origin.x) / cellWidth)
        let rawRow = Int((point.y - screenFrame.origin.y) / cellHeight)

        return GridCell(
            column: clamp(rawColumn, to: 0..<columns),
            row: clamp(rawRow, to: 0..<rows)
        )
    }

    // MARK: - coveringRect

    /// The union of the anchor and current cells' rects. Order-independent:
    /// dragging from a later cell back to an earlier one (up/left) produces
    /// the identical rectangle as the reverse drag, since both are
    /// normalized via min/max on the column/row indices before any rect
    /// math happens.
    public static func coveringRect(
        from anchor: GridCell,
        to current: GridCell,
        in configuration: GridConfiguration,
        screenFrame: CGRect
    ) -> CGRect {
        let minColumn = min(anchor.column, current.column)
        let maxColumn = max(anchor.column, current.column)
        let minRow = min(anchor.row, current.row)
        let maxRow = max(anchor.row, current.row)

        let topLeft = cellRect(column: minColumn, row: minRow, in: configuration, screenFrame: screenFrame)
        let bottomRight = cellRect(column: maxColumn, row: maxRow, in: configuration, screenFrame: screenFrame)

        return topLeft.union(bottomRight)
    }

    // MARK: - freeResizeRect

    /// Normalizes two arbitrary points into a well-formed rect (non-negative
    /// width/height) regardless of drag direction — no grid/cell snapping.
    public static func freeResizeRect(from anchor: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }
}
