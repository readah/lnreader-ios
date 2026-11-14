import SwiftUI

/// Bundled cover thumbnails emerge in staggered waves, inside the sampled scene.
struct OnboardingFountain: View {
    let start: Date?
    let size: CGSize
    let pushedUp: Bool
    let reduceMotion: Bool

    // Lead with the requested novels, then mix the rest of the supplied collection.
    private static let covers = [17, 28, 29, 30, 1, 2, 31, 32, 8, 9, 10, 3, 6, 7, 23, 4,
                                 5, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 24, 25, 26, 27]
    private static let positions: [CGPoint] = [
        .init(x: 6, y: -220), .init(x: -24, y: -190), .init(x: 62, y: -150),
        .init(x: -12, y: -130), .init(x: -68, y: -168), .init(x: 30, y: -194),
        .init(x: -108, y: -118), .init(x: -60, y: -92), .init(x: 110, y: -105),
        .init(x: 82, y: -210), .init(x: -112, y: -220), .init(x: 12, y: -270),
        .init(x: 135, y: -165), .init(x: -144, y: -175), .init(x: -56, y: -265),
        .init(x: 2, y: -60), .init(x: -48, y: -60), .init(x: 53, y: -55),
        .init(x: -18, y: -118), .init(x: 50, y: -132), .init(x: -99, y: -74),
        .init(x: 108, y: -65), .init(x: -5, y: -185), .init(x: -83, y: -201),
        .init(x: 93, y: -185), .init(x: -153, y: -112), .init(x: 153, y: -121),
        .init(x: 5, y: -321), .init(x: -120, y: -280), .init(x: 120, y: -270),
        .init(x: 65, y: -300), .init(x: -155, y: -250)
    ]

    var body: some View {
        if let start {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                let elapsed = reduceMotion ? 10 : max(0, timeline.date.timeIntervalSince(start))
                ZStack {
                    ForEach(0..<Self.positions.count, id: \.self) { index in
                        bead(index: index, elapsed: elapsed)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private func bead(index: Int, elapsed: Double) -> some View {
        let age = elapsed - Double(index) * 0.095
        // Grow before accelerating out of the pearl: several visible frames stay
        // inside its rim, where the lens magnifies and disperses the cover artwork.
        let travel = OnboardingGeometry.smooth(0, 0.95, age)
        let emergence = OnboardingGeometry.smooth(0, 0.24, age)
        let spread = min(size.width / 390, 1.4)
        let heightScale = min(size.height / 844, 1.35)
        let target = Self.positions[index]
        let phase = Double(index) * 1.71
        let driftX = reduceMotion ? 0 : sin(elapsed * 1.15 + phase) * 4 * travel
        let driftY = reduceMotion ? 0 : cos(elapsed * 1.05 + phase) * 5 * travel
        let diameter = (index < 15 ? Double(29 + index % 4 * 4) : Double(44 + index % 5 * 5)) * spread
        let x = size.width / 2 + target.x * spread * travel + driftX
        let y = size.height * 0.425 + target.y * heightScale * travel + driftY
        let coverName = String(format: "OnboardingCover%02d", Self.covers[index])
        return OnboardingCoverBead(asset: coverName)
            .frame(width: diameter, height: diameter)
            .scaleEffect(max(0.025, emergence))
            .opacity(age <= 0 ? 0 : min(1, age / 0.10))
            .position(x: x, y: y)
            .offset(x: pushedUp ? target.x * 0.12 : 0, y: pushedUp ? -size.height * 0.17 : 0)
    }
}

private struct OnboardingCoverBead: View {
    let asset: String

    var body: some View {
        GeometryReader { geometry in
            Image(asset)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(.circle)
                .overlay {
                    Circle().fill(RadialGradient(
                        colors: [.white.opacity(0.20), .clear, .black.opacity(0.16)],
                        center: .init(x: 0.30, y: 0.20), startRadius: 0,
                        endRadius: geometry.size.width * 0.85))
                }
                .overlay {
                    Circle().strokeBorder(LinearGradient(
                        colors: [.white.opacity(0.7), .white.opacity(0.08), .white.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.25), radius: 3, y: 3)
        }
    }
}
