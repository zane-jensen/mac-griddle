# Grid Engine (`GridEngine`) — Pure Grid Math

Chunk 6 of 10. Covers the `GridEngine` target: cell rects for `(columns, rows)` over a
screen frame, anchor+cursor → covering rectangle, and free-resize passthrough. **Zero
`Package.swift` dependencies — not even `MacGriddleCore`** (confirmed by `project-structure.md`'s
manifest). No AppKit import. Fully unit-testable via the paired `GridEngineTests` target.

## Why zero dependencies, restated concretely

`core-contracts.md` (chunk 2) §2 explains the reasoning; the practical consequence for this
chunk is that **every type this module's public API exposes must be declared inside this
module** — `GridConfiguration` and `GridCell` (§1 below) cannot come from `Core`, because
`GridEngine` cannot import it. Everything here is `CoreGraphics` value types
(`CGRect`/`CGPoint`/`CGFloat`/`Int`) and plain Swift — `import CoreGraphics` is fine (it is
not `AppKit` and carries no windowing/display side effects), `import AppKit` is not used
anywhere in this target.

---

## 1. Types

```swift
import CoreGraphics

/// The grid's shape only — no color/appearance/behavior fields. Those live
/// in Preferences (raw values) and Core's OverlayAppearance (rendering) per
/// core-contracts.md §5; GridEngine only ever needs to know how many cells
/// there are.
public struct GridConfiguration: Equatable {
    public let columns: Int
    public let rows: Int

    /// `columns`/`rows` are expected to already be clamped to a sane range
    /// by the caller (`preferences-ui.md`'s `SettingsStore.dimensionRange`,
    /// 1...12) before reaching this module. This initializer still guards
    /// against a degenerate 0-or-negative value itself (see §4) rather than
    /// trusting that clamping blindly — GridEngine has no visibility into
    /// Preferences and shouldn't assume its invariants hold by the time a
    /// value arrives here.
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// A single cell's grid position (zero-indexed: column 0 is leftmost, row 0
/// is topmost — matching Quartz's top-left origin, so "row 0" is visually
/// the top row, not the bottom).
public struct GridCell: Equatable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}
```

---

## 2. Coordinate contract

