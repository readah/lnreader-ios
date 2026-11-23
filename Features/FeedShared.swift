// FeedShared.swift
// The rules History and Updates share with their Minimal Mode pages.

import Foundation
import SwiftData

/// Day sections, newest first, for both feeds. A feed folds its items into
/// rows before they are listed — History collapses a run of reads of the same
/// book, Updates keeps each chapter. Undated items trail under "Unknown".
enum DaySections {
    static func of<Item, Row>(
        _ items: [Item],
        date: (Item) -> Date?,
        rows: ([Item]) -> [Row]
    ) -> [(key: String, items: [Row])] {
        let calendar = Calendar.current
        var buckets: [Date: [Item]] = [:]
        var undated: [Item] = []
        for item in items {
            guard let day = date(item) else {
                undated.append(item)
                continue
            }
            buckets[calendar.startOfDay(for: day), default: []].append(item)
        }
        var sections: [(key: String, items: [Row])] = buckets.keys.sorted(by: >).map { day in
            (key: day.daySectionTitle, items: rows(buckets[day] ?? []))
        }
        if !undated.isEmpty {
            sections.append((key: "Unknown", items: rows(undated)))
        }
        return sections
    }
}

/// The feed queries, built once: a page's `init` runs whenever its container
/// rebuilds, and building a `#Predicate` on every pass is not free.
enum FeedQueries {
    /// New chapters, read or not: the feed is what was fetched, so a read
    /// chapter stays visible as read until Clear Updates removes its badge.
    static let updates: FetchDescriptor<Chapter> = {
        var descriptor = FetchDescriptor<Chapter>(
            predicate: #Predicate<Chapter> { $0.dateFetch != nil && !$0.hidden },
            sortBy: [SortDescriptor(\Chapter.dateFetch, order: .reverse)])
        // Grouping and diffing every chapter ever fetched froze the main
        // thread on a large library.
        descriptor.fetchLimit = 300
        return descriptor
    }()

    /// All reading history, for the History tab.
    static let history = historyDescriptor(limit: nil)
    /// The Minimal Mode page mounts lazily and only needs the newest reads.
    static let recentHistory = historyDescriptor(limit: 200)

    private static func historyDescriptor(limit: Int?) -> FetchDescriptor<History> {
        var descriptor = FetchDescriptor<History>(
            sortBy: [SortDescriptor(\History.lastRead, order: .reverse)])
        descriptor.fetchLimit = limit
        return descriptor
    }
}

/// A reference box: writing to it while `body` runs does not invalidate the
/// view. Both feeds hold their last list while the reader covers them.
final class HeldItems<Value> {
    var items: [Value]?
}
