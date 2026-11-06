// MihonBackup.swift - Reads and restores `.tachibk` backups.
//
// `.tachibk` is the format Mihon, Tachiyomi forks, Yokai and Tachimanga write: a
// gzipped protobuf `Backup` message. Field numbers below are theirs; the
// import rules are written up in docs/OFFLINE_LIBRARY.md. Only the manga half
// is read: preferences, extension repos and source preferences belong to
// another app's settings model and are ignored.

import Foundation
import SwiftData

enum MihonBackup {

    /// Decompressed size we are willing to read.
    static let sizeLimit = 256 * 1024 * 1024

    // MARK: - Decoded values

    struct Backup: Sendable {
        var manga: [Manga] = []
        var categories: [Category] = []
        /// Names the backup recorded for the sources it uses, by source id.
        var sourceNames: [Int64: String] = [:]
    }

    struct Category: Sendable {
        var name = ""
        var order = 0
    }

    struct Manga: Sendable {
        var source: Int64 = 0
        var url = ""
        var title = ""
        var artist = ""
        var author = ""
        var description = ""
        var genres: [String] = []
        var status = 0
        var thumbnailURL = ""
        var dateAdded: Int64 = 0
        /// Absent means `true`: Mihon omits the field when it holds its default.
        var favorite = true
        var viewerFlags = 0
        var updateStrategy = 0
        var memo = ""
        /// `Category.order` values of the categories this title belongs to.
        var categoryOrders: [Int64] = []
        var chapters: [Chapter] = []
        var tracks: [Track] = []
        var history: [History] = []
    }

    struct Chapter: Sendable {
        var url = ""
        var name = ""
        var scanlator = ""
        var read = false
        var bookmark = false
        var lastPageRead = 0
        var dateFetch: Int64 = 0
        var dateUpload: Int64 = 0
        var number: Float = -1
        var sourceOrder = 0
        var memo = ""
    }

    struct Track: Sendable {
        var syncId = 0
        var libraryId: Int64 = 0
        var mediaId: Int64 = 0
        var url = ""
        var title = ""
        var lastChapterRead: Float = 0
        var totalChapters = 0
        var score: Float = 0
        var status = 0
        var startedMs: Int64 = 0
        var finishedMs: Int64 = 0
    }

    struct History: Sendable {
        var chapterURL = ""
        var lastReadMs: Int64 = 0
        var durationMs: Int64 = 0
    }

    enum BackupError: LocalizedError {
        case empty
        case noManga
        var errorDescription: String? {
            switch self {
            case .empty: "The backup has no titles in it."
            case .noManga: "The library has no manga titles to export into a .tachibk backup."
            }
        }
    }

    // MARK: - Decoding

    /// Decode a backup file's bytes. Accepts gzipped (the normal case) or raw protobuf.
    static func decode(_ file: Data) throws -> Backup {
        let payload = Gzip.isGzip(file) ? try Gzip.decompress(file, limit: sizeLimit) : file
        var reader = ProtobufReader(payload)
        var backup = Backup()

        while let (field, value) = try reader.next() {
            switch field {
            case 1: if let data = value.message { backup.manga.append(try manga(from: data)) }
            case 2: if let data = value.message { backup.categories.append(try category(from: data)) }
            case 101: if let data = value.message { try source(from: data, into: &backup.sourceNames) }
            default: break
            }
        }
        guard !backup.manga.isEmpty else { throw BackupError.empty }
        return backup
    }

