// MihonBackupChecks.swift - Decodes and restores `.tachibk` backups.
//
// Backups are built here with a tiny protobuf writer, gzipped, and pushed
// through the same decode -> restore path the app uses, into an in-memory
// SwiftData store. Set TACHIBK_SAMPLE to also run a real export.

import Compression
import Foundation
import SwiftData

// MARK: - Protobuf writer (test only)

private struct Writer {
    var bytes = Data()

    private mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 { bytes.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        bytes.append(UInt8(v))
    }
    private mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    mutating func int(_ field: Int, _ value: Int64) { key(field, 0); varint(UInt64(bitPattern: value)) }
    mutating func bool(_ field: Int, _ value: Bool) { int(field, value ? 1 : 0) }
    mutating func float(_ field: Int, _ value: Float) {
        key(field, 5)
        var bits = value.bitPattern.littleEndian
        bytes.append(Data(bytes: &bits, count: 4))
    }
    mutating func string(_ field: Int, _ value: String) { message(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ data: Data) {
        key(field, 2); varint(UInt64(data.count)); bytes.append(data)
    }
    mutating func message(_ field: Int, _ build: (inout Writer) -> Void) {
        var inner = Writer(); build(&inner); message(field, inner.bytes)
    }
}

private func gzip(_ payload: Data) -> Data {
    var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
    let capacity = payload.count + payload.count / 10 + 1024
    var buffer = [UInt8](repeating: 0, count: capacity)
    let size = payload.withUnsafeBytes { source in
        compression_encode_buffer(&buffer, capacity,
                                  source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                  nil, COMPRESSION_ZLIB)
    }
    out.append(contentsOf: buffer[0..<size])
    out.append(Data(count: 4))                                  // CRC32, not verified by the reader
    var length = UInt32(truncatingIfNeeded: payload.count).littleEndian
    out.append(Data(bytes: &length, count: 4))
    return out
}

// MARK: - Fixtures

private let mangaFireID: Int64 = 6_084_907_896_154_116_083
private let allMangaID: Int64 = 4_709_139_914_729_853_090
private let unknownID: Int64 = 1_234_567

private func sampleBackup() -> Data {
    var backup = Writer()

    backup.message(1) { m in
        m.int(1, mangaFireID)
        m.string(2, "/manga/overgeared.728q1")
        m.string(3, "Overgeared")
        m.string(4, "Park Saenal")
        m.string(5, "Park Saenal, Rhyuji")
        m.string(6, "A man gets a very strong smithing skill.")
        m.string(7, "Action"); m.string(7, "Fantasy")
        m.int(8, 1)
        m.string(9, "https://example.com/cover.jpg")
        m.int(13, 1_751_994_025_000)
        m.int(17, 3)                                             // category with order 3
        m.string(112, #"{"slug":"overgeared"}"#)
        for number in 1...3 {
            m.message(16) { c in
                c.string(1, "/manga/overgeared.728q1/\(1000 + number)-chapter-\(number)-en")
                c.string(2, "Chapter \(number)")
                c.string(3, number == 2 ? "official" : "")
                c.bool(4, number == 1)                           // chapter 1 read
                c.bool(5, number == 3)                           // chapter 3 bookmarked
                c.int(6, number == 2 ? 7 : 0)                    // chapter 2 stopped on page 7
                c.int(7, 1_700_000_000_000)
                c.int(8, 1_690_000_000_000)
                c.float(9, Float(number))
                c.int(10, Int64(3 - number))
                c.string(13, "{}")
            }
        }
        m.message(18) { t in
            t.int(1, 2); t.int(2, 4455); t.string(4, "https://anilist.co/manga/1")
            t.string(5, "Overgeared"); t.float(6, 41); t.int(7, 100); t.float(8, 8.5)
            t.int(9, 1); t.int(10, 1_686_951_957_686); t.int(100, 98765)
        }
        m.message(104) { h in
            h.string(1, "/manga/overgeared.728q1/1001-chapter-1-en")
            h.int(2, 1_792_589_426_000); h.int(3, 120_000)
        }
    }

    backup.message(1) { m in                                     // not favourited, unknown source
        m.int(1, unknownID)
        m.string(2, "/m/orphan")
        m.string(3, "Orphan")
        m.bool(100, false)
        m.message(16) { c in
            c.string(1, "/m/orphan/1"); c.string(2, "One"); c.float(9, 1)
        }
    }

    backup.message(2) { c in c.string(1, "stash"); c.int(2, 4) }
    backup.message(2) { c in c.string(1, "hiatus"); c.int(2, 3) }
    backup.message(101) { s in s.string(1, "MangaFire"); s.int(2, mangaFireID) }
    backup.message(101) { s in s.string(1, "Obscure Reader"); s.int(2, unknownID) }
    return backup.bytes
}

// MARK: - Checks

@main
struct MihonBackupChecks {

    static func main() throws {
        try checkDecode()
        try checkRestoreAndMerge()
        try checkGzipSafety()
        try checkRejectsGarbage()
        if let path = ProcessInfo.processInfo.environment["TACHIBK_SAMPLE"] { try checkRealBackup(path) }
        print("PASS: .tachibk — decode, restore, merge, idempotent re-import, gzip limits, bad input")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError("FAIL: \(message)") }
    }

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        return try ModelContainer(
            for: schema, migrationPlan: LNReaderSchemaMigrationPlan.self,
            configurations: ModelConfiguration(UUID().uuidString, schema: schema, isStoredInMemoryOnly: true))
    }

