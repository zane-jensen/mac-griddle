import AppKit
import SwiftUI

// `UserDefaults` has no native way to store a `Color` (or `NSColor`).
// `SettingsStore` round-trips values as `#RRGGBBAA` hex strings, bridging
// through `NSColor` to read/write RGBA components (`Color` has no public
// component accessor at this deployment target). Internal to this target —
// other targets that need overlay colors get an already-converted
// `NSColor`/`CGColor`, built by the composition root, never a hex string.
extension Color {
    /// Encodes as `#RRGGBBAA`. Safe to route through `.deviceRGB` here
    /// specifically because every `Color` this app ever hex-encodes
    /// originates either from a SwiftUI `ColorPicker` (sRGB) or from
    /// `init(hex:)` below (also `.sRGB`) — never an arbitrary system/catalog
    /// color, which is the case where colorspace conversion can fail.
    func toHexString() -> String {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        let a = Int((nsColor.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    /// Decodes `#RRGGBBAA` (or `#RRGGBB`, alpha implied 255). Returns `nil`
    /// for anything malformed — callers fall back to a `Defaults` value.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        value.removeAll { $0 == "#" }
        if value.count == 6 { value += "FF" }
        guard value.count == 8, let rgba = UInt64(value, radix: 16) else { return nil }

        self = Color(
            .sRGB,
            red: Double((rgba & 0xFF00_0000) >> 24) / 255,
            green: Double((rgba & 0x00FF_0000) >> 16) / 255,
            blue: Double((rgba & 0x0000_FF00) >> 8) / 255,
            opacity: Double(rgba & 0x0000_00FF) / 255
        )
    }
}
