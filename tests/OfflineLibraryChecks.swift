import Foundation
import CryptoKit
import SwiftData

@main @MainActor struct OfflineLibraryChecks {
    static func main() throws {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let entry = Entry(kind: .novel, sourceKey: "ln:test-backup", url: "/test", title: "Original title")
        entry.inLibrary = true
        let chapter = Chapter(url: "/test/chapter", name: "One", chapterNumber: 1)
        context.insert(entry); context.insert(chapter); chapter.entry = entry
        chapter.read = true; chapter.progress = 60; chapter.bookmark = true; chapter.paragraphIndex = 8
        let history = History(chapterURL: chapter.url, lastRead: Date(timeIntervalSince1970: 100))
        context.insert(history); history.chapter = chapter; chapter.history = history; history.timeRead = 120
        let category = Category(name: "Favorites"); context.insert(category); entry.categories = [category]
        let track = Track(syncId: 2, remoteId: 321, title: "Tracking")
        context.insert(track); track.entry = entry; track.lastChapterRead = 10
        try context.save()
        let snapshot = try LibraryBackup.snapshot(context: context)
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let data = try LibraryBackup.seal(JSONEncoder().encode(snapshot), recoveryKey: key)
        precondition(LibraryBackup.isEncrypted(data))
        let restored = try LibraryBackup.open(data, recoveryKey: key)
        precondition(restored.entries.first?.chapters.first?.paragraph == 8)
        var tampered = data; tampered[tampered.count - 1] ^= 1
        try rejects { _ = try LibraryBackup.open(tampered, recoveryKey: key) }
        try rejects { _ = try LibraryBackup.open(data, recoveryKey: Data(repeating: 0, count: 32).base64EncodedString()) }
        try rejects { _ = try LibraryBackup.open(Data("not a backup".utf8), recoveryKey: key) }

        let unencryptedData = try LibraryBackup.packUnencrypted(JSONEncoder().encode(snapshot))
        precondition(!LibraryBackup.isEncrypted(unencryptedData))
        let restoredUnencrypted = try LibraryBackup.open(unencryptedData)
        precondition(restoredUnencrypted.entries.first?.chapters.first?.paragraph == 8)
        var tamperedUnencrypted = unencryptedData; tamperedUnencrypted[tamperedUnencrypted.count - 1] ^= 1
        try rejects { _ = try LibraryBackup.open(tamperedUnencrypted) }
        let rawJson = try JSONEncoder().encode(snapshot)
        precondition(!LibraryBackup.isEncrypted(rawJson))
        let restoredJson = try LibraryBackup.open(rawJson)
        precondition(restoredJson.entries.first?.chapters.first?.paragraph == 8)
        let bad = LibraryBackup.Snapshot(createdAt: .now, entries: [], categories: [], preferences: snapshot.preferences,
                                        localFiles: ["../escape/file": Data()])
        try rejects { try LibraryBackup.validate(bad) }
        let target = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        _ = try LibraryBackup.restore(restored, container: target)
        let check = ModelContext(target)
        let e = try check.fetch(FetchDescriptor<Entry>())[0]
        precondition(e.inLibrary && e.chapters.count == 1 && e.categories.first?.name == "Favorites")
        precondition(e.chapters[0].read && e.chapters[0].bookmark && e.chapters[0].history?.timeRead == 120)
        precondition(e.tracks.first?.lastChapterRead == 10)
        e.title = "Keep my title"; e.chapters[0].progress = 90; e.tracks[0].lastChapterRead = 20
        try check.save()
        _ = try LibraryBackup.restore(restored, container: target)
        let verify = ModelContext(target)
        let merged = try verify.fetch(FetchDescriptor<Entry>())
        precondition(merged.count == 1 && merged[0].title == "Keep my title")
        precondition(merged[0].chapters.count == 1 && merged[0].chapters[0].progress == 90)
        precondition(merged[0].tracks[0].lastChapterRead == 20)
        try checkOfflineFiles()
        precondition(!LibraryUpdatePolicy.permits(strategy: .never, hasFetched: false, status: .ongoing,
            hasUnread: true, skipUnread: false, skipCompleted: false))
        precondition(!LibraryUpdatePolicy.permits(strategy: .onlyFetchOnce, hasFetched: true, status: .ongoing,
            hasUnread: true, skipUnread: false, skipCompleted: false))
        precondition(LibraryUpdatePolicy.permits(strategy: .onlyFetchOnce, hasFetched: false, status: .ongoing,
            hasUnread: false, skipUnread: true, skipCompleted: true))
        precondition(!LibraryUpdatePolicy.permits(strategy: .always, hasFetched: false, status: .publishingFinished,
            hasUnread: true, skipUnread: false, skipCompleted: true))
        precondition(!LibraryUpdatePolicy.permits(strategy: .always, hasFetched: true, status: .ongoing,
            hasUnread: true, skipUnread: true, skipCompleted: false))
        print("PASS: backup encryption/authentication, wrong-key/tamper rejection, traversal rejection, full-state restore, idempotent non-destructive merge, offline manifests and missing files")
    }
    static func rejects(_ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        precondition(rejected)
    }
    static func checkOfflineFiles() throws {
        let id = UUID().uuidString
        let folder = OfflineChapters.folder(sourceKey: id, entryURL: "entry", chapterURL: "chapter")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = OfflineChapters.Manifest(sourceKey: id, entryURL: "entry", chapterURL: "chapter", kind: .novel, files: ["chapter.html"])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        precondition(OfflineChapters.novel(sourceKey: id, entryURL: "entry", chapterURL: "chapter") == nil)
        try Data("<p>Offline</p>".utf8).write(to: folder.appendingPathComponent("chapter.html"))
        precondition(OfflineChapters.novel(sourceKey: id, entryURL: "entry", chapterURL: "chapter") == "<p>Offline</p>")
        let bad = OfflineChapters.Manifest(sourceKey: id, entryURL: "entry", chapterURL: "chapter", kind: .novel, files: ["../outside"])
        try JSONEncoder().encode(bad).write(to: folder.appendingPathComponent("manifest.json"))
        precondition(OfflineChapters.manifest(sourceKey: id, entryURL: "entry", chapterURL: "chapter") == nil)
        precondition(folder != OfflineChapters.folder(sourceKey: id + "entry", entryURL: "", chapterURL: "chapter"))
    }
}
