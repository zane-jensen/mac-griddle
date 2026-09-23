import CoreGraphics

/// The grid's shape only — no color/appearance/behavior fields. Those live
/// in Preferences (raw values) and Core's OverlayAppearance (rendering).
/// GridEngine only ever needs to know how many cells there are.
///
/// Lives in GridEngine, not MacGriddleCore, because GridEngine has zero
/// Package.swift dependencies (not even Core) and this type appears in its
/// public API. See docs/architecture/chunks/core-contracts.md §2 and
/// docs/architecture/chunks/grid-engine.md §1.
public struct GridConfiguration: Equatable {
    public let columns: Int
    public let rows: Int

    /// `columns`/`rows` are expected to already be clamped to a sane range
    /// by the caller (Preferences' SettingsStore.dimensionRange, 1...12)
    /// before reaching this module. GridEngine still guards against a
    /// degenerate 0-or-negative value itself (see GridEngine.safeDimensions)
    /// rather than trusting that clamping blindly.
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
