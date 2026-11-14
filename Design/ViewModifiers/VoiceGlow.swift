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
/// The light moves once, for a second, easing to a stop, then rests: a voice
/// remembered as a still image with motion in it, not a perpetual animation
/// competing with the text beside it. `animated: false` starts it already at
/// rest, which is what the reader and every unselected voice use.
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
    /// timeline and the frame it left on agree exactly.
    ///
    /// The distance is set so the opening speed is a little under the old
    /// six-second loop (0.167 loop/s): the lights move as they always did,
    /// only gently slowing until they stop about a second in.
    static let settleDuration: TimeInterval = 1.8
    private static let drift: Double = 0.08

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
                // Starts on the rest frame, drifts forward and settles there, so
                // nothing snaps when the surface appears or is reused by a list.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: settled)) { timeline in
                    glass(hues: hues, phase: Self.phase(at: timeline.date, since: start, voiceId: voiceId))
                }
            } else {
                glass(hues: hues, phase: Self.restPhase(for: voiceId))
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
        // The gradient used to sit under the text; here the voice's colour
        // leaks out from behind the glass instead, which reads at 12pt too.
        .shadow(color: TTSVoicePalette.accent(for: voiceId).opacity(0.35),
                radius: cornerRadius == nil ? 6 : 14, y: 1)
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

    /// Ease-out cubic over a fixed distance: fast at first, then visibly
    /// slowing into the last frame instead of stopping dead.
    static func phase(at date: Date, since start: Date, voiceId: String) -> Float {
        let progress = min(max(date.timeIntervalSince(start) / settleDuration, 0), 1)
        let eased = 1 - pow(1 - progress, 3)
        return shift(for: voiceId) + Float(eased * drift)
    }

    /// Where every surface starts and where a still one rests. Seeded by the
    /// voice, so two chips with different hues also rest on different frames.
    static func restPhase(for voiceId: String) -> Float {
        shift(for: voiceId)
    }

    private static func shift(for voiceId: String) -> Float {
        let hash = voiceId.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return Float(hash % 1000) / 1000
    }
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
