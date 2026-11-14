// LibraryFilter.swift - Tri-state library filters and their per-category store

import Foundation

/// Mihon-style tri-state: ignore the rule, require it, or require its opposite.
enum TriState: String, Codable, Sendable {
    case off
    case include
    case exclude

    /// off → include → exclude → off, the order the filter sheet cycles through.
    var next: TriState {
        switch self {
        case .off: .include
        case .include: .exclude
        case .exclude: .off
        }
    }

    func allows(_ value: Bool) -> Bool {
        switch self {
        case .off: true
        case .include: value
        case .exclude: !value
        }
    }
}

/// Everything a filter needs to know about one entry. Built from
/// `LibraryChapterCounts`, never from the `chapters` relationship.
struct LibraryFilterFacts: Equatable, Sendable {
    var unread = 0
    var total = 0
    var downloaded = 0
    var isCompleted = false
    var isTracked = false

    var hasUnread: Bool { unread > 0 }
    /// At least one chapter has been read.
    var isStarted: Bool { total - unread > 0 }
    var hasDownloads: Bool { downloaded > 0 }
}

struct LibraryFilter: Codable, Equatable, Sendable {
    var downloaded: TriState = .off
    var unread: TriState = .off
    var started: TriState = .off
    var completed: TriState = .off
    var tracked: TriState = .off

    init() {}

    // Decoded field by field so a filter saved before a rule existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloaded = try c.decodeIfPresent(TriState.self, forKey: .downloaded) ?? .off
        unread = try c.decodeIfPresent(TriState.self, forKey: .unread) ?? .off
        started = try c.decodeIfPresent(TriState.self, forKey: .started) ?? .off
        completed = try c.decodeIfPresent(TriState.self, forKey: .completed) ?? .off
        tracked = try c.decodeIfPresent(TriState.self, forKey: .tracked) ?? .off
    }

    var isActive: Bool { activeCount > 0 }

    var activeCount: Int {
        [downloaded, unread, started, completed, tracked].count { $0 != .off }
    }

    /// Whether `matches` needs chapter counts, so the library can skip the
    /// count pass when only cheap rules (or none) are on.
    var needsChapterCounts: Bool {
        downloaded != .off || unread != .off || started != .off
    }

    /// Whether the download rule needs the extra "downloaded" count, which is
    /// a query of its own. Total and unread are always counted.
    var needsDownloads: Bool { downloaded != .off }

    func matches(_ facts: LibraryFilterFacts) -> Bool {
        downloaded.allows(facts.hasDownloads)
            && unread.allows(facts.hasUnread)
            && started.allows(facts.isStarted)
            && completed.allows(facts.isCompleted)
            && tracked.allows(facts.isTracked)
    }
}

/// One `LibraryFilter` per category, persisted as a single JSON value.
/// `nil` is the "All" tab. Categories are keyed by name, which the schema
/// already makes unique.
struct LibraryFilterStore {
    private(set) var filters: [String: LibraryFilter]

    static let allKey = "\u{0}all"

    init(filters: [String: LibraryFilter] = [:]) { self.filters = filters }

    init(json: String) {
        let decoded = try? JSONDecoder().decode([String: LibraryFilter].self, from: Data(json.utf8))
        self.init(filters: decoded ?? [:])
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(filters) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func filter(for category: String?) -> LibraryFilter {
        filters[category ?? Self.allKey] ?? LibraryFilter()
    }

    mutating func set(_ filter: LibraryFilter, for category: String?) {
        // An all-off filter is the default; storing it would only grow the JSON.
        filters[category ?? Self.allKey] = filter.isActive ? filter : nil
    }

    /// Keep a rename (or drop a delete) from orphaning a category's filters.
    /// See `LibraryDisplayStore.rename(from:to:)`.
    mutating func rename(from oldName: String, to newName: String) {
        guard oldName != newName, let filter = filters.removeValue(forKey: oldName) else { return }
        filters[newName] = filter
    }

    mutating func remove(_ name: String) {
        filters[name] = nil
    }
}
