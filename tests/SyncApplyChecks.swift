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

        print("PASS: sync apply — restore into an empty store, idempotent re-apply, "
            + "local books untouched, chapter release dates round-trip")
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

    /// A restore runs on every launch, so applying the same payload twice must not
    /// duplicate anything — the unique constraint on (sourceKey, url) would make
    /// the second save throw instead.
    private static func checkRestoreIsIdempotent(_ context: ModelContext) throws {
        try SyncApplier.apply(data([novel()]), context: context)
        try SyncApplier.apply(data([novel()]), context: context)

        let entries = try context.fetch(FetchDescriptor<Entry>())
        precondition(entries.count == 1, "re-apply duplicated the entry: \(entries.count)")
        precondition(entries[0].chapters.count == 3, "re-apply duplicated chapters: \(entries[0].chapters.count)")
    }

    /// Uploaded EPUBs are device-local and never travel through sync. A restore
    /// must leave them alone rather than deleting or resurrecting them.
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
