// SortOrder.swift - Sort orders and direction for the library view

import Foundation

/// Sort orders for the library view
enum SortOrder: String, Codable, CaseIterable, Identifiable {
    case alphabetical = "Alphabetical"
    case lastRead = "Last Read"
    case lastUpdated = "Last Updated"
    case totalChapters = "Total Chapters"
    case unread = "Unread"
    case dateAdded = "Date Added"
    case latestChapter = "Latest Chapter"
    case chapterFetched = "Chapter Fetch Date"

    var id: String { rawValue }

    /// `lastUpdated` keeps its stored raw value; it is the time of the last
    /// refresh from the source, which is what "checked" means to a reader.
    var displayName: String {
        self == .lastUpdated ? "Last Checked" : rawValue
    }

    var iconName: String {
        switch self {
        case .alphabetical: "textformat.abc"
        case .lastRead: "book"
        case .lastUpdated: "clock"
        case .totalChapters: "list.number"
        case .unread: "eye.slash"
        case .dateAdded: "calendar"
        case .latestChapter: "text.badge.checkmark"
        case .chapterFetched: "arrow.down.circle"
        }
    }
}

/// Sort direction
enum SortDirection: String, Codable, CaseIterable {
    case ascending = "Ascending"
    case descending = "Descending"

    var isAscending: Bool { self == .ascending }

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}
