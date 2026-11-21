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
    static let defaultStrength = 0.50
}

/// One living cover backdrop shared by the detail screen, the audio sheet and
/// the chapter directory: a blurred, over-saturated cover under a tint glow and
/// a scrim deep enough for white text. Not a wash of colour over the shader
/// backdrop — the same canvas at every depth, so nothing seams on push.
struct EntryAtmosphericBackdrop: View {
    let coverURL: String?
    var tint: Color?
    var strength: Double = AppearanceTint.defaultStrength
    var scrimDepth: Double = 0.72

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    private var clampedStrength: Double { min(max(strength, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            let maxDim = max(proxy.size.width, proxy.size.height)
            let isSettled = settled || reduceMotion

            // Driven straight off the settings slider so 10% reads whisper-subtle
            // and 100% reads vivid, with no fixed floor to flatten the range.
            let blurOpacity = clampedStrength * 0.85
            let glowPrimary = clampedStrength * 0.50
            let glowSecondary = clampedStrength * 0.24
            // The scrim opens a little at high strength so the tint is not crushed.
            let dynamicBottomScrim = max(0.55, scrimDepth - clampedStrength * 0.18)

            ZStack {
                Color.black

                if !reduceTransparency, clampedStrength > 0 {
                    if let coverURL, let url = URL(string: coverURL) {
                        CustomAsyncImage(url: url, maxPixelSize: 320) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        // Extra scale gives headroom for both the 65pt blur and the downward drift.
                        .scaleEffect(1.44)
                        .blur(radius: 65, opaque: true)
                        .saturation(1.25)
                        .offset(y: isSettled ? 0 : -48)
                        .opacity(isSettled ? blurOpacity : blurOpacity * 0.55)
                    }

                    // Always mounted so an async `coverTint` catches the downward glide smoothly.
                    let activeTint = tint ?? .clear
                    RadialGradient(
                        colors: [
                            activeTint.opacity(glowPrimary),
                            activeTint.opacity(glowSecondary),
                            .clear
                        ],
                        center: UnitPoint(x: 0.5, y: 0.42),
                        startRadius: 20,
                        endRadius: maxDim * 0.90
                    )
                    .blendMode(.plusLighter)
                    .scaleEffect(isSettled ? 1.0 : 0.84, anchor: .top)
                    .offset(y: isSettled ? 0 : -proxy.size.height * 0.30)
                    .opacity(isSettled ? 1 : 0.6)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: tint != nil)
                } else if let tint, clampedStrength > 0 {
                    tint.opacity(clampedStrength * 0.25)
                }

                // Readability scrim stays anchored while the light flows underneath it.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.12), location: 0.0),
                        .init(color: .black.opacity(0.28), location: 0.58),
                        .init(color: .black.opacity(0.52), location: 0.84),
                        .init(color: .black.opacity(dynamicBottomScrim), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !settled else { return }
            if reduceMotion {
                settled = true
            } else {
                // Exponential ease-out: glides visibly down on open, then locks smoothly in place.
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.25)) {
                    settled = true
                }
            }
        }
    }
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
        if let decoded = ImageCache.cached(url) { return decoded }
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

private struct CoverTintStrengthKey: EnvironmentKey {
    static let defaultValue: Double = AppearanceTint.defaultStrength
}

extension EnvironmentValues {
    /// How strongly tinting should read, 0...1, injected once at the root from
    /// the Appearance slider. Every sheet, card and control reads this instead
    /// of hard-coding its own opacity, so one slider drives the whole system.
    var coverTintStrength: Double {
        get { self[CoverTintStrengthKey.self] }
        set { self[CoverTintStrengthKey.self] = newValue }
    }
}
