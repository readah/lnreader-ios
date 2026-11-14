import SwiftUI
import UIKit

/// One asynchronous drawing surface, rather than a hierarchy of clipped images,
/// geometry readers, gradients and shadows rebuilt for every particle every frame.
struct OnboardingFountain: View {
    let start: Date?
    let size: CGSize

    let reduceMotion: Bool
    var isActive = true
    @State private var textures: [CGImage?] = []

    // Keep the requested novels and the most recognizable manhwa in the first wave.
    private nonisolated static let covers = [17, 28, 29, 30, 1, 2, 31, 32, 8, 9,
                                              10, 3, 6, 7, 23, 4, 5, 12, 21, 25]
    private nonisolated static let positions: [CGPoint] = [
        .init(x: 6, y: -220), .init(x: -24, y: -190), .init(x: 62, y: -150),
        .init(x: -12, y: -130), .init(x: -68, y: -168), .init(x: 30, y: -194),
        .init(x: -108, y: -118), .init(x: -60, y: -92), .init(x: 110, y: -105),
        .init(x: 82, y: -210), .init(x: -112, y: -220), .init(x: 12, y: -270),
        .init(x: 135, y: -165), .init(x: -144, y: -175), .init(x: -56, y: -265),
        .init(x: 2, y: -60), .init(x: -48, y: -60), .init(x: 53, y: -55),
        .init(x: -18, y: -118), .init(x: 50, y: -132)
    ]

    var body: some View {
        Group {
            if let start {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { timeline in
                    let elapsed = reduceMotion ? 10 : max(0, timeline.date.timeIntervalSince(start))
                    Canvas(rendersAsynchronously: true) { context, _ in
                        draw(in: &context, elapsed: elapsed)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .task {
            // Starts while the dome is still resting, not when the first cover emits.
            textures = await Self.prepareTextures()
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, elapsed: Double) {
        let spread = min(size.width / 390, 1.4)
        let heightScale = min(size.height / 844, 1.35)
        for index in Self.covers.indices {
            guard textures.indices.contains(index), let texture = textures[index] else { continue }
            let age = elapsed - Double(index) * 0.13
            guard age > 0 else { continue }
            let travel = OnboardingGeometry.smooth(0, 0.95, age)
            let emergence = OnboardingGeometry.smooth(0, 0.24, age)
            let target = Self.positions[index]
            let phase = Double(index) * 1.71
            let driftX = reduceMotion ? 0 : sin(elapsed * 1.15 + phase) * 4 * travel
            let driftY = reduceMotion ? 0 : cos(elapsed * 1.05 + phase) * 5 * travel
            let diameter = (index < 12 ? Double(29 + index % 4 * 4) : Double(44 + index % 5 * 5)) * spread * max(0.025, emergence)
            let x = size.width / 2 + target.x * spread * travel + driftX
            let y = size.height * 0.425 + target.y * heightScale * travel + driftY
            let rect = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
            let circle = Path(ellipseIn: rect)
            var bead = context
            bead.opacity = min(1, age / 0.10)
            bead.clip(to: circle)
            bead.draw(Image(decorative: texture, scale: 1), in: rect)
            bead.fill(circle, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.12)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            bead.stroke(circle, with: .color(.white.opacity(0.40)), lineWidth: 0.8)
        }
    }

    /// Four bounded workers perform asset lookup, downsampling and bitmap decoding
    /// away from the main actor. Only ready-to-draw, immutable textures are published.
    @concurrent
    private nonisolated static func prepareTextures() async -> [CGImage?] {
        await withTaskGroup(of: [(Int, CGImage?)].self) { group in
            for worker in 0..<4 {
                group.addTask {
                    var batch: [(Int, CGImage?)] = []
                    for index in stride(from: worker, to: covers.count, by: 4) {
                        guard !Task.isCancelled else { break }
                        let image = autoreleasepool { decodeCover(covers[index]) }
                        batch.append((index, image))
                    }
                    return batch
                }
            }
            // Bounded ownership, not an unbounded/global compressed-image cache:
            // twenty 128×128 RGBA textures occupy at most 1.25 MiB.
            var result = [CGImage?](repeating: nil, count: covers.count)
            for await batch in group {
                for (index, image) in batch { result[index] = image }
            }
            return result
        }
    }

    private nonisolated static func decodeCover(_ id: Int) -> CGImage? {
        let name = String(format: "OnboardingCover%02d", id)
        guard let source = UIImage(named: name)?.cgImage,
              let bitmap = CGContext(data: nil, width: 128, height: 128,
                                     bitsPerComponent: 8, bytesPerRow: 128 * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .medium
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        return bitmap.makeImage()
    }
}
