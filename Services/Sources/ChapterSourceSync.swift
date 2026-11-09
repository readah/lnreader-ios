// ChapterSourceSync.swift - Merges a freshly fetched chapter list into an entry.
//
// One implementation for both kinds: the merge only looks at URLs, names and
// numbers, so a manga with 1,200 chapters and a novel with 30 take the same
// path.

import Foundation
import SwiftData

/// What a merge changed, for logging and for deciding whether to save.
struct ChapterSyncResult: Equatable {
    var added = 0
    var updated = 0
    var removed = 0
    /// Of the added chapters, the ones that count as new: not hidden and not a
    /// duplicate of a chapter already read. What Updates and the banner show.
    var fresh = 0

    var isNoOp: Bool { added == 0 && updated == 0 && removed == 0 }
}

enum ChapterSourceSync {

    /// Merge `incoming` into `entry.chapters`.
    ///
    /// Rules:
    /// - Chapters match by URL. The incoming list's order, normalised to
    ///   oldest-first (`ChapterOrder.normalized`), becomes `sourceOrder`.
    /// - A chapter the source no longer lists is deleted **only** when the user
    ///   has no stake in it: unread, unbookmarked and without history. Deleting
    ///   those would throw away reading progress for a chapter the site merely
    ///   renamed or hid, and a re-added chapter would come back unread.
    /// - New chapters are stamped with `dateFetch`, which is what Updates reads.
    ///
    /// - Returns: counts of added, updated and removed chapters.
    @discardableResult
    static func merge(
        _ incoming: [SourceChapter],
        into entry: Entry,
        context: ModelContext,
        removeMissing: Bool = true
    ) -> ChapterSyncResult {
        var result = ChapterSyncResult()

        // One boundary for a source's list: `ChapterOrder` puts it oldest-first,
        // whatever direction the source counted in, so the index written below
        // means the same thing for every source.
        let ordered = ChapterOrder.normalized(incoming)

        // Dedupe the incoming list: sources occasionally repeat a chapter URL,
        // and the first occurrence is the one the source itself lists first.
        var seen = Set<String>()
        var addedChapters: [Chapter] = []
        var unique: [SourceChapter] = []
        unique.reserveCapacity(ordered.count)
        for chapter in ordered where !chapter.url.isEmpty {
            if seen.insert(chapter.url).inserted {
                unique.append(chapter)
            }
        }

        var existingByURL: [String: Chapter] = [:]
        existingByURL.reserveCapacity(entry.chapters.count)
        for chapter in entry.chapters {
            existingByURL[chapter.url] = chapter
        }

        for (index, sourceChapter) in unique.enumerated() {
            if let existing = existingByURL[sourceChapter.url] {
                if update(existing, from: sourceChapter, order: index, entryTitle: entry.title) {
                    result.updated += 1
                }
            } else {
                let chapter = Chapter(
                    url: sourceChapter.url,
                    name: sourceChapter.name,
                    chapterNumber: resolvedNumber(for: sourceChapter, entryTitle: entry.title),
                    sourceOrder: index
                )
                chapter.scanlator = sourceChapter.scanlator
                chapter.dateUpload = sourceChapter.dateUpload
                // Marks the chapter as new; Updates reads this.
                chapter.dateFetch = .now
                chapter.entry = entry
                context.insert(chapter)
                addedChapters.append(chapter)
                result.added += 1
            }
        }

        if removeMissing {
            let incomingURLs = Set(unique.map(\.url))
            for chapter in entry.chapters where !incomingURLs.contains(chapter.url) {
                guard canDiscard(chapter) else { continue }
                context.delete(chapter)
                result.removed += 1
            }
        }

        // Decide what exists (hidden scanlators, merged duplicates), then what
        // is new: a new upload of a chapter the user already read, from another
        // scanlator, is not.
        if !result.isNoOp { ChapterVisibility.reconcile(entry) }
        if result.added > 0 {
            ChapterTwins.reconcile(entry)
            result.fresh = addedChapters.count { !$0.hidden && !$0.read }
        }

        return result
    }

