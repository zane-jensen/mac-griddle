import XCTest
@testable import GridEngine

final class GridEngineTests: XCTestCase {

    let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 800) // Quartz space
    let config = GridConfiguration(columns: 6, rows: 4) // the v1 default

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
        // (650, 450) lands just inside column 3, row 2 in a 6x4 grid over a
        // 1200x800 frame (cell size 200x200).
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
        let forward = GridEngine.coveringRect(from: GridCell(column: 1, row: 1), to: GridCell(column: 3, row: 2), in: config, screenFrame: screenFrame)
        let reverse = GridEngine.coveringRect(from: GridCell(column: 3, row: 2), to: GridCell(column: 1, row: 1), in: config, screenFrame: screenFrame)
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