    private static func manga(from data: Data) throws -> Manga {
        var out = Manga()
        var reader = ProtobufReader(data)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: out.source = value.int64 ?? 0
            case 2: out.url = value.string ?? ""
            case 3: out.title = value.string ?? ""
            case 4: out.artist = value.string ?? ""
            case 5: out.author = value.string ?? ""
            case 6: out.description = value.string ?? ""
            case 7: if let genre = value.string { out.genres.append(genre) }
            case 8: out.status = value.int ?? 0
            case 9: out.thumbnailURL = value.string ?? ""
            case 13: out.dateAdded = value.int64 ?? 0
            case 16: if let data = value.message { out.chapters.append(try chapter(from: data)) }
            case 17: out.categoryOrders.append(contentsOf: value.integers)
            case 18: if let data = value.message { out.tracks.append(try track(from: data)) }
            case 100: out.favorite = value.bool ?? true
            case 103: out.viewerFlags = value.int ?? 0
            case 104: if let data = value.message { out.history.append(try history(from: data)) }
            case 105: out.updateStrategy = value.int ?? 0
            case 112: out.memo = value.string ?? ""
            default: break
            }
        }
        return out
    }

    private static func chapter(from data: Data) throws -> Chapter {
        var out = Chapter()
        var reader = ProtobufReader(data)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: out.url = value.string ?? ""
            case 2: out.name = value.string ?? ""
            case 3: out.scanlator = value.string ?? ""
            case 4: out.read = value.bool ?? false
            case 5: out.bookmark = value.bool ?? false
            case 6: out.lastPageRead = value.int ?? 0
            case 7: out.dateFetch = value.int64 ?? 0
            case 8: out.dateUpload = value.int64 ?? 0
            case 9: out.number = value.float ?? -1
            case 10: out.sourceOrder = value.int ?? 0
            case 13: out.memo = value.string ?? ""
            default: break
            }
        }
        return out
    }

    private static func track(from data: Data) throws -> Track {
        var out = Track()
        var reader = ProtobufReader(data)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: out.syncId = value.int ?? 0
            case 2: out.libraryId = value.int64 ?? 0
            case 3: if out.mediaId == 0 { out.mediaId = value.int64 ?? 0 }   // legacy 32-bit id
            case 4: out.url = value.string ?? ""
            case 5: out.title = value.string ?? ""
            case 6: out.lastChapterRead = value.float ?? 0
            case 7: out.totalChapters = value.int ?? 0
            case 8: out.score = value.float ?? 0
            case 9: out.status = value.int ?? 0
            case 10: out.startedMs = value.int64 ?? 0
            case 11: out.finishedMs = value.int64 ?? 0
            case 100: out.mediaId = value.int64 ?? out.mediaId
            default: break
            }
        }
        return out
    }

    private static func history(from data: Data) throws -> History {
        var out = History()
        var reader = ProtobufReader(data)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: out.chapterURL = value.string ?? ""
            case 2: out.lastReadMs = value.int64 ?? 0
            case 3: out.durationMs = value.int64 ?? 0
            default: break
            }
        }
        return out
    }

    private static func category(from data: Data) throws -> Category {
        var out = Category()
        var reader = ProtobufReader(data)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: out.name = value.string ?? ""
            case 2: out.order = value.int ?? 0
            default: break
            }
        }
        return out
    }

    private static func source(from data: Data, into names: inout [Int64: String]) throws {
        var name = ""
        var id: Int64 = 0
        var reader = ProtobufReader(data)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: name = value.string ?? ""
            case 2: id = value.int64 ?? 0
            default: break
            }
        }
        if id != 0 { names[id] = name }
    }

    // MARK: - Encoding

    /// Encodes a `Backup` message to raw protobuf bytes.
    static func encode(_ backup: Backup) -> Data {
        var writer = ProtobufWriter()
        for manga in backup.manga {
            writer.message(1) { m in
                encode(manga, into: &m)
            }
        }
        for category in backup.categories {
            writer.message(2) { c in
                encode(category, into: &c)
            }
        }
        for (id, name) in backup.sourceNames.sorted(by: { $0.key < $1.key }) {
            writer.message(101) { s in
                encodeSource(id: id, name: name, into: &s)
            }
        }
        return writer.bytes
    }

    private static func encode(_ manga: Manga, into writer: inout ProtobufWriter) {
        if manga.source != 0 { writer.int(1, manga.source) }
        writer.string(2, manga.url)
        writer.string(3, manga.title)
        writer.string(4, manga.artist)
        writer.string(5, manga.author)
        writer.string(6, manga.description)
        for genre in manga.genres {
            writer.string(7, genre)
        }
        if manga.status != 0 { writer.int(8, Int64(manga.status)) }
        writer.string(9, manga.thumbnailURL)
        if manga.dateAdded > 0 { writer.int(13, manga.dateAdded) }
        for chapter in manga.chapters {
            writer.message(16) { c in
                encode(chapter, into: &c)
            }
        }
        for order in manga.categoryOrders {
            writer.int(17, order)
        }
        for track in manga.tracks {
            writer.message(18) { t in
                encode(track, into: &t)
            }
        }
        // In Mihon protobuf, favorite defaults to true (field absent).
        // Only emit if explicitly false.
        if !manga.favorite {
            writer.bool(100, false)
        }
        if manga.viewerFlags != 0 { writer.int(103, Int64(manga.viewerFlags)) }
        for history in manga.history {
            writer.message(104) { h in
                encode(history, into: &h)
            }
        }
        if manga.updateStrategy != 0 { writer.int(105, Int64(manga.updateStrategy)) }
        if !manga.memo.isEmpty && manga.memo != "{}" {
            writer.string(112, manga.memo)
        }
    }

    private static func encode(_ chapter: Chapter, into writer: inout ProtobufWriter) {
        writer.string(1, chapter.url)
        writer.string(2, chapter.name)
        writer.string(3, chapter.scanlator)
        if chapter.read { writer.bool(4, true) }
        if chapter.bookmark { writer.bool(5, true) }
        if chapter.lastPageRead > 0 { writer.int(6, Int64(chapter.lastPageRead)) }
        if chapter.dateFetch > 0 { writer.int(7, chapter.dateFetch) }
        if chapter.dateUpload > 0 { writer.int(8, chapter.dateUpload) }
        if chapter.number >= 0 || chapter.number.isFinite {
            writer.float(9, chapter.number)
        }
        if chapter.sourceOrder != 0 { writer.int(10, Int64(chapter.sourceOrder)) }
        if !chapter.memo.isEmpty && chapter.memo != "{}" {
            writer.string(13, chapter.memo)
        }
    }

    private static func encode(_ track: Track, into writer: inout ProtobufWriter) {
        // `syncId` and `libraryId` have no default in Mihon's BackupTracking, so
        // kotlinx.serialization treats them as required: always write both, even at 0.
        writer.int(1, Int64(track.syncId))
        writer.int(2, track.libraryId)
        if track.mediaId != 0 { writer.int(3, track.mediaId) }
        writer.string(4, track.url)
        writer.string(5, track.title)
        if track.lastChapterRead != 0 { writer.float(6, track.lastChapterRead) }
        if track.totalChapters != 0 { writer.int(7, Int64(track.totalChapters)) }
        if track.score != 0 { writer.float(8, track.score) }
        if track.status != 0 { writer.int(9, Int64(track.status)) }
        if track.startedMs > 0 { writer.int(10, track.startedMs) }
        if track.finishedMs > 0 { writer.int(11, track.finishedMs) }
        if track.mediaId != 0 { writer.int(100, track.mediaId) }
    }

    private static func encode(_ history: History, into writer: inout ProtobufWriter) {
        writer.string(1, history.chapterURL)
        if history.lastReadMs > 0 { writer.int(2, history.lastReadMs) }
        if history.durationMs > 0 { writer.int(3, history.durationMs) }
    }

    private static func encode(_ category: Category, into writer: inout ProtobufWriter) {
        writer.string(1, category.name)
        writer.int(2, Int64(category.order))
    }

    private static func encodeSource(id: Int64, name: String, into writer: inout ProtobufWriter) {
        writer.string(1, name)
        writer.int(2, id)
    }

    // MARK: - Export

    /// Snapshot manga entries and categories from `context` into a gzipped `.tachibk` payload.
    ///
    /// Runs on whichever thread calls it with its own `ModelContext` (must be run off the main actor).
    static func export(
        context: ModelContext,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) throws -> Data {
        let allEntries = try context.fetch(FetchDescriptor<Entry>())
        let mangaEntries = allEntries.filter { $0.kind == .manga }
        guard !mangaEntries.isEmpty else { throw BackupError.noManga }

        let categories = try context.fetch(FetchDescriptor<SchemaV2.Category>())
        var backup = Backup()
        backup.categories = categories
            .sorted(by: { $0.order < $1.order })
            .map { Category(name: $0.name, order: $0.order) }

        let total = mangaEntries.count
        for (index, entry) in mangaEntries.enumerated() {
            if Task.isCancelled { break }
            onProgress?(index + 1, total, entry.title)

            let sourceID = NativeSourceIDs.sourceID(for: entry.sourceKey)
            let sourceName = NativeSourceIDs.sourceName(for: entry.sourceKey, id: sourceID)
            backup.sourceNames[sourceID] = sourceName

            var manga = Manga()
            manga.source = sourceID
            manga.url = entry.url
            manga.title = entry.title
            manga.artist = entry.artist ?? ""
            manga.author = entry.author ?? ""
            manga.description = entry.summary ?? ""
            manga.genres = entry.genres
            manga.status = entry.status.rawValue
            manga.thumbnailURL = entry.thumbnailURL ?? ""
            manga.dateAdded = Int64(entry.dateAdded.timeIntervalSince1970 * 1000)
            manga.favorite = entry.inLibrary
            manga.viewerFlags = entry.viewerFlags
            manga.updateStrategy = entry.updateStrategy.rawValue
            manga.memo = entry.memo == "{}" ? "" : entry.memo
            manga.categoryOrders = entry.categories.map { Int64($0.order) }

            // Oldest to newest via ChapterOrder. Mihon numbers sourceOrder 0 for newest,
            // N-1 for oldest.
            let sortedChapters = ChapterOrder.oldestFirst(Array(entry.chapters))
            let chapterCount = sortedChapters.count
            for (idx, ch) in sortedChapters.enumerated() {
                var chapter = Chapter()
                chapter.url = ch.url
                chapter.name = ch.name
                chapter.scanlator = ch.scanlator ?? ""
                chapter.read = ch.read
                chapter.bookmark = ch.bookmark
                chapter.lastPageRead = ch.lastPageRead
                if let df = ch.dateFetch { chapter.dateFetch = Int64(df.timeIntervalSince1970 * 1000) }
                if let du = ch.dateUpload { chapter.dateUpload = Int64(du.timeIntervalSince1970 * 1000) }
                chapter.number = ch.chapterNumber.isFinite ? Float(ch.chapterNumber) : -1
                chapter.sourceOrder = max(0, chapterCount - 1 - idx)
                chapter.memo = ch.memo == "{}" ? "" : ch.memo
                manga.chapters.append(chapter)

                if let hist = ch.history {
                    var h = History()
                    h.chapterURL = ch.url
                    h.lastReadMs = Int64(hist.lastRead.timeIntervalSince1970 * 1000)
                    h.durationMs = Int64(hist.timeRead * 1000)
                    manga.history.append(h)
                }
            }

            for tr in entry.tracks {
                var track = Track()
                track.syncId = tr.syncId
                track.libraryId = tr.libraryId ?? 0
                track.mediaId = tr.remoteId
                track.url = tr.remoteURL
                track.title = tr.title
                track.lastChapterRead = Float(tr.lastChapterRead)
                track.totalChapters = tr.totalChapters
                track.score = Float(tr.score)
                track.status = tr.status
                if let start = tr.startDate { track.startedMs = Int64(start.timeIntervalSince1970 * 1000) }
                if let fin = tr.finishDate { track.finishedMs = Int64(fin.timeIntervalSince1970 * 1000) }
                manga.tracks.append(track)
            }

            backup.manga.append(manga)
        }

        let protobuf = encode(backup)
        return try Gzip.compress(protobuf)
    }

    // MARK: - Summary

    /// What a restore did, for the confirmation and the result message.
    struct Summary: Sendable {
        var added = 0
        var merged = 0
        var chapters = 0
        var categories = 0
        /// Titles whose source has no native port, by source name.
        var unmatchedSources: [String: Int] = [:]
        var skipped = 0
    }

    /// Count titles per source without touching the store, for the preview dialog.
    static func preview(_ backup: Backup) -> (matched: Int, unmatched: [String: Int]) {
        var matched = 0
        var unmatched: [String: Int] = [:]
        for manga in backup.manga {
            if NativeSourceIDs.mihon[manga.source] != nil {
                matched += 1
            } else {
                unmatched[backup.sourceNames[manga.source] ?? "Source \(manga.source)", default: 0] += 1
            }
        }
        return (matched, unmatched)
    }

    // MARK: - Restore

    /// `sourceKey` an imported title is stored under.
    static func sourceKey(forSource id: Int64) -> String {
        if let key = NativeSourceIDs.mihon[id] { return key }
        // No native port: keep the Mihon id so the title is not silently lost.
        return SourceKey.make(kind: .manga, id: String(id))
    }

    /// Merge `backup` into the store behind `container`.
    ///
    /// Runs on whatever thread calls it, with its own `ModelContext`, so call it
    /// off the main actor: a large library is tens of thousands of rows.
    ///
    /// Merge rules, from Mihon's `BackupRestorer` (docs/OFFLINE_LIBRARY.md): categories match by
    /// name, titles by (source, url) and keep their stored details; chapters
    /// match by url with read and bookmark OR-ed and the further page kept;
    /// history keeps the later read; trackers match by service and keep the
    /// higher chapter.
    static func restore(
        _ backup: Backup,
        into container: ModelContainer,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) throws -> Summary {
        var summary = Summary()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // Categories.
        var categories = Dictionary(
            try context.fetch(FetchDescriptor<SchemaV2.Category>()).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        var nextOrder = (categories.values.map(\.order).max() ?? -1) + 1
        var categoryByBackupOrder: [Int64: SchemaV2.Category] = [:]
        for category in backup.categories.sorted(by: { $0.order < $1.order }) {
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let existing = categories[name] {
                categoryByBackupOrder[Int64(category.order)] = existing
            } else {
                let created = SchemaV2.Category(name: name, order: nextOrder)
                nextOrder += 1
                context.insert(created)
                categories[name] = created
                categoryByBackupOrder[Int64(category.order)] = created
                summary.categories += 1
            }
        }

        // Existing titles, indexed once.
        var entries: [String: Entry] = [:]
        for entry in try context.fetch(FetchDescriptor<Entry>()) where entry.kind == .manga {
            entries["\(entry.sourceKey)\u{0}\(entry.url)"] = entry
        }

        for (offset, manga) in backup.manga.enumerated() {
            if Task.isCancelled { break }
            onProgress?(offset + 1, backup.manga.count, manga.title)

            guard !manga.url.isEmpty, !manga.title.isEmpty else {
                summary.skipped += 1
                continue
            }
            let key = sourceKey(forSource: manga.source)
            if NativeSourceIDs.mihon[manga.source] == nil {
                summary.unmatchedSources[backup.sourceNames[manga.source] ?? "Source \(manga.source)", default: 0] += 1
            }

            let entry: Entry
            if let existing = entries["\(key)\u{0}\(manga.url)"] {
                entry = existing
                summary.merged += 1
            } else {
                entry = Entry(kind: .manga, sourceKey: key, url: manga.url, title: manga.title)
                context.insert(entry)
                apply(manga, to: entry)
                entries["\(key)\u{0}\(manga.url)"] = entry
                summary.added += 1
            }
            entry.inLibrary = entry.inLibrary || manga.favorite

            for order in manga.categoryOrders {
                guard let category = categoryByBackupOrder[order],
                      !entry.categories.contains(where: { $0.name == category.name })
                else { continue }
                entry.categories.append(category)
            }

            summary.chapters += mergeChapters(manga, into: entry, context: context)
            mergeTracks(manga.tracks, into: entry, context: context)

            // Keep memory flat on a big library.
            if offset % 25 == 24 { try context.save() }
        }

        try context.save()
        Task { await ChapterVisibility.reconcileAll(container: container) }
        return summary
    }

    private static func apply(_ manga: Manga, to entry: Entry) {
        entry.author = manga.author.isEmpty ? nil : manga.author
        entry.artist = manga.artist.isEmpty ? nil : manga.artist
        entry.summary = manga.description.isEmpty ? nil : manga.description
        entry.genres = manga.genres.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        entry.status = EntryStatus(rawValue: manga.status) ?? .unknown
        entry.thumbnailURL = manga.thumbnailURL.isEmpty ? nil : manga.thumbnailURL
        if manga.dateAdded > 0 { entry.dateAdded = date(manga.dateAdded) }
        entry.viewerFlags = manga.viewerFlags
        entry.updateStrategy = UpdateStrategy(rawValue: manga.updateStrategy) ?? .always
        entry.memo = manga.memo.isEmpty ? "{}" : manga.memo
    }

    private static func mergeChapters(_ manga: Manga, into entry: Entry, context: ModelContext) -> Int {
        var byURL = Dictionary(entry.chapters.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var inserted = 0

        // Mihon numbers `source_order` from the first chapter its source listed,
        // and manga sources list newest first; this app numbers from the oldest.
        // Normalising the imported list here is what stops a restored library
        // from showing chapter 0, 1, 2 at the top with "Newest first" selected.
        let imported = ChapterOrder.normalized(
            manga.chapters
                .filter { !$0.url.isEmpty }
                .sorted { $0.sourceOrder < $1.sourceOrder }
                .map {
                    SourceChapter(
                        url: $0.url,
                        name: $0.name,
                        chapterNumber: $0.number.isFinite ? Double($0.number) : -1,
                        scanlator: $0.scanlator.isEmpty ? nil : $0.scanlator,
                        dateUpload: $0.dateUpload > 0 ? date($0.dateUpload) : nil
                    )
                }
        )
        var order: [String: Int] = [:]
        order.reserveCapacity(imported.count)
        for (index, chapter) in imported.enumerated() { order[chapter.url] = index }

        for item in manga.chapters where !item.url.isEmpty && byURL[item.url] == nil {
            let chapter = SchemaV2.Chapter(
                url: item.url,
                name: item.name,
                chapterNumber: item.number.isFinite ? Double(item.number) : -1,
                sourceOrder: order[item.url] ?? item.sourceOrder)
            context.insert(chapter)
            chapter.entry = entry
            chapter.scanlator = item.scanlator.isEmpty ? nil : item.scanlator
            if item.dateUpload > 0 { chapter.dateUpload = date(item.dateUpload) }
            if item.dateFetch > 0 { chapter.dateFetch = date(item.dateFetch) }
            chapter.memo = item.memo.isEmpty ? "{}" : item.memo
            byURL[item.url] = chapter
            inserted += 1
        }

        var latestRead: Date?
        for item in manga.chapters {
            guard let chapter = byURL[item.url] else { continue }
            chapter.read = chapter.read || item.read
            chapter.bookmark = chapter.bookmark || item.bookmark
            // A finished chapter reads as 100%, as the reader records it.
            if chapter.read { chapter.progress = max(chapter.progress, 100) }
            if item.lastPageRead > chapter.lastPageRead { chapter.lastPageRead = item.lastPageRead }
        }

        for item in manga.history where item.lastReadMs > 0 {
            guard let chapter = byURL[item.chapterURL] else { continue }
            let when = date(item.lastReadMs)
            let seconds = TimeInterval(item.durationMs) / 1000
            if let history = chapter.history {
                history.lastRead = max(history.lastRead, when)
                history.timeRead = max(history.timeRead, seconds)
            } else {
                let history = SchemaV2.History(chapterURL: item.chapterURL, lastRead: when)
                history.timeRead = seconds
                context.insert(history)
                history.chapter = chapter
                chapter.history = history
            }
            latestRead = max(latestRead ?? .distantPast, when)
        }
        if let latestRead { entry.lastReadAt = max(entry.lastReadAt ?? .distantPast, latestRead) }
        return inserted
    }

    private static func mergeTracks(_ tracks: [Track], into entry: Entry, context: ModelContext) {
        for item in tracks {
            if let existing = entry.tracks.first(where: { $0.syncId == item.syncId }) {
                existing.lastChapterRead = max(existing.lastChapterRead, Double(item.lastChapterRead))
                continue
            }
            let track = SchemaV2.Track(syncId: item.syncId, remoteId: item.mediaId, title: item.title)
            context.insert(track)
            track.entry = entry
            track.libraryId = item.libraryId == 0 ? nil : item.libraryId
            track.lastChapterRead = Double(item.lastChapterRead)
            track.totalChapters = item.totalChapters
            track.status = item.status
            track.score = Double(item.score)
            track.remoteURL = item.url
            if item.startedMs > 0 { track.startDate = date(item.startedMs) }
            if item.finishedMs > 0 { track.finishDate = date(item.finishedMs) }
        }
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
