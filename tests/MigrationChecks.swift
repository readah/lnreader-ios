// MigrationChecks.swift - Title matching and progress carry for source migration.

import Foundation
import SwiftData

@main
@MainActor
struct MigrationChecks {

    static func main() async throws {
        checkMatching()
        try checkCarry()
        try await checkPacing()
        try checkSourcePreference()
        print("PASS: migration matching (exact, punctuation, partial, unrelated), "
            + "progress carry (read, bookmark, position, history, unnumbered, no downgrade, "
            + "hidden chapters ignored), pacing (exponential backoff, cap, jitter, "
            + "retry budget, cool-down), and the destination order (sticky per kind, "
            + "empty ignored)")
    }

    private static func checkMatching() {
        precondition(MigrationMatcher.score("Solo Leveling", "solo  leveling!") == 1, "case and punctuation fold")
        precondition(MigrationMatcher.score("Café Days", "Cafe Days") == 1, "accents fold")
        let partial = MigrationMatcher.score("Solo Leveling", "Solo Leveling (Novel)")
        precondition(partial >= MigrationMatcher.autoAcceptScore - 0.2 && partial < 1, "a suffix is close, not exact")
        precondition(MigrationMatcher.score("Solo Leveling", "Solo Max-Level Newbie") < MigrationMatcher.autoAcceptScore)
        precondition(MigrationMatcher.score("Bleach", "Naruto") == 0)
        precondition(MigrationMatcher.score("", "Naruto") == 0)
        precondition(MigrationMatcher.score(["Foo", "Solo Leveling"], "Solo Leveling") == 1, "alt titles count")

        let results = [
            SourceEntry(sourceKey: "b", kind: .manga, url: "/1", title: "Solo Max-Level Newbie"),
            SourceEntry(sourceKey: "b", kind: .manga, url: "/2", title: "Solo Leveling"),
        ]
        precondition(MigrationMatcher.best(for: ["Solo Leveling"], in: results)?.entry.url == "/2")
        precondition(MigrationMatcher.best(for: ["Bleach"], in: results) == nil)
    }

