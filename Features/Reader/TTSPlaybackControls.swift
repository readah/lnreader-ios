import Foundation
import SwiftUI

struct TTSPlaybackControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPlaying: Bool
    let isBuffering: Bool
    let elapsed: Double
    let duration: Double
    let rate: Double
    let voiceId: String
    let voiceName: String
    let isFollowing: Bool
    let sleepTimerLabel: String
    let playbackStatus: String?
    let onSettings: () -> Void
    let onPlayPause: () -> Void
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void
    let onRate: () -> Void
    let onVoice: () -> Void
    let onBookmark: () -> Void
    let onSleep: () -> Void
    let onFollow: () -> Void
    let onSeek: (Double) -> Void
    let onScrub: (Double?) -> Void

    @State private var scrubValue: Double = 0.0
    @State private var isScrubbing: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if !isFollowing {
                followBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            bottomControlsPanel
        }
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: isFollowing)
    }

    private var followBanner: some View {
        GlassPillButton(action: onFollow) {
            AppLabel("Back to current", systemName: "arrow.uturn.backward.circle.fill", size: 17, relativeTo: .body)
        }
        .accessibilityLabel("Back to current reading position")
        .padding(.top, 72)
    }

    private var bottomControlsPanel: some View {
        VStack(spacing: 2) {
            scrubberSection
            transportRow
            secondaryRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(alignment: .bottom) {
            LinearGradient(colors: TTSVoicePalette.colors(for: voiceId).map { $0.opacity(0.30) } + [.clear], startPoint: .bottomLeading, endPoint: .topTrailing)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                .clipShape(.rect(cornerRadius: 26))
        }
        .appGlassEffect(.regular, in: .rect(cornerRadius: 26))
        .frame(maxWidth: 500)
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
    }

    private var scrubberSection: some View {
        VStack(spacing: 0) {
            AppSlider(
                value: scrubberBinding,
                in: 0...safeRangeUpper,
                onEditingChanged: handleScrubEditing
            )
            .disabled(safeDuration <= 0)
            .accessibilityLabel("Playback progress")
            .accessibilityValue("\(formatTime(displayedTime)) of \(formatTime(safeDuration))")

            HStack {
                Text(formatTime(displayedTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)
                if let playbackStatus { Text(playbackStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)

                Text("-" + formatTime(max(0, safeDuration - displayedTime)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sleepActive: Bool { !(sleepTimerLabel.isEmpty || sleepTimerLabel == "Off") }

    private var transportRow: some View {
        HStack(spacing: 0) {
            Button(action: onSleep) {
                VStack(spacing: 2) {
                    AppIcon(systemName: sleepActive ? "moon.zzz.fill" : "moon.zzz", size: 20, relativeTo: .title3)
                        .font(.title3)
                    if sleepActive {
                        Text(sleepTimerLabel)
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                    }
                }
                .foregroundStyle(sleepActive ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(AppBorderlessButtonStyle())
            .accessibilityLabel(sleepActive ? "Sleep timer: \(sleepTimerLabel)" : "Sleep timer")

            transportButton("gobackward.15", label: "Rewind 15 seconds", action: onSkipBack)

            playPauseButton
                .frame(maxWidth: .infinity)

            transportButton("goforward.30", label: "Fast forward 30 seconds", action: onSkipForward)

            Button(action: onRate) {
                Text(formatRate(rate))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(AppBorderlessButtonStyle())
            .foregroundStyle(.primary)
            .accessibilityLabel("Playback speed \(formatRate(rate))")
        }
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(AppBorderlessButtonStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    private var playPauseButton: some View {
        Button(action: onPlayPause) {
            if isBuffering {
                ProgressView()
            } else {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.bold))
            }
        }
        // `glassProminent` fills with the accent colour, and the accent is white
        // in dark mode, so an untinted prominent button is a white glyph on a
        // white circle. `primaryActionStyle` pairs the fill with its contrast.
        .primaryActionStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel(isBuffering ? "Buffering" : (isPlaying ? "Pause" : "Play"))
    }

    private var secondaryRow: some View {
        ZStack {
            HStack {
                Button(action: onSettings) {
                    AppLabel("Reader settings", systemName: "textformat.size", size: 20, relativeTo: .title3)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(AppBorderlessButtonStyle())
                .foregroundStyle(.primary)

                Spacer()

                Button(action: onBookmark) {
                    AppLabel("Bookmark", systemName: "bookmark", size: 20, relativeTo: .title3)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(AppBorderlessButtonStyle())
                .foregroundStyle(.primary)
            }

            Button(action: onVoice) {
                TTSVoiceChip(voiceId: voiceId, name: voiceName, animated: false)
                    .frame(minHeight: 44)
                    .contentShape(.capsule)
            }
            .buttonStyle(AppPlainButtonStyle())
            .accessibilityLabel("Voice: \(voiceName)")
            .padding(.horizontal, 52)
        }
    }

    private var safeDuration: Double {
        guard duration.isFinite && !duration.isNaN && duration > 0 else { return 0 }
        return duration
    }

    private var safeRangeUpper: Double {
        safeDuration > 0 ? safeDuration : 1.0
    }

    private var clampedElapsed: Double {
        guard elapsed.isFinite && !elapsed.isNaN && elapsed >= 0 else { return 0 }
        return safeDuration > 0 ? min(elapsed, safeDuration) : 0
    }

    private var displayedTime: Double {
        isScrubbing ? scrubValue : clampedElapsed
    }

    private var scrubberBinding: Binding<Double> {
        Binding(
            get: { displayedTime },
            set: { scrubValue = $0; if isScrubbing { onScrub($0) } }
        )
    }

    private func handleScrubEditing(_ isEditing: Bool) {
        if isEditing {
            isScrubbing = true
            scrubValue = clampedElapsed
            onScrub(scrubValue)
        } else {
            isScrubbing = false
            let clampedTarget = min(max(scrubValue, 0), safeDuration)
            onSeek(clampedTarget)
            onScrub(nil)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }

    private func formatRate(_ value: Double) -> String {
        let text = String(format: "%g", value)
        return "\(text)x"
    }
}


/// A voice keeps its colour across chapters, offline playback, and app launches.
struct TTSVoiceChip: View {
    let voiceId: String
    let name: String
    /// The reader passes false: a 30 fps shader in the playback bar would run
    /// for the whole chapter to change nothing you look at twice.
    var animated = true

    var body: some View {
        HStack(spacing: 6) {
            AppIcon(systemName: "waveform", size: 12, relativeTo: .caption).font(.caption.weight(.semibold))
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        // The light can reach white behind the label; a soft shadow keeps the
        // name and the waveform readable over it.
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background { VoiceGlowSurface(voiceId: voiceId, animated: animated, halo: 9) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice: \(name)")
    }
}

/// Base hue plus its two split-complementary accents; stable after random assignment.
enum TTSVoicePalette {
    /// Hues between yellow and teal read as olive mud on dark glass. That band
    /// moves to emerald or mint; every other stored hue is left alone, so a
    /// voice that already looked right keeps its colour.
    private static func safeHue(_ value: Double) -> Double {
        let hue = value - floor(value)
        guard (0.12...0.50).contains(hue), hue != 0.40, hue != 0.46 else { return hue }
        return hue < 0.33 ? 0.40 : 0.46
    }

    /// The hue a voice was assigned. One assignment feeds the gradient, the
    /// shader and the halo, so all three always agree.
    static func baseHue(for voiceId: String) -> Double {
        let defaults = UserDefaults.standard, key = "tts.voice-palette.v2"
        var assigned = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        if let saved = assigned[voiceId], saved.isFinite {
            return safeHue(saved)
        }
        // Curated hues: warm ambers and roses, emerald and mint, cool azures,
        // violet. Nothing in the yellow-green band, which reads as olive.
        let curated: [Double] = [0.02, 0.06, 0.10, 0.40, 0.46, 0.56, 0.60, 0.64, 0.68, 0.90, 0.94, 0.97]
        func distance(_ candidate: Double) -> Double {
            assigned.values.map { let d = abs(candidate - safeHue($0)); return min(d, 1 - d) }.min() ?? 1
        }
        let hue = curated.max { distance($0) < distance($1) } ?? 0.02
        assigned[voiceId] = hue
        defaults.set(assigned, forKey: key)
        return hue
    }

    /// Analogous partners keep each voice in one colour family, so no gradient
    /// ever pairs green with purple.
    static func hues(for voiceId: String) -> SIMD3<Float> {
        let hue = baseHue(for: voiceId)
        return SIMD3(Float(hue),
                     Float((hue + 0.045).truncatingRemainder(dividingBy: 1)),
                     Float((hue - 0.05 + 1).truncatingRemainder(dividingBy: 1)))
    }

    static func accent(for voiceId: String) -> Color {
        Color(hue: baseHue(for: voiceId), saturation: 0.62, brightness: 0.58)
    }

    static func colors(for voiceId: String) -> [Color] {
        let hue = baseHue(for: voiceId)
        return [Color(hue: hue, saturation: 0.60, brightness: 0.54),
                Color(hue: (hue + 0.045).truncatingRemainder(dividingBy: 1), saturation: 0.54, brightness: 0.44),
                Color(hue: (hue - 0.05 + 1).truncatingRemainder(dividingBy: 1), saturation: 0.64, brightness: 0.60)]
    }
}
