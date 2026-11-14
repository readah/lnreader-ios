// V2SchemaChecks.swift - Exercises the v2 SwiftData schema for real.
//
// `@Model` mistakes (bad inverses, unsupported unique constraints, cascade
// rules) only surface when a container is built and rows are saved, so this
// check builds an in-memory container and drives it like the app will.

import Foundation
import SwiftData

@main
@MainActor
struct V2SchemaChecks {

    static func main() throws {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: LNReaderSchemaMigrationPlan.self,
            configurations: ModelConfiguration("V3SchemaChecks", schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        try checkLibraryRoundTrip(context)
        try checkChapterState(context)
        try checkCategories(context)
        try checkHistoryCascade(context)
        try checkDownloadQueue(context)
        try checkHighlights(context)
        try checkEntryUniqueConstraint(container)
        try checkMigrationFromV1()
        try checkMigrationFromV2ToV3()

        print("PASS: v3 schema — library round-trip, chapter state, categories, "
            + "history cascade, download queue, highlights, entry uniqueness, "
            + "V1 → V3 and V2 → V3 store migration")
    }

    // MARK: Library

    /// A store written by the V1 schema opens through the plan, keeps its rows and
    /// gives them the new column's default.
    private static func checkMigrationFromV1() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "V2Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "migrate.store")

        do {
            let old = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: file))
            let context = ModelContext(container)
            let entry = SchemaV1.Entry(kind: .manga, sourceKey: "mihon:1", url: "/m", title: "Old")
            context.insert(entry)
            let chapter = SchemaV1.Chapter(url: "c1", name: "Chapter 1", chapterNumber: 1)
            context.insert(chapter)
            chapter.entry = entry
            chapter.read = true
            try context.save()
        }

        let current = Schema(versionedSchema: SchemaV3.self)
        let container = try ModelContainer(
            for: current, migrationPlan: LNReaderSchemaMigrationPlan.self,
            configurations: ModelConfiguration(schema: current, url: file))
        let context = ModelContext(container)
        let chapters = try context.fetch(FetchDescriptor<Chapter>())
        precondition(chapters.count == 1 && chapters[0].read && chapters[0].entry?.title == "Old", "rows survive the migration")
        precondition(!chapters[0].hidden, "migrated rows start visible")
        chapters[0].hidden = true
        try context.save()
        let visible = try context.fetchCount(FetchDescriptor<Chapter>(predicate: #Predicate { !$0.hidden }))
        precondition(visible == 0, "the column is queryable")
        let highlights = try context.fetchCount(FetchDescriptor<Highlight>())
        precondition(highlights == 0, "the new table starts empty")
    }

    /// A V2 store opens through the plan and gains the highlight table without
    /// touching the rows it already has.
    private static func checkMigrationFromV2ToV3() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "V3Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "migrate.store")

        do {
            let old = Schema(versionedSchema: SchemaV2.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: file))
            let context = ModelContext(container)
            let entry = Entry(kind: .novel, sourceKey: "ln:reader", url: "/n", title: "Newer")
            context.insert(entry)
            let chapter = Chapter(url: "c1", name: "Chapter 1", chapterNumber: 1)
            context.insert(chapter)
            chapter.entry = entry
            try context.save()
        }

        let current = Schema(versionedSchema: SchemaV3.self)
        let container = try ModelContainer(
            for: current, migrationPlan: LNReaderSchemaMigrationPlan.self,
            configurations: ModelConfiguration(schema: current, url: file))
        let context = ModelContext(container)
        let entries = try context.fetch(FetchDescriptor<Entry>())
        precondition(entries.count == 1 && entries[0].chapters.count == 1, "V2 rows survive V2 → V3")
        let emptyHighlights = try context.fetchCount(FetchDescriptor<Highlight>())
        precondition(emptyHighlights == 0)

        let highlight = Highlight(
            text: "a line worth keeping", color: "green",
            sourceKey: "ln:reader", entryURL: "/n",
            chapterURL: "c1", chapterName: "Chapter 1", chapterNumber: 1, sourceOrder: 0,
            paragraphIndex: 4, startOffset: 10, endOffset: 31,
            bookTitle: "Newer", bookCoverURL: nil)
        context.insert(highlight)
        try context.save()
        let storedHighlights = try context.fetchCount(FetchDescriptor<Highlight>())
        precondition(storedHighlights == 1)
    }

    // MARK: Highlights

    private static func checkHighlights(_ context: ModelContext) throws {
        let entry = Entry(kind: .novel, sourceKey: "ln:highlight", url: "/book", title: "Highlighted")
        context.insert(entry)
        let chapter = Chapter(url: "/book/1", name: "Chapter 1", chapterNumber: 1)
        context.insert(chapter)
        chapter.entry = entry
        try context.save()

        let first = Highlight(
            text: "The first thing worth remembering",
            color: "pink",
            sourceKey: entry.sourceKey,
            entryURL: entry.url,
            chapterURL: chapter.url,
            chapterName: chapter.name,
            chapterNumber: chapter.chapterNumber,
            sourceOrder: chapter.sourceOrder,
            paragraphIndex: 7, startOffset: 12, endOffset: 44,
            bookTitle: entry.title,
            bookCoverURL: entry.thumbnailURL)
        let second = Highlight(
            text: "and the second", color: "indigo",
            sourceKey: "ln:elsewhere", entryURL: "/other",
            chapterURL: chapter.url, chapterName: chapter.name,
            chapterNumber: chapter.chapterNumber, sourceOrder: chapter.sourceOrder,
            paragraphIndex: 9, startOffset: 0, endOffset: 14,
            bookTitle: "Elsewhere", bookCoverURL: nil)
        context.insert(first)
        context.insert(second)
        try context.save()

        let chapterURL = chapter.url
        let forChapter = try context.fetch(FetchDescriptor<Highlight>(
            predicate: #Predicate { $0.chapterURL == chapterURL },
            sortBy: [SortDescriptor(\.paragraphIndex)]))
        precondition(forChapter.count == 2, "highlights are queryable by chapter")
        precondition(forChapter[0].color == "pink" && forChapter[0].startOffset == 12)
        precondition(forChapter[0].entryKey != forChapter[1].entryKey, "book identity separates sources")

        context.delete(forChapter[1])
        try context.save()
        try expectCount(context, Highlight.self, 1)
    }

    private static func checkLibraryRoundTrip(_ context: ModelContext) throws {
        let entry = Entry(kind: .manga, sourceKey: "mihon:42", url: "/manga/solo", title: "Solo Leveling")
        entry.author = "Chugong"
        entry.genres = ["Action", "Fantasy"]
        entry.status = .completed
        entry.inLibrary = true
        entry.viewerFlags = 3
        entry.updateStrategy = .onlyFetchOnce
        context.insert(entry)

        let chapters = (1...3).map { number -> Chapter in
            let chapter = Chapter(
                url: "/manga/solo/\(number)",
                name: "Chapter \(number)",
                chapterNumber: Double(number),
                sourceOrder: number
            )
            chapter.entry = entry
            context.insert(chapter)
            return chapter
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Entry>())
        precondition(fetched.count == 1)
        let stored = try unwrap(fetched.first)
        precondition(stored.kind == .manga)
        precondition(stored.genres == ["Action", "Fantasy"], "Array properties must round-trip")
        precondition(stored.status == .completed)
        precondition(stored.updateStrategy == .onlyFetchOnce)
        precondition(stored.viewerFlags == 3)
        precondition(stored.chapters.count == 3, "Inverse relationship must be populated")
        precondition(stored.unreadCount == 3)
        precondition(stored.hasUnread)

        // Overrides win over source metadata, without destroying it.
        stored.customTitle = "Solo Leveling (Renamed)"
        precondition(stored.displayTitle == "Solo Leveling (Renamed)")
        precondition(stored.title == "Solo Leveling")
        precondition(stored.displayAuthor == "Chugong")

        let latest = try unwrap(stored.latestChapter)
        precondition(latest.chapterNumber == 3)

        // The chapter-state check expects the first chapter finished.
        chapters[0].read = true
        chapters[0].progress = 100
    }

    // MARK: Chapter state

    private static func checkChapterState(_ context: ModelContext) throws {
        let chapters = try context.fetch(FetchDescriptor<Chapter>(sortBy: [SortDescriptor(\.sourceOrder)]))
        let first = try unwrap(chapters.first)
        precondition(first.read)
        precondition(!first.isInProgress)

        let second = chapters[1]
        second.progress = 40
        second.lastPageRead = 7
        second.pagesLeft = 11
        second.bookmark = true
        try context.save()

        precondition(second.isInProgress)
        precondition(second.progress == 40)
        precondition(second.lastPageRead == 7)
        precondition(second.pagesLeft == 11)
        precondition(second.bookmark)
    }

    // MARK: Categories

    private static func checkCategories(_ context: ModelContext) throws {
        let entry = try unwrap(context.fetch(FetchDescriptor<Entry>()).first)
        let category = SchemaV2.Category(name: "Favourites", order: 1)
        context.insert(category)
        category.entries.append(entry)
        try context.save()

        precondition(entry.categories.count == 1)
        precondition(entry.categories.first?.name == "Favourites")
        precondition(category.entries.count == 1)

        // Removing the entry from the category must not delete either side.
        category.entries.removeAll { $0.url == entry.url }
        try context.save()
        precondition(entry.categories.isEmpty)
        try expectCount(context, Entry.self, 1)
        try expectCount(context, SchemaV2.Category.self, 1)
    }

    // MARK: History

    private static func checkHistoryCascade(_ context: ModelContext) throws {
        let entry = try unwrap(context.fetch(FetchDescriptor<Entry>()).first)
        let chapters = entry.chapters.sorted { $0.sourceOrder < $1.sourceOrder }
        let chapter = chapters[1]

        let history = SchemaV2.History(chapterURL: chapter.url, lastRead: .now)
        history.chapter = chapter
        history.timeRead = 120
        context.insert(history)
        try context.save()

        try expectCount(context, SchemaV2.History.self, 1)
        precondition(chapter.history?.timeRead == 120)

        // Deleting a chapter takes its history row with it.
        context.delete(chapter)
        try context.save()
        try expectCount(context, SchemaV2.History.self, 0)

        // Deleting the entry cascades to the remaining chapters.
        context.delete(entry)
        try context.save()
        try expectCount(context, Entry.self, 0)
        try expectCount(context, Chapter.self, 0)
    }

    // MARK: Downloads

    private static func checkDownloadQueue(_ context: ModelContext) throws {
        let entry = Entry(kind: .novel, sourceKey: "ln:readnovelfull", url: "novel/x", title: "X")
        context.insert(entry)
        let chapter = Chapter(url: "novel/x/1", name: "1", chapterNumber: 1)
        chapter.entry = entry
        context.insert(chapter)

        let item = DownloadItem(chapter: chapter, order: 0)
        item.state = .downloading
        item.progress = 0.25
        context.insert(item)
        try context.save()

        try expectCount(context, DownloadItem.self, 1)
        let stored = try unwrap(context.fetch(FetchDescriptor<DownloadItem>()).first)
        precondition(stored.state == .downloading)
        precondition(stored.chapter?.url == "novel/x/1")
        precondition(!stored.state.isTerminal)

        // Deleting the chapter removes its queue row.
        context.delete(chapter)
        try context.save()
        try expectCount(context, DownloadItem.self, 0)

        context.delete(entry)
        try context.save()
    }

    // MARK: Uniqueness

    private static func checkEntryUniqueConstraint(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        let first = Entry(kind: .novel, sourceKey: "ln:dup", url: "novel/dup", title: "First")
        context.insert(first)
        try context.save()

        let second = Entry(kind: .novel, sourceKey: "ln:dup", url: "novel/dup", title: "Second")
        context.insert(second)
        // SwiftData resolves a unique-constraint clash by merging into the
        // existing row (upsert); either way the store must hold one entry.
        try? context.save()

        let all = try context.fetch(FetchDescriptor<Entry>())
        let matching = all.filter { $0.sourceKey == "ln:dup" && $0.url == "novel/dup" }
        precondition(matching.count == 1, "Duplicate (sourceKey, url) must collapse to one row")

        // A different url under the same source is a distinct entry.
        let other = Entry(kind: .novel, sourceKey: "ln:dup", url: "novel/other", title: "Other")
        context.insert(other)
        try context.save()
        let dupRows = try context.fetch(FetchDescriptor<Entry>()).filter { $0.sourceKey == "ln:dup" }
        precondition(dupRows.count == 2, "Same source, different url must stay separate")
    }

    // MARK: Helpers

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw CheckFailure.missingValue }
        return value
    }

    /// `precondition` takes a non-throwing autoclosure, so counting is a helper.
    private static func expectCount<T: PersistentModel>(
        _ context: ModelContext,
        _ type: T.Type,
        _ expected: Int
    ) throws {
        let actual = try context.fetchCount(FetchDescriptor<T>())
        precondition(actual == expected, "Expected \(expected) \(T.self) rows, found \(actual)")
    }

    private enum CheckFailure: Error {
        case missingValue
    }
}
