// GlassControls.swift
// The one set of floating glass controls. Readers, overlays and sheets build
// their chrome from these instead of hand-rolling `.glassEffect` on a frame.
//
// Every control is drawn from `GlassMetrics`, so a round button, a stepper
// segment and an icon-group segment are the same height and the same weight.
// Mixing `.appGlassButtonStyle()` with a hand-built capsule used to leave the
// back button, the TTS button and the settings/comments pair at slightly
// different sizes on the same screen.

import SwiftUI

/// Shared geometry for the floating controls.
enum GlassMetrics {
    /// Circle diameter, and the height of every capsule. One number, so a
    /// round button lines up with the segment beside it.
    static let side: CGFloat = 46
    /// Horizontal padding inside a capsule segment.
    static let segmentInset: CGFloat = 18
    /// Gap between the screen edge and a control.
    static let edgeInset: CGFloat = 12
    /// Gap between a side control and a centred pill.
    static let pillGap: CGFloat = 8
    static let iconFont: Font = .body.weight(.semibold)
}

/// A round, icon-only glass button.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            AppIcon(systemName: symbol, size: 17)
                .font(GlassMetrics.iconFont)
                .frame(width: GlassMetrics.side, height: GlassMetrics.side)
                .contentShape(.circle)
        }
        .buttonStyle(AppPlainButtonStyle())
        .appGlassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// A capsule glass button holding a title and optional symbol.
struct GlassPillButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(height: GlassMetrics.side)
                .padding(.horizontal, 16)
                .contentShape(.capsule)
        }
        .buttonStyle(AppPlainButtonStyle())
        .appGlassEffect(.regular.interactive(), in: .capsule)
    }
}

/// A round glass menu. Same metrics as `GlassIconButton`, so a menu and a
/// button sitting in the same row are the same size whatever their glyphs
/// look like — `magnifyingglass` is a much wider symbol than
/// `line.3.horizontal.decrease`, and sizing to the glyph made the search
/// control visibly bigger than the filter one.
struct GlassMenuButton<Content: View>: View {
    let symbol: String
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        AppMenu {
            content()
        } label: {
            AppIcon(systemName: symbol, size: 17)
                .font(GlassMetrics.iconFont)
                .frame(width: GlassMetrics.side, height: GlassMetrics.side)
                .contentShape(.circle)
        }
        .buttonStyle(AppPlainButtonStyle())
        .appGlassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// One tappable segment of a capsule: an icon on a fixed height, with the same
/// horizontal inset everywhere so two segments read as equal.
private struct GlassSegment: View {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppIcon(systemName: symbol, size: 17)
                .font(GlassMetrics.iconFont)
                .frame(height: GlassMetrics.side)
                .padding(.horizontal, GlassMetrics.segmentInset)
                .contentShape(.rect)
        }
        .buttonStyle(AppPlainButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// The hairline between two segments. Decorative, so it stays out of the
/// accessibility tree.
private struct GlassSegmentDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }
}

/// Previous / next as one glass capsule with a system separator between them.
struct GlassStepper: View {
    let backLabel: String
    let forwardLabel: String
    var canGoBack = true
    var canGoForward = true
    var back: () -> Void
    var forward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            GlassSegment(symbol: "chevron.left", label: backLabel, enabled: canGoBack, action: back)
            GlassSegmentDivider()
            GlassSegment(symbol: "chevron.right", label: forwardLabel, enabled: canGoForward, action: forward)
        }
        .appGlassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Two icon actions as one glass capsule, split like `GlassStepper`.
///
/// A pair that belongs together (reader settings and comments) reads as a
/// single control instead of two circles that never quite match.
struct GlassIconGroup: View {
    struct Item {
        let symbol: String
        let label: String
        let action: () -> Void

        init(symbol: String, label: String, action: @escaping () -> Void) {
            self.symbol = symbol
            self.label = label
            self.action = action
        }
    }

    let first: Item
    let second: Item

    var body: some View {
        HStack(spacing: 0) {
            GlassSegment(symbol: first.symbol, label: first.label, action: first.action)
            GlassSegmentDivider()
            GlassSegment(symbol: second.symbol, label: second.label, action: second.action)
        }
        .appGlassEffect(.regular.interactive(), in: .capsule)
    }
}

/// A search field in clear glass, the same height as every floating control.
/// Clear rather than regular: the field sits over content it filters, so the
/// list stays visible through it while typing.
struct GlassSearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(systemName: "magnifyingglass", size: 15, relativeTo: .body)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focus)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    AppIcon(systemName: "xmark.circle.fill", size: 15, relativeTo: .body)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .contentShape(.circle)
                }
                .buttonStyle(AppPlainButtonStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: GlassMetrics.side)
        .appGlassEffect(.clear.interactive(), in: .capsule)
    }
}
