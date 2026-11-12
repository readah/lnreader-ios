// ErrorDetailBox.swift
// A failure's technical detail, in a box the user can copy from.

import SwiftUI

/// The raw text of an error, monospaced, with a clipboard button.
///
/// For a failure the user may need to report or look up: a url, an HTTP status, what the
/// Cloudflare solver tried. Plain prose would wrap the url mid-word and could not be pasted.
struct ErrorDetailBox: View {
    let text: String

    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Typography.body)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied" : "Copy error")
        }
        .padding(12)
        .background(AppTheme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.hairline, lineWidth: 0.5))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copied = false }
        }
    }

    /// A pasteboard write from code is silent, so the button acknowledges it itself.
    private func copy() {
        UIPasteboard.general.string = text
        Haptics.shared.impact(.light)
        AccessibilityNotification.Announcement("Error copied").post()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { copied = true }
    }
}

#Preview {
    ErrorDetailBox(text: "Cloudflare challenge blocked https://example.com/api/v2/search\nSolving on https://example.com/ failed: webkit agent: no clearance in 12s")
        .padding()
}
