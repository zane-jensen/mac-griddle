import AppKit

/// AppKit types only (NSColor, not SwiftUI Color) — Overlay has no SwiftUI
/// dependency and never should; the composition root does the Color→NSColor
/// conversion once, when reading from SettingsStore.
///
/// See docs/architecture/chunks/core-contracts.md §5 and
/// docs/architecture/chunks/overlay-rendering.md §5.
public struct OverlayAppearance: Equatable {
    public let cellStrokeColor: NSColor
    public let selectionFillColor: NSColor
    public let selectionStrokeColor: NSColor

    /// Multiplies on top of each color's own alpha, as a single master
    /// dial — applied as the overlay NSWindow's own `alphaValue`.
    public let opacity: Double

    public init(
        cellStrokeColor: NSColor,
        selectionFillColor: NSColor,
        selectionStrokeColor: NSColor,
        opacity: Double
    ) {
        self.cellStrokeColor = cellStrokeColor
        self.selectionFillColor = selectionFillColor
        self.selectionStrokeColor = selectionStrokeColor
        self.opacity = opacity
    }
}
