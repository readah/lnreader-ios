// SyncApplyChecks.swift - Drives the "server copy wins" mapping for real.
//
// `SyncApplier.apply` is the only place a restore touches the store, and it is
// the step that can silently do nothing: a payload that decodes but does not
// match an existing entry either creates a duplicate (which the unique
// constraint rejects) or lands nowhere visible. This builds an in-memory
// container and feeds it payloads shaped exactly like `GET /api/sync`.

import Foundation
import SwiftData

@main
@MainActor
struct SyncApplyChecks {

    static func main() throws {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: LNReaderSchemaMigrationPlan.self,
            configurations: ModelConfiguration("SyncApplyChecks", schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        try checkRestoreIntoEmptyStore(context)
        try checkRestoreIsIdempotent(context)
        try checkLocalBookSurvives(context)
        try checkReleaseDateRoundTrip()
        try checkReadingStateAndHighlights(context)
        try checkLocalFiles()

        print("PASS: sync apply — restore into an empty store, idempotent re-apply, "
            + "precise progress, history, manga identity, bookmarks/highlights, chunked EPUB files and covers")
    }

    // MARK: Payloads

    /// The shape the backend actually holds for a native novel: the source id is
    /// the bare plugin id (`novelphoenix`), the path is source-relative, and the
    /// chapters carry `page`/`position` rather than a date.
    private static func novel(
        path: String = "novel/radiant-blade-of-the-wilderness",
        pluginId: String = "novelphoenix",
        title: String = "Radiant Blade of the Wilderness",
        inLibrary: Bool = true,
        chapters: Int = 3
    ) -> SyncNovelPayload {
        SyncNovelPayload(
            path: path,
            pluginId: pluginId,
            name: title,
            cover: "https://novelphoenix.com/server-1/radiant-blade-of-the-wilderness.jpg",
            summary: "A summary.",
            author: "Cuttlefish That Loves Diving",
            artist: nil,
            status: "Ongoing",
            genres: "Eastern, Action",
            inLibrary: inLibrary,
            totalPages: 0,
            chapters: (1...chapters).map { index in
                SyncChapterPayload(
                    path: "\(path)/chapter-\(index)",
                    name: "Chapter \(index): Waking from a Dream",
                    releaseTime: nil,
                    bookmark: false,
                    unread: index > 1,
                    isDownloaded: false,
                    chapterNumber: Double(index),
                    page: "1",
                    position: index - 1,
                    progress: nil,
                    lastReadParagraphIndex: nil
                )
            }
        )
    }

    private static func data(_ novels: [SyncNovelPayload]) -> RemoteSyncData {
        RemoteSyncData(
            profile: SyncProfilePayload(username: "ca5", email: "ca5@example.com", name: "ca5", image: nil),
            library: novels,
            sources: [],
            updatedAt: "2026-10-29T15:05:53.648Z"
        )
    }

    // MARK: Checks

    /// The case that matters: a fresh install with an empty library pulls the
    /// backend's copy and the novels have to show up in it.
    private static func checkRestoreIntoEmptyStore(_ context: ModelContext) throws {
        let startCount = try context.fetch(FetchDescriptor<Entry>()).count
        precondition(startCount == 0, "store should start empty")

        try SyncApplier.apply(data([novel()]), context: context)

        let entries = try context.fetch(FetchDescriptor<Entry>())
        precondition(entries.count == 1, "restore should create exactly one entry, got \(entries.count)")

        let entry = entries[0]
        // The wire says `novelphoenix`; the store keys sources with the prefix, and
        // a mismatch here is what makes a restored novel invisible to its source.
        precondition(entry.sourceKey == "builtin:novelphoenix", "source key was \(entry.sourceKey)")
        precondition(entry.url == "novel/radiant-blade-of-the-wilderness", "url was \(entry.url)")
        precondition(entry.inLibrary, "a restored novel must be in the library or it is invisible")
        precondition(entry.title == "Radiant Blade of the Wilderness", "title was \(entry.title)")
        precondition(entry.status == .ongoing, "status was \(entry.status)")
        precondition(entry.genres == ["Eastern", "Action"], "genres were \(entry.genres)")
        precondition(entry.chapters.count == 3, "chapters were \(entry.chapters.count)")

        let first = entry.chapters.first { $0.url == "novel/radiant-blade-of-the-wilderness/chapter-1" }
        precondition(first != nil, "chapter 1 missing")
        precondition(first?.read == true, "chapter 1 was pushed as read")
        precondition(first?.sourceOrder == 0, "chapter 1 order was \(String(describing: first?.sourceOrder))")
        precondition(first?.chapterNumber == 1, "chapter 1 number was \(String(describing: first?.chapterNumber))")

        let second = entry.chapters.first { $0.url == "novel/radiant-blade-of-the-wilderness/chapter-2" }
        precondition(second?.read == false, "chapter 2 was pushed as unread")
    }

    private static func checkRestoreIsIdempotent(_ context: ModelContext) throws {
        try SyncApplier.apply(data([novel()]), context: context)
        try SyncApplier.apply(data([novel()]), context: context)

        let entries = try context.fetch(FetchDescriptor<Entry>())
        precondition(entries.count == 1, "re-apply duplicated the entry: \(entries.count)")
        precondition(entries[0].chapters.count == 3, "re-apply duplicated chapters: \(entries[0].chapters.count)")
    }

    private static func checkLocalBookSurvives(_ context: ModelContext) throws {
        let local = Entry(kind: .novel, sourceKey: SourceKey.local, url: "local/book.epub", title: "Think Faster")
        local.inLibrary = true
        context.insert(local)
        try context.save()

        try SyncApplier.apply(data([novel()]), context: context)

        let locals = try context.fetch(FetchDescriptor<Entry>()).filter(\.isLocal)
        precondition(locals.count == 1, "restore touched the local book: \(locals.count)")
        precondition(locals[0].title == "Think Faster", "restore renamed the local book")
    }

    private static func checkReadingStateAndHighlights(_ context: ModelContext) throws {
        let source = Entry(kind: .manga, sourceKey: "builtin:mangafire", url: "manga/test", title: "Test manga")
        source.inLibrary = true
        source.lastReadAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = Chapter(url: "test/1", name: "First", chapterNumber: 1, sourceOrder: 0)
        let second = Chapter(url: "test/2", name: "Second", chapterNumber: 2, sourceOrder: 1)
        let hidden = Chapter(url: "test/hidden", name: "Hidden", sourceOrder: 2)
        source.chapters = [first, second, hidden]
        context.insert(source)
        first.read = true
        first.progress = 100
        second.progress = 37.125
        second.paragraphIndex = 123
        second.lastPageRead = 7
        second.pagesLeft = 12
        second.bookmark = true
        hidden.hidden = true
        let history = History(chapterURL: second.url, lastRead: source.lastReadAt!)
        context.insert(history)
        history.chapter = second
        second.history = history
        history.timeRead = 32.75
        let highlight = Highlight(text: "saved selection", color: "yellow", sourceKey: source.sourceKey,
            entryURL: source.url, chapterURL: second.url, chapterName: second.name, chapterNumber: 2,
            sourceOrder: 1, paragraphIndex: 123, startOffset: 5, endOffset: 20, bookTitle: source.title, bookCoverURL: nil)
        context.insert(highlight)
        try context.save()
        let uploaded = SyncNovelPayload(entry: source)
        precondition(uploaded.chapters.count == 2, "hidden chapters must not upload")
        let bytes = try JSONEncoder().encode(uploaded)
        let decoded = try JSONDecoder().decode(SyncNovelPayload.self, from: bytes)
        var remote = data([decoded])
        remote.syncVersion = 2
        remote.highlights = [SyncHighlightPayload(highlight)]
        second.progress = 90
        second.paragraphIndex = 900
        second.bookmark = false
        second.read = true
        history.lastRead = .now
        try SyncApplier.apply(remote, context: context)
        precondition(source.kind == .manga && source.sourceKey == "builtin:mangafire")
        precondition(second.progress == 37.125 && second.paragraphIndex == 123)
        precondition(second.lastPageRead == 7 && second.pagesLeft == 12)
        precondition(second.bookmark && !second.read && first.read)
        precondition(second.history?.timeRead == 32.75 && second.history?.lastRead == source.lastReadAt)
        let restoredHighlights = try context.fetch(FetchDescriptor<Highlight>())
        precondition(restoredHighlights.count == 1)
        try SyncApplier.apply(remote, context: context)
        let repeatedHighlights = try context.fetch(FetchDescriptor<Highlight>())
        precondition(repeatedHighlights.count == 1)
        var reset = decoded
        reset.chapters[1].progress = 0
        reset.chapters[1].lastReadParagraphIndex = nil
        reset.chapters[1].bookmark = false
        reset.chapters[1].lastRead = nil
        var zero = data([reset])
        zero.syncVersion = 2
        zero.highlights = []
        try SyncApplier.apply(zero, context: context)
        precondition(second.progress == 0 && second.paragraphIndex == nil && !second.bookmark && second.history == nil)
        let clearedHighlights = try context.fetch(FetchDescriptor<Highlight>())
        precondition(clearedHighlights.isEmpty)
    }

    private static func checkLocalFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sync-files-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let staging = root.appendingPathComponent("staging")
        let destination = root.appendingPathComponent("destination")
        let id = UUID().uuidString
        var book = novel(path: "local://\(id)", pluginId: "local", chapters: 1)
        book.sourceKey = "local"
        book.cover = "local://Covers/\(id).jpg"
        book.chapters[0].path = "OPS/chapter.xhtml"
        let content = Data(repeating: 42, count: SyncFiles.chunkSize + 73)
        let contents: [String: Data] = [
            "LocalNovels/\(id)/OPS/chapter.xhtml": content,
            "LocalNovels/\(id)/META-INF/container.xml": Data("<container/>".utf8),
            "LocalNovels/\(id)/OPS/book.opf": Data("<package/>".utf8),
            "LocalNovels/\(id)/OPS/style.css": Data(),
            "Covers/\(id).jpg": Data([1, 2, 3, 4]),
        ]
        for (path, bytes) in contents {
            let target = try SyncFiles.fileURL(path, root: original)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        let manifest = try SyncFiles.snapshot([book], root: original)
        precondition(manifest.count == contents.count)
        precondition(manifest.first { $0.path.hasSuffix("chapter.xhtml") }?.chunks.count == 2)
        for file in manifest {
            for index in file.chunks.indices {
                let bytes = try SyncFiles.chunk(file, index: index, root: original)
                try SyncFiles.stage(bytes, file: file, index: index, root: staging)
            }
        }
        try SyncFiles.install(manifest, staging: staging, root: destination)
        for (path, expected) in contents {
            let actual = try Data(contentsOf: SyncFiles.fileURL(path, root: destination))
            precondition(actual == expected, "restored asset differs: \(path)")
        }
        let file = manifest.first { $0.size > 0 }!
        do {
            try SyncFiles.stage(Data("corrupt".utf8), file: file, index: 0, root: staging)
            preconditionFailure("corrupted download accepted")
        } catch {}
        for path in ["../file", "LocalNovels/../escape", "/Covers/escape", "Covers/a\\b"] {
            do {
                _ = try SyncFiles.fileURL(path, root: destination)
                preconditionFailure("unsafe file path accepted")
            } catch {}
        }
        do {
            try SyncFiles.validate([], books: [book])
            preconditionFailure("missing EPUB files accepted")
        } catch {}
    }

    /// Chapter release dates used to be written with `Date.formatted`, which is a
    /// localized string `DateParsing` cannot read back, so every restore silently
    /// dropped them. The wire form is now the same ISO-8601 the rest of the
    /// payload uses.
    private static func checkReleaseDateRoundTrip() throws {
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        let wire = SyncWire.string(from: original)
        precondition(wire == "2023-11-14T22:13:20.000Z", "wire form was \(wire)")

        let parsed = DateParsing.parse(wire)
        precondition(parsed != nil, "DateParsing cannot read back what SyncWire writes")
        precondition(abs(parsed!.timeIntervalSince(original)) < 1, "round trip drifted")

        // A payload written by an older build (localized, no milliseconds) must not
        // break the restore; it degrades to no date rather than a wrong one.
        precondition(SyncWire.date(from: "2023-11-14T22:13:20Z") != nil, "plain ISO must parse")
    }
}
