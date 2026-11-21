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
    static func onboardingPage(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.56, dampingFraction: 0.88)
    }

    static func onboardingControl(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.4)
    }

    static func onboardingExit(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.48)
    }

    static func onboardingTracking(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.16, dampingFraction: 0.9)
    }

    static func onboardingSettle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.56, dampingFraction: 0.78)
    }

    static func gentle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.3, extraBounce: 0.03)
    }

    /// Switching between peer lists (library categories, browse catalogues).
    /// One duration so the two screens feel the same.
    static func tabSwitch(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.4)
    }

    /// A Minimal Mode page finishing the move a finger started, or returning
    /// when the drag did not commit. The spring begins at the speed the finger
    /// was dragging, so the drag and the snap are one motion instead of a stop
    /// followed by an animation; it is sticky, settling into place without
    /// bouncing past it.
    ///
    /// `initialVelocity` is not points per second: it is a fraction of the
    /// animated distance per second, so the finger's speed is divided by what
    /// is left to travel and clamped to the documented 0…1.
    static func pageSticky(speed: Double, distance: Double, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        let fraction = min(1, max(0, abs(speed) / max(1, distance)))
        return .interpolatingSpring(stiffness: 300, damping: 34, initialVelocity: fraction)
    }

    /// The Minimal Mode page arriving on a swipe or a menu pick: it glides in
    /// from the right and unblurs. A crisp deceleration with a tiny settle, not
    /// a bounce — an overshooting page reads as a cartoon.
    ///
    /// Reduce Motion keeps the exchange in place and fades instead: no offset,
    /// no blur, just a quick crossfade.
    static func pageReveal(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.42, bounce: 0.12)
    }

    /// The page that left clears slightly faster than the incoming spring
    /// settles, so it never lingers as a ghost behind the new content.
    static func pageExit(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .easeOut(duration: 0.24)
    }

    /// Glass controls splitting from or merging into each other, such as the
    /// detail screen's actions when an entry joins or leaves the library.
    static func glassMorph(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }
}
