import Foundation

/// Pure geometry shared by the gesture, the animated lens and headless checks.
enum OnboardingGeometry {
    static func progress(y: Double, height: Double) -> Double {
        clamp((height * 0.91 - y) / max(height * 0.49, 1))
    }

    static func smooth(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        let t = clamp((value - lower) / max(upper - lower, 0.0001))
        return t * t * (3 - 2 * t)
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    static func titleVisibility(progress: Double) -> Double {
        smooth(0.32, 0.56, progress)
    }

    static func dome(width: Double, height: Double) -> OnboardingLensMetrics {
        OnboardingLensMetrics(x: width / 2, y: height + width * 0.24,
                              rx: width * 0.68, ry: width * 0.68, power: 0, dispersion: 0)
    }

    static func dock(width: Double, height: Double) -> OnboardingLensMetrics {
        let radius = min(width * 0.1, 39)
        return OnboardingLensMetrics(x: width / 2, y: height * 0.425,
                                     rx: radius, ry: radius, power: 0.65, dispersion: 0.55)
    }

    static func drag(x: Double, y: Double, width: Double, height: Double) -> OnboardingLensMetrics {
        let p = progress(y: y, height: height)
        let detach = smooth(0, 0.22, p)
        let resting = dome(width: width, height: height)
        let radius = width * (0.315 - 0.145 * smooth(0.18, 0.90, p))
        let targetX = width / 2 + (x - width / 2) * 0.42
        let targetY = min(max(y, height * 0.20), height * 0.96) + radius * 0.30

        return OnboardingLensMetrics(
            x: resting.x + (targetX - resting.x) * detach,
            y: resting.y + (targetY - resting.y) * detach,
            rx: resting.rx + (radius - resting.rx) * detach,
            ry: resting.ry + (radius - resting.ry) * detach,
            power: smooth(0.04, 0.22, p), dispersion: smooth(0.10, 0.27, p))
    }

    static func shouldDock(y: Double, predictedY: Double, height: Double) -> Bool {
        let p = progress(y: y, height: height)
        return p > 0.48 || (p > 0.22 && predictedY < height * 0.55)
    }
}

struct OnboardingLensMetrics: Equatable {
    // SIMD storage lets SwiftUI interpolate every optical and geometric value together.
    var values: SIMD8<Double>

    init(x: Double, y: Double, rx: Double, ry: Double, power: Double, dispersion: Double) {
        values = SIMD8(x, y, rx, ry, power, dispersion, 0, 0)
    }

    var x: Double { values[0] }
    var y: Double { values[1] }
    var rx: Double { values[2] }
    var ry: Double { values[3] }
    var power: Double { values[4] }
    var dispersion: Double { values[5] }

}
