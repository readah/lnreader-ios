// VoiceGlow.swift
// The living glass behind a narrator's identity.
//
// Ported from GlassGlow: lights drift through a shape's distance field and the
// edge refracts them. A voice chip, a card and a dot have known rounded-rect
// shapes, so the field is analytic here — one fragment pass, no mask, no mip
// chain — which is what lets it run in a list without heating the phone.

import SwiftUI

/// A narrator's voice drawn as light moving through tinted glass.
///
/// The light moves once, for about a second and a half, easing to a stop, and
/// it stops exactly on the frame a still surface draws. `animated: false`
/// starts already there, which is what the reader and every unselected voice
/// use.
struct VoiceGlowSurface: View {
    let voiceId: String
    /// Nil makes a capsule, which is a circle on a square frame.
    var cornerRadius: CGFloat? = nil
    var animated = true
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var start: Date?
    @State private var settled = false

    /// One eased drift. `phase(at:)` stops changing after this, so the paused
    /// timeline and the resting frame agree exactly.
    ///
    /// The distance and duration are set so the lights open at a little under
    /// the old six-second loop's speed (0.167 loop/s), then decelerate into
    /// the resting frame rather than stopping dead.
    static let settleDuration: TimeInterval = 1.5
    private static let drift: Double = 0.135
    /// The frame every surface rests on, and the one the drift arrives at.
    static let restPhase: Float = 0

    var body: some View {
        let hues = TTSVoicePalette.hues(for: voiceId)
        Group {
            if reduceTransparency {
                GeometryReader { geometry in
                    VoiceGlassShape(cornerRadius: radius(for: geometry.size))
                        .fill(LinearGradient(colors: TTSVoicePalette.colors(for: voiceId),
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            } else if animated && !reduceMotion, let start {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: settled)) { timeline in
                    glass(hues: hues, phase: Self.phase(at: timeline.date, since: start))
                }
            } else {
                // Before the drift starts, show its first frame, so a reused
                // cell never flashes the resting image and then rewinds.
                let phase = animated && !reduceMotion ? Self.startPhase : Self.restPhase
                glass(hues: hues, phase: phase)
            }
        }
        .onAppear {
            settled = false
            start = .now
        }
        .onChange(of: animated) { _, isAnimated in
            // Choosing a voice in the picker hands it the motion.
            guard isAnimated else { return }
            settled = false
            start = .now
        }
        .task(id: start) {
            guard start != nil else { return }
            try? await Task.sleep(for: .seconds(Self.settleDuration))
            settled = true
        }
        .accessibilityHidden(true)
    }

    private func glass(hues: SIMD3<Float>, phase: Float) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let shape = VoiceGlassShape(cornerRadius: radius(for: size))
            shape
                .fill(.white)
                .colorEffect(ShaderLibrary.voiceGlass(
                    .float2(Float(size.width), Float(size.height)),
                    .float(Float(shape.cornerRadius)),
                    .float(phase),
                    .float3(hues.x, hues.y, hues.z),
                    .float(Float(intensity))
                ))
        }
    }

    /// The shader gets the radius as a number, so it has to agree with the path.
    private func radius(for size: CGSize) -> CGFloat {
        let wanted = cornerRadius ?? size.height / 2
        return max(0, min(wanted, min(size.width, size.height) / 2))
    }

    private struct VoiceGlassShape: Shape {
        var cornerRadius: CGFloat

        func path(in rect: CGRect) -> Path {
            Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        }
    }

    /// Ease-out sine over a fixed distance: the lights start at the old loop's
    /// pace, slow smoothly, and land on the resting frame with no final step.
    static func phase(at date: Date, since start: Date) -> Float {
        let progress = min(max(date.timeIntervalSince(start) / settleDuration, 0), 1)
        let eased = sin(progress * .pi / 2)
        return startPhase + Float(eased) * Float(drift)
    }

    private static var startPhase: Float { restPhase - Float(drift) }
}

/// A 12pt voice marker for a row that is about the recording, not the narrator.
struct VoiceGlowDot: View {
    let voiceId: String

    var body: some View {
        VoiceGlowSurface(voiceId: voiceId)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }
}
