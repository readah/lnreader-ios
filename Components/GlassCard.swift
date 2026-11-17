// GlassCard.swift
// Reusable glass card container for floating UI elements.

import SwiftUI

/// A reusable container that wraps content in a Liquid Glass card effect.
/// Use only for controls and navigation elements — never for content.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = LayoutConstants.glassCornerRadius
    var tint: Color? = nil
    var interactive: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding()
            .appGlassEffect(glass, in: .rect(cornerRadius: cornerRadius), frostTint: tint?.opacity(0.18))
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.18)) }
        return interactive ? glass.interactive() : glass
    }
}
#Preview {
    VStack(spacing: 16) {
        GlassCard {
            Label("Default Glass Card", systemImage: "sparkles")
        }

        GlassCard(tint: .blue) {
            Label("Tinted Glass Card", systemImage: "paintbrush")
        }
    }
    .padding()
}
