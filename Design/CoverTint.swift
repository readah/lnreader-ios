// CoverTint.swift
// A tint colour taken from a book's cover, for the detail screens.

import CoreImage
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The tint preferences, shared by the Appearance screen and the detail screens.
enum AppearanceTint {
    static let enabledKey = "appearance.tintDetails"
    static let strengthKey = "appearance.tintStrength"
    /// Enough to see the book's colour, little enough to keep text readable.
    static let defaultStrength = 0.35
}

/// Draws one colour out of a cover image.
///
/// Averaging the whole cover is the reliable part: it survives busy artwork and
/// the hue it lands on is the one the eye reads as "the colour of this book". A
/// raw average is almost always washed out, though, because most of a cover is
/// background, so saturation and brightness are lifted into a range that still
/// reads as a tint behind text.
@MainActor
enum CoverTint {

    /// Colours already worked out, keyed by cover URL. Extraction renders a
    /// Core Image filter, so it happens once per cover rather than per redraw.
    private static var cache: [String: Color] = [:]

    static func color(for urlString: String?) async -> Color? {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        if let cached = cache[urlString] { return cached }
        guard let image = await image(for: url), let color = color(from: image) else { return nil }
        cache[urlString] = color
        return color
    }

    /// The already-decoded cover when one is on screen, the disk cache next, and
    /// the network only as a last resort.
    private static func image(for url: URL) async -> PlatformImage? {
        if let decoded = ImageCache.shared.object(forKey: url as NSURL) { return decoded }
        if let stored = CoverDiskCache.read(url), let decoded = CoverDecode.image(from: stored.data) { return decoded }
        guard let data = try? await HTTPClient.covers.send(HTTPRequest(url: url)).data else { return nil }
        return CoverDecode.image(from: data)
    }

    static func color(from image: PlatformImage) -> Color? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        // No colour management: the average should stay in the cover's own space.
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)

        let average = UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return nil }

        let lifted = UIColor(
            hue: hue,
            saturation: min(max(saturation * 1.8, 0.35), 0.80),
            brightness: min(max(brightness, 0.45), 0.85),
            alpha: 1)
        return Color(uiColor: lifted)
        #else
        return nil
        #endif
    }
}

private struct CoverTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The colour drawn from the open book's cover, when tinting is enabled.
    /// Detail screens read it instead of threading the colour through every
    /// initializer between the header and the chapter list.
    var coverTint: Color? {
        get { self[CoverTintKey.self] }
        set { self[CoverTintKey.self] = newValue }
    }
}
