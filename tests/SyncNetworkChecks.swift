import Foundation
import SwiftData

@main
@MainActor
struct SyncNetworkChecks {
    static func main() async throws {
        guard let address = ProcessInfo.processInfo.environment["LNREADER_SYNC_TEST_URL"],
              let url = URL(string: address), url.host == "127.0.0.1", url.scheme == "http" else {
            fatalError("Set LNREADER_SYNC_TEST_URL to a disposable backend on http://127.0.0.1")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sync-network-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: SchemaV3.self)
        let uploadStore = try ModelContainer(for: schema, configurations: ModelConfiguration("upload", schema: schema, url: root.appendingPathComponent("upload.store")))
        let downloadStore = try ModelContainer(for: schema, configurations: ModelConfiguration("download", schema: schema, url: root.appendingPathComponent("download.store")))
        let uploadContext = uploadStore.mainContext
        var downloadContext = downloadStore.mainContext
        let id = UUID().uuidString
        let localDirectory = SyncFiles.documents.appendingPathComponent("LocalNovels/\(id)")
        let coverURL = SyncFiles.documents.appendingPathComponent("Covers/\(id).jpg")
        defer {
            try? fm.removeItem(at: localDirectory)
            try? fm.removeItem(at: coverURL)
            try? fm.removeItem(at: root)
        }
        let content = Data(("<html><body><p>Imported EPUB chapter</p>" + String(repeating: "text ", count: 850_000) + "</body></html>").utf8)
        try fm.createDirectory(at: localDirectory.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try content.write(to: localDirectory.appendingPathComponent("OPS/one.xhtml"))
        try fm.createDirectory(at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: coverURL)
        let profile = UserProfile(name: "Sync test")
        uploadContext.insert(profile)
        let local = Entry(kind: .novel, sourceKey: "local", url: "local://\(id)", title: "Imported EPUB")
        local.inLibrary = true
        local.thumbnailURL = "local://Covers/\(id).jpg"
        let localChapter = Chapter(url: "OPS/one.xhtml", name: "One")
        local.chapters = [localChapter]
        localChapter.bookmark = true
        localChapter.paragraphIndex = 17
        localChapter.progress = 22.125
        uploadContext.insert(local)
        let source = Entry(kind: .novel, sourceKey: "builtin:novelfire", url: "book/sync-test", title: "Source book")
        source.inLibrary = true
        source.lastReadAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        source.lastUpdate = source.lastReadAt
        let first = Chapter(url: "book/sync-test/1", name: "One", sourceOrder: 0)
        first.read = true
        first.progress = 100
        let second = Chapter(url: "book/sync-test/2", name: "Two", sourceOrder: 1)
        second.progress = 54.625
        second.paragraphIndex = 97
        second.bookmark = true
        source.chapters = [first, second]
        uploadContext.insert(source)
        let history = History(chapterURL: second.url, lastRead: source.lastReadAt!)
        uploadContext.insert(history)
        second.history = history
        history.chapter = second
        history.timeRead = 62.5
        let highlight = Highlight(text: "A saved sentence", color: "yellow", sourceKey: source.sourceKey,
            entryURL: source.url, chapterURL: second.url, chapterName: second.name, chapterNumber: 2,
            sourceOrder: 1, paragraphIndex: 97, startOffset: 3, endOffset: 19, bookTitle: source.title, bookCoverURL: nil)
        uploadContext.insert(highlight)

        let sync = SyncManager()
        sync.updateBackendURL(address)
        let username = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        await sync.register(username: String(username), email: "\(username)@example.com", password: "sync-test-password-123")
        precondition(sync.currentUser != nil, sync.lastError ?? "sign-in failed")
        await sync.restore(into: downloadContext)
        precondition(sync.lastError?.contains("no cloud copy") == true, "empty cloud must not report successful restore")
        await sync.push(profile: profile, sources: [], context: uploadContext)
        precondition(sync.lastError == nil, sync.lastError ?? "upload failed")
        precondition(sync.hasSynced && sync.progress?.fraction == 1 && sync.progress?.isFinished == true)
        try fm.moveItem(at: localDirectory, to: root.appendingPathComponent("original-book"))
        try fm.moveItem(at: coverURL, to: root.appendingPathComponent("original-cover"))
        await sync.loadSession()
        let beforeDownload = try downloadContext.fetch(FetchDescriptor<Entry>())
        precondition(beforeDownload.isEmpty, "loading the account must not apply cloud data")
        await sync.restore(into: downloadContext)
        precondition(sync.lastError == nil, sync.lastError ?? "download failed")
        precondition(sync.restoredContext !== downloadContext, "restore must replace the UI context")
        downloadContext = sync.restoredContext!
        let books = try downloadContext.fetch(FetchDescriptor<Entry>())
        precondition(books.count == 2, "fresh store should have both imported and source books")
        let restoredLocal = books.first { $0.isLocal }!
        precondition(restoredLocal.sourceKey == "local" && restoredLocal.url == local.url)
        precondition(restoredLocal.chapters[0].bookmark && restoredLocal.chapters[0].paragraphIndex == 17)
        let restoredBytes = try Data(contentsOf: localDirectory.appendingPathComponent("OPS/one.xhtml"))
        precondition(restoredBytes == content, "EPUB bytes changed during round-trip")
        let restoredCover = try Data(contentsOf: coverURL)
        precondition(restoredCover == Data([1, 2, 3, 4]))
        let restored = books.first { !$0.isLocal }!
        let current = restored.chapters.first { $0.url == second.url }!
        precondition(restored.chapters.filter(\.read).count == 1)
        precondition(current.progress == 54.625 && current.paragraphIndex == 97 && current.bookmark)
        precondition(current.history?.lastRead == source.lastReadAt && current.history?.timeRead == 62.5)
        let highlights = try downloadContext.fetch(FetchDescriptor<Highlight>())
        precondition(highlights.count == 1 && highlights[0].id == highlight.id && highlights[0].startOffset == 3)

        current.progress = 12.25
        current.paragraphIndex = 8
        current.bookmark = false
        try downloadContext.save()
        await sync.restore(into: downloadContext)
        precondition(sync.lastError == nil, sync.lastError ?? "repeat restore failed")
        precondition(sync.restoredContext !== downloadContext)
        downloadContext = sync.restoredContext!
        let reloaded = try downloadContext.fetch(FetchDescriptor<Chapter>()).first { $0.url == second.url }!
        precondition(reloaded.progress == 54.625 && reloaded.paragraphIndex == 97 && reloaded.bookmark)

        reloaded.progress = 12.25
        reloaded.paragraphIndex = 8
        reloaded.bookmark = false
        for saved in try downloadContext.fetch(FetchDescriptor<Highlight>()) { downloadContext.delete(saved) }
        let downloadedProfile = try downloadContext.fetch(FetchDescriptor<UserProfile>()).first!
        await sync.push(profile: downloadedProfile, sources: [], context: downloadContext)
        precondition(sync.lastError == nil, sync.lastError ?? "second upload failed")
        await sync.restore(into: uploadContext)
        precondition(sync.lastError == nil, sync.lastError ?? "second device download failed")
        let roundTripContext = sync.restoredContext!
        let roundTrip = try roundTripContext.fetch(FetchDescriptor<Chapter>()).first { $0.url == second.url }!
        precondition(roundTrip.progress == 12.25 && roundTrip.paragraphIndex == 8 && !roundTrip.bookmark)
        let deletedHighlights = try roundTripContext.fetch(FetchDescriptor<Highlight>())
        precondition(deletedHighlights.isEmpty, "removed bookmarks must not be resurrected")

        await sync.signOut()
        precondition(sync.currentUser == nil)
        await sync.push(profile: profile, sources: [], context: uploadContext)
        precondition(sync.lastError != nil && sync.progress?.failed == true && !sync.isWorking)
        print("PASS: real backend + Swift client — login, unsaved-state upload, chunked EPUB/cover restore, exact progress/history/highlights, repeat restore, no automatic sync, expired session")
    }
}
