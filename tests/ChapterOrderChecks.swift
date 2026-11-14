// ChapterOrderChecks.swift - The chapter order rule, on its own.
//
// Every case here is a shape a real source has handed this app: a list that
// counts up, one that counts down (MangaFire), one with a stray bonus chapter,
// one with no numbers at all, and one where the only signal is a date.

import Foundation

@main
struct ChapterOrderChecks {

    static func main() {
        checkStoredOrder()
        checkDisplayOrder()
        checkResumeChapter()
        checkNormalizesAnOldestFirstList()
        checkNormalizesANewestFirstList()
        checkAStrayChapterDoesNotFlipTheList()
        checkFallsBackToDates()
        checkTrustsAListWithNoSignal()
        checkDegenerateLists()
        print("PASS: chapter order (sourceOrder invariant, newest-first display, "
            + "resume selection, normalising oldest/newest-first sources, stray chapters, "
            + "date fallback, no-signal lists, empty and single-chapter lists)")
    }

    // MARK: - Stored order

    private static func chapters(_ indices: [Int]) -> [Chapter] {
        indices.map { Chapter(url: "ch/\($0)", name: "Chapter \($0 + 1)", chapterNumber: Double($0 + 1), sourceOrder: $0) }
    }

    private static func checkStoredOrder() {
        let rows = chapters([2, 0, 3, 1])

        precondition(
            ChapterOrder.oldestFirst(rows).map(\.sourceOrder) == [0, 1, 2, 3],
            "oldest first is ascending sourceOrder"
        )
        precondition(
            ChapterOrder.newestFirst(rows).map(\.sourceOrder) == [3, 2, 1, 0],
            "newest first is descending sourceOrder"
        )
        // The input order must not matter: a relationship hands back whatever.
        precondition(
            ChapterOrder.newestFirst(Array(rows.reversed())).map(\.sourceOrder) == [3, 2, 1, 0],
            "the order the rows arrive in is irrelevant"
        )
        // Two rows with the same index still sort the same way twice.
        let twins = [
            Chapter(url: "b", name: "B", chapterNumber: 1, sourceOrder: 0),
            Chapter(url: "a", name: "A", chapterNumber: 1, sourceOrder: 0),
        ]
        precondition(
            ChapterOrder.oldestFirst(twins).map(\.url) == ["a", "b"],
            "equal indices break by url, so a pass cannot reshuffle them"
        )
        precondition(
            ChapterOrder.newestFirst(twins).map(\.url) == ["a", "b"],
            "the tie-break does not flip with the direction"
        )
    }

    private static func checkDisplayOrder() {
        let rows = chapters([1, 0, 2])
        precondition(ChapterOrder.display(rows, ascending: false).map(\.sourceOrder) == [2, 1, 0])
        precondition(ChapterOrder.display(rows, ascending: true).map(\.sourceOrder) == [0, 1, 2])
    }

    private static func checkResumeChapter() {
        let rows = chapters([0, 1, 2, 3])
        // Nothing read yet -> first chapter.
        precondition(ChapterOrder.resume(oldestFirst: rows, lastOpenedPath: nil, isUnread: { !$0.read })?.url == "ch/0")

        // Last opened chapter is still unread -> reopen it even if earlier ones are unread.
        rows[0].read = true
        precondition(ChapterOrder.resume(oldestFirst: rows, lastOpenedPath: "ch/2", isUnread: { !$0.read })?.url == "ch/2")

        // Last opened chapter was finished -> advance to the first unread after the latest read.
        rows[2].read = true
        precondition(ChapterOrder.resume(oldestFirst: rows, lastOpenedPath: "ch/2", isUnread: { !$0.read })?.url == "ch/3")

        // Latest read is the last chapter -> fall back to the earliest unread chapter.
        rows[3].read = true
        precondition(ChapterOrder.resume(oldestFirst: rows, lastOpenedPath: "ch/3", isUnread: { !$0.read })?.url == "ch/1")

        // All chapters read -> newest chapter.
        rows[1].read = true
        precondition(ChapterOrder.resume(oldestFirst: rows, lastOpenedPath: "ch/1", isUnread: { !$0.read })?.url == "ch/3")

        // Last opened path is missing (e.g. hidden by scanlator rules) -> ignored.
        rows[1].read = false
        precondition(ChapterOrder.resume(oldestFirst: rows, lastOpenedPath: "ch/hidden", isUnread: { !$0.read })?.url == "ch/1")

        // Empty list -> nil.
        precondition(ChapterOrder.resume(oldestFirst: [Chapter](), lastOpenedPath: nil, isUnread: { !$0.read }) == nil)
    }

