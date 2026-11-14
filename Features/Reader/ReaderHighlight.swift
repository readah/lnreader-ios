// ReaderHighlight.swift
// The highlight palette, and the shapes shared with the page.

import SwiftUI

// MARK: - Palette

/// The eight swatches offered by the native selection menu, in the same order.
enum ReaderHighlightColor: String, CaseIterable, Identifiable, Codable, Hashable {
    case green
    case skyBlue
    case pink
    case yellow
    // The eraser, never persisted.
    case clearWhite
    case indigo
    case purple
    case coralRed

    var id: String { rawValue }

    var isClearSwatch: Bool { self == .clearWhite }

    var displayName: String {
        switch self {
        case .green: "Mint"
        case .skyBlue: "Sky"
        case .pink: "Pink"
        case .yellow: "Yellow"
        case .clearWhite: "Erase Highlight"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .coralRed: "Coral"
        }
    }

    /// Saturation for the swatch, the text tint and the underline.
    var hex: String {
        switch self {
        case .green: "#5CE680"
        case .skyBlue: "#54C4FF"
        case .pink: "#F566B8"
        case .yellow: "#F5C745"
        case .clearWhite: "#FFFFFF"
        case .indigo: "#6178F7"
        case .purple: "#9E59F5"
        case .coralRed: "#EB595C"
        }
    }

    private var rgb: (Int, Int, Int) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return (Int((value >> 16) & 255), Int((value >> 8) & 255), Int(value & 255))
    }

    var swatchColor: Color {
        Color(hex: hex) ?? .white
    }

    /// The translucent fill drawn behind highlighted words.
    var settledFillCSS: String {
        if isClearSwatch { return "rgba(92,87,117,0.45)" }
        let (r, g, b) = rgb
        return "rgba(\(r),\(g),\(b),0.34)"
    }
}

// MARK: - Page messages

/// A color chosen from the native selection menu, with the text it applies to.
struct ReaderHighlightRequest: Decodable, Equatable {
    let color: String
    let text: String
    let paragraphIndex: Int
    let startOffset: Int
    let endOffset: Int

    var readerColor: ReaderHighlightColor? {
        ReaderHighlightColor(rawValue: color)
    }
}

/// One persisted highlight, in the shape the page applies with CSS.
struct ReaderStoredHighlight: Codable, Equatable {
    let paragraphIndex: Int
    let startOffset: Int
    let endOffset: Int
    let color: String
}