Every `CGRect`/`CGPoint` this module accepts or returns — `screenFrame` parameters, cursor
points, returned cell/covering rects — is in **Quartz** (global-display, top-left-origin,
Y-down) space, per `core-contracts.md` §7's restatement of the project-wide coordinate
discipline. This module never calls `NSScreen` or does any Cocoa↔Quartz conversion itself —
callers (`Input`, `Overlay`) are responsible for handing it an already-Quartz `screenFrame`
(via `Core`'s `ScreenSpace`, per `core-contracts.md` §6) and reading an already-Quartz result
back. This keeps the "no AppKit import" constraint honest: a screen frame is just a `CGRect`
to this module, regardless of which coordinate space it happens to be expressed in, but Y-down
vs. Y-up changes which edge is "top" — see §3's `cellRect` for exactly where that matters.

---

## 3. `cellRect(column:row:in:screenFrame:)`

The one function `overlay-rendering.md` (chunk 7) already wrote a call site against
(`GridEngine.cellRect(column:row:in:screenFrame:)` — this document confirms that exact
signature, no changes needed on chunk 7's side).

```swift
public enum GridEngine {
    /// The rectangle for the cell at (column, row), given a grid shape and
    /// the Quartz-space frame of the screen it's laid out on. Column/row
    /// outside 0..<columns / 0..<rows are clamped (§4) rather than
    /// producing a rect outside `screenFrame` or crashing.
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
        // the screen (origin.y increases) — the opposite of what this same
        // arithmetic would mean in Cocoa's Y-up space. This is the one place
        // in this module where getting the coordinate direction backwards
        // would silently flip the grid vertically without any type error to
        // catch it — worth the explicit comment.
        return CGRect(
            x: screenFrame.origin.x + CGFloat(clampedColumn) * cellWidth,
            y: screenFrame.origin.y + CGFloat(clampedRow) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }
}
```

---

## 4. Defensive dimension handling

```swift
extension GridEngine {
    /// SettingsStore clamps to 1...12 before a GridConfiguration is ever
    /// built (preferences-ui.md §2) — that's the primary defense. This is
    /// defense-in-depth only: GridEngine has no way to know a caller
    /// actually went through that clamp, and a 0-column/0-row grid would
    /// otherwise divide by zero in cellRect. Floors both dimensions at 1
    /// rather than special-casing a zero/negative input with a thrown error
    /// or a zero-rect return — a 1x1 "grid" (the whole screen, one cell) is
    /// a well-defined, harmless degenerate case, consistent with this
    /// project's general "never crash on bad input, degrade to something
    /// sane" posture (window-control-and-coordinates.md §6 takes the same
    /// stance for AX failures).
    static func safeDimensions(_ configuration: GridConfiguration) -> (columns: Int, rows: Int) {
        (max(configuration.columns, 1), max(configuration.rows, 1))
    }

    static func clamp(_ value: Int, to range: Range<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound - 1)
    }
}
```

---

## 5. `cell(at:in:screenFrame:)` — hit-testing a cursor point to a cell

Needed by `Input`'s state machine (`input-engine-and-state-machine.md`) on every mouse-move
during `.gridActive`/`.anchored` to know which cell the cursor is currently over. Not
referenced by name in any of the 7 completed chunks (none of them do their own grid math),
so this signature is free to design cleanly for its one real caller.

```swift
extension GridEngine {
    /// Which cell `point` falls in, clamped to the grid's bounds so a
    /// cursor slightly outside `screenFrame` (common during a fast drag
    /// right at a screen edge) still resolves to the nearest real cell
    /// instead of an out-of-range index or nil.
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
}
```

---

## 6. `coveringRect(from:to:in:screenFrame:)` — anchor + current cell → snapped rectangle

The grid-snapped counterpart to `freeResizeRect` (§7). Computes the smallest rectangle that
fully covers both the anchor cell and the current cell — this is what makes dragging from
cell (1,1) to cell (3,2) select a 3×2 block, in either drag direction (down-right or
up-left from the anchor).

```swift
extension GridEngine {
    /// The union of the anchor and current cells' rects. Order-independent:
    /// dragging from a later cell back to an earlier one (up/left) produces
    /// the identical rectangle as the reverse drag, since both are
    /// normalized via min/max on the column/row indices before any rect
    /// math happens — this is what makes the gesture spec's "move to the
    /// end corner" work regardless of which direction the user actually
    /// drags in.
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
}
```

`CGRect.union` is exactly the right built-in here: two axis-aligned rects that share the grid's
cell grid lines, unioned, always produces the full covering rectangle with no gaps — no need
to hand-compute width/height from the column/row span.

---

## 7. `freeResizeRect(from:to:)` — ungridded passthrough

The free-resize mode's rectangle: an arbitrary rect from the anchor point to the current
cursor point, with no grid involvement at all — not even `GridConfiguration`/`screenFrame`
are needed. Kept in `GridEngine` anyway (rather than inlined in `Input`'s state machine)
specifically so *every* "turn gesture geometry into a rect" computation lives in one pure,
tested place, consistent with `overview.md`'s "free-resize passthrough" being named as part
of this chunk's own scope.

```swift
extension GridEngine {
    /// Normalizes two arbitrary points into a well-formed rect (non-negative
    /// width/height) regardless of drag direction — same normalization
    /// principle as coveringRect (§6), just without any grid/cell snapping.
    public static func freeResizeRect(from anchor: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }
}
```

---

## 8. Unit test plan (`GridEngineTests`)

`project-structure.md` already declares this test target (`dependencies: ["GridEngine"]`);
this section is what should actually go in it. Every test below is a pure function call —
no mocking, no AppKit, no run loop — which is the entire point of keeping this module
dependency-free.

```swift
import XCTest
@testable import GridEngine

final class GridEngineTests: XCTestCase {

    let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 800) // Quartz space
    let config = GridConfiguration(columns: 6, rows: 4) // the v1 default (overview.md)

    // MARK: cellRect

    func testCellRectTopLeftCell() {
        let rect = GridEngine.cellRect(column: 0, row: 0, in: config, screenFrame: screenFrame)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    func testCellRectBottomRightCell() {
        // column 5, row 3 is the last cell in a 6x4 grid (zero-indexed)
        let rect = GridEngine.cellRect(column: 5, row: 3, in: config, screenFrame: screenFrame)
        XCTAssertEqual(rect, CGRect(x: 1000, y: 600, width: 200, height: 200))
    }

    func testCellRectClampsOutOfBoundsColumn() {
        let farRight = GridEngine.cellRect(column: 99, row: 0, in: config, screenFrame: screenFrame)
        let lastRealColumn = GridEngine.cellRect(column: 5, row: 0, in: config, screenFrame: screenFrame)
        XCTAssertEqual(farRight, lastRealColumn)
    }

    func testCellRectClampsNegativeColumn() {
        let negative = GridEngine.cellRect(column: -3, row: 0, in: config, screenFrame: screenFrame)
        let firstRealColumn = GridEngine.cellRect(column: 0, row: 0, in: config, screenFrame: screenFrame)
        XCTAssertEqual(negative, firstRealColumn)
    }

    func testCellRectDegenerateOneByOneGridIsWholeScreen() {
        let oneByOne = GridConfiguration(columns: 0, rows: 0) // floored to 1x1 by safeDimensions
        let rect = GridEngine.cellRect(column: 0, row: 0, in: oneByOne, screenFrame: screenFrame)
        XCTAssertEqual(rect, screenFrame)
    }

    // MARK: cell(at:)

    func testCellAtOriginIsTopLeftCell() {
        let cell = GridEngine.cell(at: CGPoint(x: 5, y: 5), in: config, screenFrame: screenFrame)
        XCTAssertEqual(cell, GridCell(column: 0, row: 0))
    }

    func testCellAtCenterOfGrid() {
        // (600, 400) is exactly the boundary between columns 2/3 and rows 1/2
        // in a 6x4 grid over a 1200x800 frame — lands just inside column 3, row 2.
        let cell = GridEngine.cell(at: CGPoint(x: 650, y: 450), in: config, screenFrame: screenFrame)
        XCTAssertEqual(cell, GridCell(column: 3, row: 2))
    }

    func testCellAtClampsPointOutsideScreenFrame() {
        let farBeyond = GridEngine.cell(at: CGPoint(x: 5000, y: 5000), in: config, screenFrame: screenFrame)
        XCTAssertEqual(farBeyond, GridCell(column: 5, row: 3)) // last real cell, not out of range
    }

    func testCellAtClampsNegativePoint() {
        let beforeOrigin = GridEngine.cell(at: CGPoint(x: -100, y: -100), in: config, screenFrame: screenFrame)
        XCTAssertEqual(beforeOrigin, GridCell(column: 0, row: 0))
    }

    // MARK: coveringRect

    func testCoveringRectSameCellBothWays() {
        let cell = GridCell(column: 2, row: 1)
        let rect = GridEngine.coveringRect(from: cell, to: cell, in: config, screenFrame: screenFrame)
        let expected = GridEngine.cellRect(column: 2, row: 1, in: config, screenFrame: screenFrame)
        XCTAssertEqual(rect, expected)
    }

    func testCoveringRectForwardDrag() {
        let anchor = GridCell(column: 1, row: 1)
        let current = GridCell(column: 3, row: 2)
        let rect = GridEngine.coveringRect(from: anchor, to: current, in: config, screenFrame: screenFrame)
        // columns 1-3 (3 cells wide), rows 1-2 (2 cells tall), cell = 200x200
        XCTAssertEqual(rect, CGRect(x: 200, y: 200, width: 600, height: 400))
    }

    func testCoveringRectReverseDragProducesIdenticalRect() {
        let anchor = GridCell(column: 3, row: 2)
        let current = GridCell(column: 1, row: 1)
        let forward = GridEngine.coveringRect(from: GridCell(column: 1, row: 1), to: GridCell(column: 3, row: 2), in: config, screenFrame: screenFrame)
        let reverse = GridEngine.coveringRect(from: anchor, to: current, in: config, screenFrame: screenFrame)
        XCTAssertEqual(forward, reverse)
    }

    // MARK: freeResizeRect

    func testFreeResizeRectForwardDrag() {
        let rect = GridEngine.freeResizeRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    func testFreeResizeRectReverseDragNormalizes() {
        let rect = GridEngine.freeResizeRect(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    func testFreeResizeRectZeroSizeAtSamePoint() {
        let point = CGPoint(x: 250, y: 250)
        let rect = GridEngine.freeResizeRect(from: point, to: point)
        XCTAssertEqual(rect, CGRect(x: 250, y: 250, width: 0, height: 0))
    }
}
```

---

## Handoff notes

- **`overlay-rendering.md`**: no changes needed — its `cellRect(column:row:in:screenFrame:)`
  call site matches §3 exactly, and its assumption that `screenFrame` is Quartz-space (§2
  here) was correct.
- **`core-contracts.md`**: this document is what that chunk's §2 points to for
  `GridConfiguration`'s real definition; `GridCell` is a new type that chunk didn't
  anticipate by name but is scoped identically (grid-shape-adjacent, zero-dependency,
  belongs alongside `GridConfiguration` for the same reason).
- **`input-engine-and-state-machine.md`**: the state machine's `.gridActive`/`.anchored`
  handling calls `cell(at:in:screenFrame:)` on every mouse-move and `coveringRect(from:to:in:screenFrame:)`
  once anchored; `.freeResize` handling calls `freeResizeRect(from:to:)` instead. All three
  take/return Quartz-space values — `Input` owns converting the `NSScreen` it resolves the
  cursor onto into a Quartz `screenFrame` via `Core.ScreenSpace` before calling any of these
  (§2's coordinate contract).