    // MARK: - The boundary

    private static func source(_ numbers: [Double]) -> [SourceChapter] {
        numbers.enumerated().map {
            SourceChapter(url: "ch/\($0.offset)", name: "Chapter \($0.element)", chapterNumber: $0.element)
        }
    }

    private static func checkNormalizesAnOldestFirstList() {
        let list = source([1, 2, 3, 4])
        let normalized = ChapterOrder.normalized(list)
        precondition(normalized.map(\.chapterNumber) == [1, 2, 3, 4], "an oldest-first list is left alone")
        precondition(normalized.map(\.url) == list.map(\.url), "and keeps its order")
    }

    private static func checkNormalizesANewestFirstList() {
        // What MangaFire hands back.
        let list = source([4, 3, 2, 1])
        let normalized = ChapterOrder.normalized(list)
        precondition(normalized.map(\.chapterNumber) == [1, 2, 3, 4], "a newest-first list is reversed once")
        precondition(normalized.first?.url == "ch/3", "the oldest chapter is now first")
        // Reversing is its own inverse, so a second pass changes nothing.
        precondition(
            ChapterOrder.normalized(normalized).map(\.url) == normalized.map(\.url),
            "normalising twice is normalising once"
        )
    }

    private static func checkAStrayChapterDoesNotFlipTheList() {
        // A bonus chapter numbered 0 pinned to the top of an otherwise
        // newest-first list, and an announcement with no number at all.
        let list = [
            SourceChapter(url: "extra", name: "Announcement", chapterNumber: -1),
            SourceChapter(url: "bonus", name: "Bonus", chapterNumber: 0),
            SourceChapter(url: "c5", name: "Chapter 5", chapterNumber: 5),
            SourceChapter(url: "c4", name: "Chapter 4", chapterNumber: 4),
            SourceChapter(url: "c3", name: "Chapter 3", chapterNumber: 3),
            SourceChapter(url: "c2", name: "Chapter 2", chapterNumber: 2),
        ]
        let normalized = ChapterOrder.normalized(list)
        precondition(
            normalized.map(\.url) == ["c2", "c3", "c4", "c5", "bonus", "extra"],
            "the numbered run decides the direction; the stray rows follow it"
        )
    }

    private static func checkFallsBackToDates() {
        // No usable numbers: the dates are the only signal.
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let list = (0..<4).reversed().map { index in
            SourceChapter(
                url: "ch/\(index)",
                name: "Part \(index + 1)",
                chapterNumber: -1,
                dateUpload: start.addingTimeInterval(Double(index) * day)
            )
        }
        let normalized = ChapterOrder.normalized(list)
        precondition(
            normalized.map(\.url) == ["ch/0", "ch/1", "ch/2", "ch/3"],
            "dates decide when the numbers are unusable"
        )
    }

    private static func checkTrustsAListWithNoSignal() {
        // No numbers, no dates: there is nothing to measure, so the source's
        // order is the order. Reversing on a guess would be worse than trusting.
        let list = ["a", "b", "c"].map { SourceChapter(url: $0, name: $0) }
        precondition(
            ChapterOrder.normalized(list).map(\.url) == ["a", "b", "c"],
            "a list with no signal is trusted as given"
        )
    }

    private static func checkDegenerateLists() {
        precondition(ChapterOrder.normalized([]).isEmpty)
        precondition(ChapterOrder.oldestFirst([Chapter]()).isEmpty)
        precondition(ChapterOrder.newestFirst([Chapter]()).isEmpty)
        let one = source([1])
        precondition(ChapterOrder.normalized(one).map(\.url) == ["ch/0"], "one chapter is its own order")
    }
}