    // MARK: decode

    private static func checkDecode() throws {
        let backup = try MihonBackup.decode(gzip(sampleBackup()))
        expect(backup.manga.count == 2, "two titles decoded")
        expect(backup.categories.map(\.name) == ["stash", "hiatus"], "categories decoded in file order")
        expect(backup.sourceNames[mangaFireID] == "MangaFire", "source names decoded")

        let first = backup.manga[0]
        expect(first.url == "/manga/overgeared.728q1" && first.title == "Overgeared", "url and title")
        expect(first.author == "Park Saenal, Rhyuji" && first.artist == "Park Saenal", "author/artist not swapped")
        expect(first.genres == ["Action", "Fantasy"], "repeated genre field")
        expect(first.favorite, "an absent favorite flag means favourite")
        expect(first.categoryOrders == [3], "category reference")
        expect(first.memo == #"{"slug":"overgeared"}"#, "memo")
        expect(first.chapters.count == 3 && first.chapters[1].number == 2, "float chapter number")
        expect(first.chapters[0].read && !first.chapters[1].read, "read flag")
        expect(first.chapters[1].lastPageRead == 7, "last page")
        expect(first.tracks.first?.mediaId == 98765 && first.tracks.first?.score == 8.5, "track mediaId and score")
        expect(first.history.first?.durationMs == 120_000, "history duration")
        expect(!backup.manga[1].favorite, "explicit false favorite")

        // Raw (ungzipped) protobuf is accepted too.
        try expect(try MihonBackup.decode(sampleBackup()).manga.count == 2, "raw protobuf")

        let preview = MihonBackup.preview(backup)
        expect(preview.matched == 1 && preview.unmatched == ["Obscure Reader": 1], "preview splits matched sources")
    }

    // MARK: restore

    private static func checkRestoreAndMerge() throws {
        let backup = try MihonBackup.decode(gzip(sampleBackup()))
        let container = try makeContainer()
        let summary = try MihonBackup.restore(backup, into: container)
        expect(summary.added == 2 && summary.merged == 0 && summary.chapters == 4, "first restore adds everything")
        expect(summary.categories == 2, "categories created")
        expect(summary.unmatchedSources == ["Obscure Reader": 1], "unmatched source reported")

        // Ids confirmed against a real Tachimanga backup (MangaFire, AllManga); the rest follow upstream's rule.
        expect(NativeSourceIDs.mihon[6_084_907_896_154_116_083] == "builtin:mangafire", "MangaFire id")
        expect(NativeSourceIDs.mihon[4_709_139_914_729_853_090] == "builtin:allmanga", "AllManga id")
        expect(MihonSourceID.make(name: "allanime", lang: "en") == 4_709_139_914_729_853_090, "AllManga id derives from allanime")
        // Named rather than counted: adding a source updates this list once, and a
        // missing mapping cannot hide behind a total that still adds up.
        expect(
            Set(NativeSourceIDs.mihon.values) == [
                "builtin:mangafire", "builtin:allmanga", "builtin:manhwa18", "builtin:fourkhd",
                "builtin:omegascans", "builtin:pornpics", "builtin:metarthunter",
                "builtin:atsumaru", "builtin:weebcentral", "builtin:kagane",
            ],
            "every native manga source carries a Mihon id")

        let context = ModelContext(container)
        let entries = try context.fetch(FetchDescriptor<Entry>())
        expect(entries.count == 2, "two entries stored")
        let overgeared = try unwrap(entries.first { $0.title == "Overgeared" })
        expect(overgeared.sourceKey == "builtin:mangafire", "MangaFire id maps to the native source")
        expect(overgeared.kind == .manga && overgeared.inLibrary, "kind and library flag")
        expect(overgeared.status == .ongoing && overgeared.genres == ["Action", "Fantasy"], "status and genres")
        expect(overgeared.categories.map(\.name) == ["hiatus"], "category order 3 -> hiatus")
        expect(overgeared.tracks.count == 1 && overgeared.tracks[0].remoteId == 98765, "track stored")
        expect(overgeared.lastReadAt != nil, "history sets lastReadAt")

        let byName = Dictionary(uniqueKeysWithValues: overgeared.chapters.map { ($0.name, $0) })
        expect(byName["Chapter 1"]?.read == true && byName["Chapter 1"]?.progress == 100, "read chapter is 100%")
        expect(byName["Chapter 1"]?.history?.timeRead == 120, "history seconds")
        expect(byName["Chapter 2"]?.lastPageRead == 7 && byName["Chapter 2"]?.scanlator == "official", "resume page, scanlator")
        expect(byName["Chapter 3"]?.bookmark == true, "bookmark")

        let orphan = try unwrap(entries.first { $0.title == "Orphan" })
        expect(orphan.sourceKey == "mihon:1234567" && !orphan.inLibrary, "unknown source keeps its id, not in library")

        // Importing again changes nothing.
        let again = try MihonBackup.restore(backup, into: container)
        expect(again.added == 0 && again.merged == 2 && again.chapters == 0, "second restore is a no-op")
        try expect(try context.fetch(FetchDescriptor<SchemaV2.Chapter>()).count == 4, "no duplicate chapters")
        try expect(try context.fetch(FetchDescriptor<SchemaV2.Category>()).count == 2, "no duplicate categories")

        try checkMergeKeepsLocalState()
    }

    private static func checkMergeKeepsLocalState() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = Entry(kind: .manga, sourceKey: "builtin:mangafire", url: "/manga/overgeared.728q1", title: "My Title")
        entry.summary = "mine"
        context.insert(entry)
        let local = SchemaV2.Chapter(url: "/manga/overgeared.728q1/1002-chapter-2-en", name: "Chapter 2", chapterNumber: 2)
        context.insert(local); local.entry = entry
        local.read = true; local.lastPageRead = 12
        try context.save()

        _ = try MihonBackup.restore(try MihonBackup.decode(sampleBackup()), into: container)

        let fresh = ModelContext(container)
        let merged = try unwrap(try fresh.fetch(FetchDescriptor<Entry>()).first { $0.url == "/manga/overgeared.728q1" })
        expect(merged.title == "My Title" && merged.summary == "mine", "existing details win")
        let chapter = try unwrap(merged.chapters.first { $0.url.hasSuffix("1002-chapter-2-en") })
        expect(chapter.read, "read is OR-ed, not cleared by the backup")
        expect(chapter.lastPageRead == 12, "the further page wins")
        expect(merged.chapters.count == 3, "backup chapters added around the existing one")
    }

