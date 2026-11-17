// ReaderToolbar.swift
// Glass overlay toolbar with chapter navigation and settings controls.

import SwiftUI

struct ReaderToolbar: View {
    let chapterName: String
    let hasPrevious: Bool
    let hasNext: Bool
    let isPreparingTTS: Bool
    let onDismiss: () -> Void
    let onSettings: () -> Void
    let onTTSStart: () -> Void
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onChapterClick: () -> Void
    var onComments: (() -> Void)? = nil
    var isListening = false

    @Namespace private var topNamespace
    @Namespace private var bottomNamespace
    @AppStorage("tts.enabled") private var ttsEnabled = true

    var body: some View {
        VStack {
            topBar
            Spacer()
            if !isListening { bottomBar }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        AppGlassEffectContainer {
            ZStack {
                HStack {
                    GlassIconButton(symbol: "chevron.left", label: "Close reader", action: onDismiss)
                        .glassEffectID("back", in: topNamespace)
                    Spacer()
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity))

                GlassPillButton(action: onChapterClick) {
                    Text(chapterName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .glassEffectID("title", in: topNamespace)
                // Both sides of the pill are the same distance from the same
                // sized control, so the title sits centred between them.
                .padding(.horizontal, GlassMetrics.edgeInset + GlassMetrics.side + GlassMetrics.pillGap)
                .accessibilityLabel("Chapters: \(chapterName)")
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale), removal: .opacity))

                HStack {
                    Spacer()
                    if ttsEnabled { ttsButton }
                }
            }
        }
        .padding(.horizontal, GlassMetrics.edgeInset)
        .padding(.top, 8)
    }

    @ViewBuilder private var ttsButton: some View {
        if isPreparingTTS {
            ProgressView()
                .controlSize(.small)
                .frame(width: GlassMetrics.side, height: GlassMetrics.side)
                .appGlassEffect(.regular, in: .circle)
                .glassEffectID("tts-trigger", in: topNamespace)
        } else {
            GlassIconButton(
                symbol: isListening ? "stop.fill" : "waveform",
                label: isListening ? "Stop listening" : "Listen to chapter",
                action: onTTSStart
            )
            .glassEffectID("tts-trigger", in: topNamespace)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        AppGlassEffectContainer {
            HStack(spacing: 8) {
                if let onComments {
                    // Settings and comments act on the same page, so they share
                    // one capsule instead of floating as two separate circles.
                    GlassIconGroup(
                        first: .init(symbol: "textformat.size", label: "Reader settings", action: onSettings),
                        second: .init(symbol: "bubble.left.and.bubble.right", label: "Comments", action: onComments)
                    )
                    .glassEffectID("settings-group", in: bottomNamespace)
                } else {
                    GlassIconButton(symbol: "textformat.size", label: "Reader settings", action: onSettings)
                        .glassEffectID("settings", in: bottomNamespace)
                }
                Spacer()
                GlassStepper(
                    backLabel: "Previous chapter",
                    forwardLabel: "Next chapter",
                    canGoBack: hasPrevious,
                    canGoForward: hasNext,
                    back: onPreviousChapter,
                    forward: onNextChapter
                )
                .glassEffectID("nav-group", in: bottomNamespace)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}
