import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Reader colors and a small, reusable paper tile shared by WebKit and the preview.
enum ReaderAppearance {
    static func highlightHex(background: String, custom: String = "") -> String {
        if custom.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { return custom }
        switch background.uppercased() {
        case "#0A0A0C", "#242135": return "#B4A4D4"
        case "#1C1C1E", "#15241F": return "#86B8A4"
        case "#000000", "#101827": return "#A3B8D8"
        case "#362E26", "#F5E6CE", "#F8F3E8": return "#B28343"
        case "#1C1B16": return "#B9B683"
        case "#E6EDE5": return "#568068"
        case "#FFFFFF": return "#6282A6"
        default: return "#789A87"
        }
    }

    static func highlightCSS(background: String, custom: String, opacity: Double) -> String {
        let hex = highlightHex(background: background, custom: custom)
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x789A87
        return "rgba(\((value >> 16) & 255),\((value >> 8) & 255),\(value & 255),\(min(0.65, max(0.1, opacity))))"
    }

    // Generate 16 KB of deterministic noise once, rather than drawing thousands of
    // Canvas dots or evaluating an SVG turbulence filter for each preview update.
    static let paperTile: CGImage? = {
        var state: UInt32 = 42
        let pixels: [UInt8] = (0..<(128 * 128)).map { _ in
            state = 1664525 &* state &+ 1013904223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    static let paperDataURL: String = {
        guard let image = paperTile else { return "" }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return "" }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return "" }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }()
}

/// The brightness slider in the themes sheet.
///
/// Stored as 0…1 and applied as a black veil over the page: it dims the text
/// for night reading without touching the toolbar or the sheet, and it never
/// changes the system brightness the way a real brightness control would.
enum ReaderDim {
    static let key = "reader.dimLevel"
    /// The veil at full slider travel. Below 1 so text stays legible.
    static let maxVeil: Double = 0.55
}

enum AppMotion {
    static func gentle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.3, extraBounce: 0.03)
    }

    /// Switching between peer lists (library categories, browse catalogues).
    /// One duration so the two screens feel the same.
    static func tabSwitch(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.4)
    }

    /// Glass controls splitting from or merging into each other, such as the
    /// detail screen's actions when an entry joins or leaves the library.
    static func glassMorph(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }
}
