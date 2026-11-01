// MangaReadingMode.swift - How the reader lays pages out.

import SwiftUI

/// Paged (one screen at a time) or continuous strip.
enum MangaReadingMode: String, Codable, CaseIterable, Identifiable {
    case pager
    case webtoon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pager: "Paged"
        case .webtoon: "Webtoon"
        }
    }

    var iconName: String {
        switch self {
        case .pager: "book.pages"
        case .webtoon: "scroll"
        }
    }
}

/// Which way a page turn advances in paged mode.
enum MangaPagingDirection: String, Codable, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftToRight: "Left to right"
        case .rightToLeft: "Right to left"
        }
    }

    /// SwiftUI's page view reverses its swipe handling with the layout direction,
    /// so this is all a manga reader needs for RTL.
    var layoutDirection: LayoutDirection {
        switch self {
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }
}
