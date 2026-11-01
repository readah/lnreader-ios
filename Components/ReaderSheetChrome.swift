// ReaderSheetChrome.swift
// The chrome the reader settings sheets share: the close-and-title header, the
// on/off segment that sits beside the font stepper, and the info popover that
// keeps long explanations out of the sheet body.
//
// Sizes come from `GlassMetrics`, so these line up with the reader's own
// floating controls instead of inventing a second set of glass dimensions.

import SwiftUI

// MARK: - Header

/// The header both reader sheets open with: a glass close button, then the
/// title, left aligned.
///
/// Drawn by hand rather than put in a navigation bar because the title has to
/// sit on the same line as the close button, the way the system's own reader
/// sheets do it. The gap between them is fixed here so the title never crowds
/// the button.
struct ReaderSheetHeader: View {
    let title: String
    /// Title and close glyph colour. Over the theme preview the header has to
    /// follow the paper's text colour, not the system one.
    var foreground: Color = .primary
    let onClose: () -> Void
    /// Adds a check on the trailing edge and centres the title, the way the
    /// system reader's customize sheet does.
    var onConfirm: (() -> Void)? = nil

    var body: some View {
        Group {
            if onConfirm == nil {
                HStack(spacing: 14) {
                    closeButton
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
            } else {
                ZStack {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    HStack(spacing: 0) {
                        closeButton
                        Spacer(minLength: 0)
                        if let onConfirm {
                            Button(action: onConfirm) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 38, height: 38)
                                    .background(Color.white, in: .circle)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Keep changes")
                        }
                    }
                }
            }
        }
        .frame(height: GlassMetrics.side)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

// MARK: - Segments

/// One icon segment of a capsule that reads as on or off.
///
/// `GlassIconGroup`'s segments have no state; these do, and they draw a filled
/// pill behind the glyph when the setting is on, so two toggles sitting beside
/// the font stepper show their state without a label.
struct GlassToggleSegment: View {
    let symbol: String
    let label: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(GlassMetrics.iconFont)
                .foregroundStyle(isOn ? AppTheme.onPrimaryFill : Color.primary)
                .frame(height: GlassMetrics.side)
                .padding(.horizontal, GlassMetrics.segmentInset)
                .background {
                    if isOn {
                        Capsule(style: .continuous).fill(AppTheme.primaryFill)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Action row

/// A full-width glass capsule with a symbol and a title: the row that opens the
/// rest of the sheet.
struct SheetActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: GlassMetrics.side)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Info popover

/// A small ⓘ that explains a setting in a popover.
///
/// Reader settings are dense, and a paragraph of footer text under every
/// section drowns the controls. The explanation lives here instead, one tap
/// away, and the sheet stays quiet.
struct InfoButton: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More about this setting")
        .popover(isPresented: $isShowing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(16)
                .frame(width: 280)
                // Keep it a popover on iPhone too; adapting to a sheet would
                // cover the very control being explained.
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A section header with its explanation behind an ⓘ.
struct SettingsSectionHeader: View {
    let title: String
    let info: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(text: info)
        }
    }
}
