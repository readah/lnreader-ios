// ChapterOrder.swift - The one place that decides chapter order.
//
// Every surface that lists, navigates or queues chapters asks this file: the
// detail screen, the directory, both readers' chapter sheets, sync upload,
// scanlator merging and the download queue. Before it, nine call sites each had
// their own `.sorted { $0.sourceOrder < $1.sourceOrder }` and they disagreed
// about which end of `sourceOrder` was newest — which is how a list could show
// chapter 0, 1, 2 at the top while the menu said "Newest first".
//
// Two words, used the same way everywhere:
//
//   oldestFirst   reading order, chapter 1 -> N. What previous/next walk.
//   newestFirst   what the chapter list shows by default, N -> 1.
//
// One invariant makes that possible, and it is enforced in one place:
//
//   `sourceOrder` 0 is the OLDEST chapter.
//
// A source is free to list newest-first (MangaFire does); `normalized(_:)`
// reverses it once, when the list arrives, so the index that gets stored always
// counts from the oldest. Nothing downstream has to ask which way a source
// counted, and a refresh re-stamps `sourceOrder` for entries stored before this
// rule existed.
//
// `sourceOrder` stays the key — not the number, not the date — because a source
// that fixes a chapter's name or renumbers it keeps its place in the list, and
// because a novel with no numbers in its titles still has an order.

import Foundation

/// Anything that carries its position in the source's chapter list.
///
/// `Chapter` (stored) and `ChapterDisplay` (a row) conform. A source's
/// `[SourceChapter]` has no index of its own — its position *is* the array — so
/// it goes through `normalized` first and becomes one of these.
protocol ChapterOrdered {
    /// Position in the source's list, `0` = oldest.
    var orderIndex: Int { get }
    /// Stable tie-break, so two rows with the same index never swap between
    /// passes. A chapter's URL is unique within an entry.
    var orderIdentity: String { get }
}

extension Chapter: ChapterOrdered {
    var orderIndex: Int { sourceOrder }
    var orderIdentity: String { url }
}

// `ChapterDisplay` conforms next to its definition in `ChapterListView.swift`,
// so this file stays free of SwiftUI and the headless checks can compile it.

enum ChapterOrder {

    /// The user's order setting. One key, read by every surface, so the menu and
    /// the list cannot disagree: `false` = newest first.
    static let ascendingKey = "chapters.ascending"

    // MARK: - Stored order

    /// Reading order: chapter 1 to N.
    static func oldestFirst<T: ChapterOrdered>(_ items: [T]) -> [T] {
        items.sorted { lhs, rhs in
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
            return lhs.orderIdentity < rhs.orderIdentity
        }
    }

    /// Display order: newest chapter to oldest. The chapter list's default.
    static func newestFirst<T: ChapterOrdered>(_ items: [T]) -> [T] {
        items.sorted { lhs, rhs in
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex > rhs.orderIndex }
            return lhs.orderIdentity < rhs.orderIdentity
        }
    }

    /// What a list should show, given the user's setting. The only place the
    /// setting is applied to a list.
    static func display<T: ChapterOrdered>(_ items: [T], ascending: Bool) -> [T] {
        ascending ? oldestFirst(items) : newestFirst(items)
    }

    /// Resume an unfinished last-opened chapter; otherwise advance past the
    /// latest read chapter, then fall back to an unread chapter or the newest.
    /// Callers pass only visible chapters, in reading order.
    static func resume<T: ChapterOrdered>(
        oldestFirst: [T],
        lastOpenedPath: String?,
        isUnread: (T) -> Bool
    ) -> T? {
        if let lastOpenedPath,
           let lastOpened = oldestFirst.first(where: { $0.orderIdentity == lastOpenedPath }),
           isUnread(lastOpened) {
            return lastOpened
        }
        if let latestRead = oldestFirst.lastIndex(where: { !isUnread($0) }),
           let next = oldestFirst[latestRead...].first(where: isUnread) {
            return next
        }
        return oldestFirst.first(where: isUnread) ?? oldestFirst.last
    }

    // MARK: - The boundary

    /// Put an incoming source list in the one order the app stores.
    ///
    /// `CatalogSource.chapters` asks for oldest-first, and most sources do that
    /// because that is how the site paginates. The ones that hand back
    /// newest-first are reversed here rather than in every source: chapter
    /// numbers decide first, release dates when the numbers are unusable, and
    /// with neither the list is trusted as given.
    ///
    /// Reversing changes nothing but the order — the same chapters, the same
    /// URLs — so a source cannot lose a chapter to this.
    static func normalized(_ incoming: [SourceChapter]) -> [SourceChapter] {
        guard incoming.count > 1 else { return incoming }

        let numbered = incoming.filter { $0.chapterNumber >= 0 }
        let dated = incoming.filter { $0.dateUpload != nil }

        let newestFirst = descending(numbered, by: { $0.chapterNumber })
            ?? descending(dated, by: { $0.dateUpload?.timeIntervalSince1970 ?? 0 })
            ?? false

        return newestFirst ? Array(incoming.reversed()) : incoming
    }

    /// Whether `items` mostly counts down. `nil` when it does not say — fewer
    /// than two usable values, or as many steps up as down.
    ///
    /// Counting adjacent pairs instead of comparing the ends keeps one stray
    /// chapter (a bonus chapter numbered 0, a pinned announcement) from
    /// flipping the whole list.
    private static func descending<T>(_ items: [T], by value: (T) -> Double) -> Bool? {
        guard items.count > 1 else { return nil }
        var rising = 0
        var falling = 0
        var previous = value(items[0])
        for item in items.dropFirst() {
            let current = value(item)
            if current > previous { rising += 1 } else if current < previous { falling += 1 }
            previous = current
        }
        guard rising != falling else { return nil }
        return falling > rising
    }
}