    private static func checkCarry() throws {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration("MigrationChecks", schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let old = Entry(kind: .manga, sourceKey: "mihon:1", url: "/old", title: "Series")
        let new = Entry(kind: .manga, sourceKey: "mihon:2", url: "/new", title: "Series")
        context.insert(old)
        context.insert(new)
        ChapterSourceSync.merge(
            [1, 2, 3, 4].map { SourceChapter(url: "o\(Int($0))", name: "Chapter \(Int($0))", chapterNumber: $0) }
                + [SourceChapter(url: "oe", name: "Epilogue", chapterNumber: -1),
                   SourceChapter(url: "o3b", name: "Chapter 3", chapterNumber: 3, scanlator: "B")],
            into: old, context: context)
        ChapterSourceSync.merge(
            [1, 2, 3, 4, 5].map { SourceChapter(url: "n\(Int($0))", name: "Ch. \(Int($0))", chapterNumber: $0) }
                + [SourceChapter(url: "ne", name: "epilogue!", chapterNumber: -1)],
            into: new, context: context)
        func chapter(_ entry: Entry, _ url: String) -> Chapter {
            guard let found = entry.chapters.first(where: { $0.url == url }) else { fatalError("missing \(url)") }
            return found
        }

        let o1 = chapter(old, "o1"), o2 = chapter(old, "o2"), o3 = chapter(old, "o3")
        o1.read = true
        o1.progress = 100
        o2.bookmark = true
        o3.progress = 40
        o3.lastPageRead = 7
        o3.pagesLeft = 12
        let history = History(chapterURL: "o3", lastRead: Date(timeIntervalSince1970: 1_000))
        history.timeRead = 90
        history.chapter = o3
        context.insert(history)
        chapter(old, "oe").read = true
        // Already read in the new source: carrying must not undo it.
        chapter(new, "n4").read = true
        try context.save()

        let outcome = EntryMigrator.carryProgress(from: old, to: new, context: context)

        let n1 = chapter(new, "n1"), n2 = chapter(new, "n2"), n3 = chapter(new, "n3")
        precondition(n1.read && n1.progress == 100, "read carries by number")
        precondition(n2.bookmark && !n2.read, "bookmark carries without reading")
        precondition(n3.progress == 40 && n3.lastPageRead == 7 && n3.pagesLeft == 12, "position carries")
        precondition(n3.history?.lastRead == Date(timeIntervalSince1970: 1_000) && n3.history?.timeRead == 90,
                     "history carries to the new chapter's url")
        precondition(chapter(new, "ne").read, "unnumbered chapters match by name")
        precondition(chapter(new, "n4").read, "an existing read is kept")
        precondition(!(chapter(new, "n5").read), "chapters beyond the old list stay unread")
        // o1, o2, o3, oe carried; o3b is a twin of o3 with no state.
        precondition(outcome.oldWithState == 4 && outcome.carried == 4 && outcome.missed == 0,
                     "outcome counts: \(outcome)")

        // A source that has fewer chapters reports what it missed.
        let sparse = Entry(kind: .manga, sourceKey: "mihon:3", url: "/sparse", title: "Series")
        context.insert(sparse)
        ChapterSourceSync.merge([SourceChapter(url: "s1", name: "Chapter 1", chapterNumber: 1)],
                                into: sparse, context: context)
        let partial = EntryMigrator.carryProgress(from: old, to: sparse, context: context)
        precondition(partial.carried == 1 && partial.missed == 3, "partial outcome: \(partial)")

        // A hidden chapter does not exist, so it neither counts nor carries.
        let hiddenOld = Entry(kind: .manga, sourceKey: "mihon:4", url: "/hidden-old", title: "Series")
        let hiddenNew = Entry(kind: .manga, sourceKey: "mihon:5", url: "/hidden-new", title: "Series")
        context.insert(hiddenOld)
        context.insert(hiddenNew)
        ChapterSourceSync.merge([SourceChapter(url: "h1", name: "Chapter 1", chapterNumber: 1)],
                                into: hiddenOld, context: context)
        ChapterSourceSync.merge([SourceChapter(url: "k1", name: "Chapter 1", chapterNumber: 1)],
                                into: hiddenNew, context: context)
        let hidden = chapter(hiddenOld, "h1")
        hidden.read = true
        hidden.hidden = true
        let hiddenOutcome = EntryMigrator.carryProgress(from: hiddenOld, to: hiddenNew, context: context)
        precondition(hiddenOutcome.oldWithState == 0, "a hidden chapter is not state to carry")
        precondition(!chapter(hiddenNew, "k1").read, "a hidden chapter carries nothing")
    }

    // MARK: - Pacing

    private static func checkPacing() async throws {
        let backoff = MigrationBackoff(base: 1.5, cap: 20, maxAttempts: 3, rest: 45)
        precondition(backoff.delay(afterAttempt: 1) == 1.5, "first wait is the base")
        precondition(backoff.delay(afterAttempt: 2) == 3, "waits double")
        precondition(backoff.delay(afterAttempt: 3) == 6, "and double again")
        precondition(backoff.delay(afterAttempt: 20) == 20, "never above the cap")
        precondition(backoff.delay(afterAttempt: 3, jitter: 0.5) == 9, "jitter spreads the wait up")
        precondition(backoff.delay(afterAttempt: 3, jitter: -0.5) == 3, "and down")
        precondition(backoff.delay(afterAttempt: 20, jitter: 0.5) == 20, "jitter cannot beat the cap")
        precondition(backoff.delay(afterAttempt: 1, jitter: -4) >= 0, "jitter is clamped")
        precondition(backoff.canRetry(afterAttempt: 1), "two more tries after the first failure")
        precondition(backoff.canRetry(afterAttempt: 2))
        precondition(!backoff.canRetry(afterAttempt: 3), "three tries in total")

        // No sleeping: spacing 0, so the schedule is testable.
        let pacer = MigrationPacer(
            backoff: MigrationBackoff(base: 0, cap: 0, maxAttempts: 3, rest: 60), spacing: 0)
        let fresh = await pacer.isAvailable("a")
        precondition(fresh, "a fresh source is available")

        let first = await pacer.failed("a")
        let second = await pacer.failed("a")
        precondition(first != nil && second != nil, "a failure asks for a wait, twice")
        let third = await pacer.failed("a")
        precondition(third == nil, "the third failure gives up on this entry")
        let restingA = await pacer.isAvailable("a")
        let freeB = await pacer.isAvailable("b")
        precondition(!restingA, "and rests the source")
        precondition(freeB, "another source is unaffected")

        await pacer.succeeded("a")
        let revived = await pacer.isAvailable("a")
        precondition(revived, "an answer clears the cool-down")
        let afterRevival = await pacer.failed("a")
        precondition(afterRevival != nil, "and the budget starts over")

        await pacer.reset()
        let afterReset = await pacer.isAvailable("a")
        precondition(afterReset, "reset forgets the cool-down")
    }

    // MARK: - Destination order

    private static func checkSourcePreference() throws {
        let suite = "MigrationChecks.preference"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not open a defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)

        precondition(MigrationSourcePreference.load(for: .manga, defaults: defaults) == nil,
                     "nothing chosen yet means every source")

        // Unticking sources sticks: the shortened order is what the next
        // migration of the same kind reads back.
        MigrationSourcePreference.save(["mihon:a", "mihon:c"], for: .manga, defaults: defaults)
        precondition(MigrationSourcePreference.load(for: .manga, defaults: defaults)
            == ["mihon:a", "mihon:c"], "the unticked source stays out")

        // Order is part of the preference, not just membership.
        MigrationSourcePreference.save(["mihon:c", "mihon:a"], for: .manga, defaults: defaults)
        precondition(MigrationSourcePreference.load(for: .manga, defaults: defaults)
            == ["mihon:c", "mihon:a"], "the order is kept")

        // Kinds do not share a choice.
        precondition(MigrationSourcePreference.load(for: .novel, defaults: defaults) == nil,
                     "manga choices do not leak into novels")
        MigrationSourcePreference.save(["ln:one"], for: .novel, defaults: defaults)
        precondition(MigrationSourcePreference.load(for: .manga, defaults: defaults)
            == ["mihon:c", "mihon:a"], "novel choices do not overwrite manga")

        // Unticking everything is not a preference: it must not leave the next
        // migration with nothing to search.
        MigrationSourcePreference.save([], for: .novel, defaults: defaults)
        precondition(MigrationSourcePreference.load(for: .novel, defaults: defaults) == ["ln:one"],
                     "an empty list is ignored, not stored")

        defaults.removePersistentDomain(forName: suite)
    }
}
