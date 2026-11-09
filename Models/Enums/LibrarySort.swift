// LibrarySort.swift - Per-category library sort and the rule that applies it

import Foundation

/// A sort order with its direction. "Ascending" means smallest first: A to Z,
/// oldest first, fewest first.
struct LibrarySort: Codable, Equatable, Sendable {
    var order: SortOrder
    var direction: SortDirection
    /// Entries with nothing to rank (0 unread, no upload date, never read) go
    /// to the end whichever way the sort runs. Without it, "fewest unread
    /// first" lists every finished title before the first one worth opening.
    var emptyLast: Bool

    init(order: SortOrder, direction: SortDirection? = nil, emptyLast: Bool = false) {
        self.order = order
        self.direction = direction ?? order.defaultDirection
        self.emptyLast = emptyLast
    }

    // Decoded field by field so a sort saved before an order existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent(SortOrder.self, forKey: .order) ?? .lastRead
        direction = try c.decodeIfPresent(SortDirection.self, forKey: .direction) ?? order.defaultDirection
        emptyLast = try c.decodeIfPresent(Bool.self, forKey: .emptyLast) ?? false
    }

    /// The menu's rule: the current order flips direction, another order
    /// starts in its natural direction.
    mutating func select(_ newOrder: SortOrder) {
        if order == newOrder {
            direction.toggle()
        } else {
            // Count-based orders start with empty entries last: that is the
            // useful reading of them in either direction.
            self = LibrarySort(order: newOrder, emptyLast: newOrder.needsChapterCounts)
        }
    }

    /// Whether `LibrarySorter` reads chapter counts for this order.
    var needsChapterCounts: Bool { order.needsChapterCounts }
    /// Whether it also reads the latest upload / fetch dates.
    var needsChapterDates: Bool { order.needsChapterDates }
}

extension SortOrder {
    /// Alphabetical and manual order read naturally first-to-last; everything
    /// else is about "most" or "newest", which people want on top.
    var defaultDirection: SortDirection {
        switch self {
        case .alphabetical, .custom: .ascending
        default: .descending
        }
    }

    var needsChapterCounts: Bool {
        switch self {
        case .unread, .totalChapters, .latestChapter, .chapterFetched: true
        default: false
        }
    }

    var needsChapterDates: Bool { self == .latestChapter || self == .chapterFetched }

    /// Whether "empty" means something for this order. Names, manual order and
    /// date added always have a value.
    var supportsEmptyLast: Bool {
        switch self {
        case .custom, .alphabetical, .dateAdded: false
        default: true
        }
    }

    /// The two directions in words the order's own terms, instead of a bare arrow.
    var directionLabels: (ascending: String, descending: String) {
        switch self {
        case .alphabetical: ("A to Z", "Z to A")
        case .totalChapters, .unread: ("Fewest first", "Most first")
        case .custom: ("First to last", "Last to first")
        default: ("Oldest first", "Newest first")
        }
    }
}

/// Everything a sort needs to know about one entry. Built from `Entry`
/// columns and `LibraryChapterCounts`, never from the `chapters` relationship.
struct LibrarySortFacts: Equatable, Sendable {
    var title = ""
    var libraryOrder = 0
    var dateAdded = Date.distantPast
    var lastReadAt: Date?
    /// When the entry was last refreshed from its source.
    var lastChecked: Date?
    var total = 0
    var unread = 0
    /// Newest `dateUpload` among the chapters.
    var latestUpload: Date?
    /// Newest `dateFetch` among chapters whose update has not been dismissed.
    var latestFetch: Date?

    /// Whether this entry has nothing to rank by under `order`.
    func isEmpty(for order: SortOrder) -> Bool {
        switch order {
        case .totalChapters: total == 0
        case .unread: unread == 0
        case .lastRead: lastReadAt == nil
        case .lastUpdated: lastChecked == nil
        case .latestChapter: latestUpload == nil
        case .chapterFetched: latestFetch == nil
        case .custom, .alphabetical, .dateAdded: false
        }
    }
}

enum LibrarySorter {
    /// `items` in the order `sort` asks for. Ties fall back to the title so the
    /// grid does not shuffle between refreshes.
    static func sorted<T>(_ items: [T], by sort: LibrarySort, facts: (T) -> LibrarySortFacts) -> [T] {
        let keyed = items.map { (item: $0, facts: facts($0)) }
        let ascending = sort.direction.isAscending

        let ordered = keyed.sorted { lhs, rhs in
            let l = lhs.facts, r = rhs.facts
            if sort.emptyLast, sort.order.supportsEmptyLast {
                let lEmpty = l.isEmpty(for: sort.order), rEmpty = r.isEmpty(for: sort.order)
                if lEmpty != rEmpty { return rEmpty }
            }
            let result = compare(l, r, order: sort.order)
            if result != .orderedSame { return ascending ? result == .orderedAscending : result == .orderedDescending }
            return titleOrder(l.title, r.title) == .orderedAscending
        }
        return ordered.map(\.item)
    }

    private static func compare(_ l: LibrarySortFacts, _ r: LibrarySortFacts, order: SortOrder) -> ComparisonResult {
        switch order {
        case .custom: compare(l.libraryOrder, r.libraryOrder)
        case .alphabetical: titleOrder(l.title, r.title)
        case .lastRead: compare(l.lastReadAt, r.lastReadAt)
        case .lastUpdated: compare(l.lastChecked, r.lastChecked)
        case .totalChapters: compare(l.total, r.total)
        case .unread: compare(l.unread, r.unread)
        case .dateAdded: compare(l.dateAdded, r.dateAdded)
        case .latestChapter: compare(l.latestUpload, r.latestUpload)
        case .chapterFetched: compare(l.latestFetch, r.latestFetch)
        }
    }

    private static func titleOrder(_ a: String, _ b: String) -> ComparisonResult {
        a.localizedStandardCompare(b)
    }

    private static func compare<V: Comparable>(_ a: V, _ b: V) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// A missing date is the oldest possible one, so those entries sink in a
    /// "newest first" sort instead of floating to the top.
    private static func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        compare(a ?? .distantPast, b ?? .distantPast)
    }
}

/// One `LibrarySort` per category, persisted as a single JSON value. `nil` is
/// the "All" tab. A category with no entry follows the global default.
struct LibrarySortStore {
    private(set) var sorts: [String: LibrarySort]

    static let allKey = LibraryFilterStore.allKey

    init(sorts: [String: LibrarySort] = [:]) { self.sorts = sorts }

    init(json: String) {
        let decoded = try? JSONDecoder().decode([String: LibrarySort].self, from: Data(json.utf8))
        self.init(sorts: decoded ?? [:])
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(sorts) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func sort(for category: String?, default fallback: LibrarySort) -> LibrarySort {
        sorts[category ?? Self.allKey] ?? fallback
    }

    func hasOverride(for category: String?) -> Bool {
        sorts[category ?? Self.allKey] != nil
    }

    mutating func set(_ sort: LibrarySort, for category: String?) {
        sorts[category ?? Self.allKey] = sort
    }

    mutating func reset(_ category: String?) {
        sorts[category ?? Self.allKey] = nil
    }

    /// Keep a rename (or drop a delete) from orphaning a category's sort.
    /// See `LibraryDisplayStore.rename(from:to:)`.
    mutating func rename(from oldName: String, to newName: String) {
        guard oldName != newName, let sort = sorts.removeValue(forKey: oldName) else { return }
        sorts[newName] = sort
    }

    mutating func remove(_ name: String) {
        sorts[name] = nil
    }
}