    /// A missing chapter is only safe to drop when nothing depends on it.
    static func canDiscard(_ chapter: Chapter) -> Bool {
        !chapter.read && !chapter.bookmark && chapter.history == nil
    }

    // MARK: - Per-chapter update

    /// - Returns: whether anything actually changed.
    @discardableResult
    private static func update(
        _ chapter: Chapter,
        from source: SourceChapter,
        order: Int,
        entryTitle: String
    ) -> Bool {
        var changed = false

        if chapter.name != source.name {
            chapter.name = source.name
            changed = true
        }
        if chapter.scanlator != source.scanlator {
            chapter.scanlator = source.scanlator
            changed = true
        }
        if chapter.dateUpload != source.dateUpload {
            chapter.dateUpload = source.dateUpload
            changed = true
        }
        if chapter.sourceOrder != order {
            chapter.sourceOrder = order
            changed = true
        }

        // Keep a number the source gave us; fill in or repair a missing one.
        if source.chapterNumber > -1, chapter.chapterNumber != source.chapterNumber {
            chapter.chapterNumber = source.chapterNumber
            changed = true
        } else if chapter.chapterNumber <= -1 {
            let parsed = ChapterRecognition.parseChapterNumber(
                source.name, mangaTitle: entryTitle
            )
            if parsed > -1 {
                chapter.chapterNumber = parsed
                changed = true
            }
        }

        return changed
    }

    private static func resolvedNumber(for chapter: SourceChapter, entryTitle: String) -> Double {
        if chapter.chapterNumber > -1 { return chapter.chapterNumber }
        return ChapterRecognition.parseChapterNumber(chapter.name, mangaTitle: entryTitle)
    }
}

// MARK: - Same chapter, other scanlator

/// Chapters that are the same number from a different scanlator.
///
/// Read state is per row, so reading chapter 5 from one scanlator left the
/// other's chapter 5 unread, and the library badge counted both. Rather than
/// make every count apply the per-entry scanlator rules, a read is copied to
/// the twins, so `!read` stays the only thing anything has to ask.
///
/// Only entries with more than one scanlator are touched: a novel that reuses
/// a number across volumes has a single (or no) scanlator and is left alone.
enum ChapterTwins {

    /// Copy `read` from `chapter` to its twins. Returns the ones that changed.
    @discardableResult
    static func fanOut(from chapter: Chapter, read: Bool) -> [Chapter] {
        guard chapter.chapterNumber > 0, let entry = chapter.entry,
              hasSeveralScanlators(entry.chapters) else { return [] }
        var changed: [Chapter] = []
        for other in entry.chapters
        where other.chapterNumber == chapter.chapterNumber
            && other.url != chapter.url
            && other.read != read {
            other.read = read
            // A copy of a chapter the user has read is not an update.
            if read { other.dateFetch = nil }
            other.progress = read ? 100 : 0
            other.paragraphIndex = read ? 0 : nil
            if !read {
                other.lastPageRead = 0
                other.pagesLeft = 0
            }
            changed.append(other)
        }
        return changed
    }

    /// Make every twin of a read chapter read. For fetched chapters and for
    /// entries read before this existed. Returns how many it changed.
    @discardableResult
    static func reconcile(_ entry: Entry) -> Int {
        let chapters = entry.chapters
        guard hasSeveralScanlators(chapters) else { return 0 }
        let readNumbers = Set(chapters.lazy.filter { $0.read && $0.chapterNumber > 0 }.map(\.chapterNumber))
        guard !readNumbers.isEmpty else { return 0 }
        var count = 0
        for chapter in chapters where !chapter.read && readNumbers.contains(chapter.chapterNumber) {
            chapter.read = true
            chapter.dateFetch = nil
            chapter.progress = 100
            chapter.paragraphIndex = 0
            count += 1
        }
        return count
    }

    private static func hasSeveralScanlators(_ chapters: [Chapter]) -> Bool {
        var first: String?
        for chapter in chapters {
            guard let name = chapter.scanlator, !name.isEmpty else { continue }
            if let first { if first != name { return true } } else { first = name }
        }
        return false
    }
}
