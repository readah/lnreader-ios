import SwiftUI

/// The supplied MetalLoginDemo background, with a stable clock and accessibility
/// pausing. Its original shader, palette, domain warping and touch response stay intact.
struct AuroraBackground: View {
    var touch: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || scenePhase != .active)) { context in
            let time = reduceMotion ? Float(0) : Float(context.date.timeIntervalSince(start))
            Rectangle()
                .visualEffect { content, proxy in
                    content.colorEffect(
                        ShaderLibrary.auroraBackground(
                            .float2(proxy.size), .float(time), .float2(touch)
                        )
                    )
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct OnboardingBackdrop: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.black)
                .colorEffect(ShaderLibrary.onboardingBackdrop(
                    .float2(geometry.size.width, geometry.size.height), .float(displayScale)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