    // MARK: gzip

    private static func checkGzipSafety() throws {
        let zeros = Data(count: 8 * 1024 * 1024)
        let packed = gzip(zeros)
        expect(packed.count < 100_000, "fixture really is a compression bomb")
        do { _ = try Gzip.decompress(packed, limit: 1024 * 1024); fatalError("FAIL: limit not enforced") }
        catch Gzip.GzipError.tooLarge {}
        try expect(try Gzip.decompress(packed, limit: 16 * 1024 * 1024).count == zeros.count, "round trip under the limit")

        let cut = packed.prefix(packed.count / 2)
        do { _ = try Gzip.decompress(Data(cut), limit: 16 * 1024 * 1024); fatalError("FAIL: truncated gzip accepted") }
        catch is Gzip.GzipError {}
    }

    private static func checkRejectsGarbage() throws {
        for sample in [Data(), Data("not a backup at all".utf8), Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0x0f])] {
            do { _ = try MihonBackup.decode(sample); fatalError("FAIL: garbage accepted") } catch {}
        }
    }

    // MARK: real file

    private static func checkRealBackup(_ path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let started = Date()
        let backup = try MihonBackup.decode(data)
        let chapters = backup.manga.reduce(0) { $0 + $1.chapters.count }
        let preview = MihonBackup.preview(backup)
        print("sample: \(backup.manga.count) titles, \(chapters) chapters, \(backup.categories.count) categories, "
            + "matched=\(preview.matched), unmatched=\(preview.unmatched) "
            + "(decode \(String(format: "%.2f", Date().timeIntervalSince(started)))s)")

        let container = try makeContainer()
        let restoreStart = Date()
        let summary = try MihonBackup.restore(backup, into: container)
        print("sample restore: added=\(summary.added) chapters=\(summary.chapters) categories=\(summary.categories) "
            + "(\(String(format: "%.2f", Date().timeIntervalSince(restoreStart)))s)")

        let context = ModelContext(container)
        try expect(try context.fetch(FetchDescriptor<Entry>()).count == backup.manga.count, "every title stored")
        try expect(try context.fetch(FetchDescriptor<SchemaV2.Chapter>()).count == chapters, "every chapter stored")
        let fire = try context.fetch(FetchDescriptor<Entry>()).filter { $0.sourceKey == "builtin:mangafire" }
        let all = try context.fetch(FetchDescriptor<Entry>()).filter { $0.sourceKey == "builtin:allmanga" }
        print("sample sources: mangafire=\(fire.count) allmanga=\(all.count)")
        expect(fire.count + all.count == backup.manga.count, "both sources in the file map to bundled extensions")
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { fatalError("FAIL: expected a value") }
        return value
    }
}
