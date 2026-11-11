import CryptoKit
import Foundation
import ImageIO
import SwiftData
import UIKit

@Observable @MainActor
final class ChapterDownloadManager {
    static let shared = ChapterDownloadManager()
    private var context: ModelContext?
    private var sources: SourceManager?
    private var worker: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var active: PersistentIdentifier?
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid
    var isRunning = false
    var message: String?
    /// Live per-page progress for the running item. Held in memory because every
    /// `save()` re-runs every `@Query` in the app; a per-page save made the whole
    /// UI stutter for as long as a manga chapter was downloading.
    private(set) var liveProgress: [String: Double] = [:]
    /// Every item's state keyed by chapter, so a chapter row reads its own state in
    /// O(1) and updates the moment the queue changes, without a model lookup.
    private(set) var states: [String: DownloadState] = [:]

    static func key(sourceKey: String, entryURL: String, chapterURL: String) -> String {
        "\(sourceKey)\u{1F}\(entryURL)\u{1F}\(chapterURL)"
    }
    private func key(_ item: DownloadItem) -> String? {
        guard let chapter = item.chapter, let entry = chapter.entry else { return nil }
        return Self.key(sourceKey: entry.sourceKey, entryURL: entry.url, chapterURL: chapter.url)
    }
    private func set(_ item: DownloadItem, _ state: DownloadState) {
        item.state = state
        if let key = key(item) { states[key] = state }
    }

    func progress(of item: DownloadItem) -> Double {
        key(item).flatMap { liveProgress[$0] } ?? item.progress
    }

    func status(sourceKey: String, entryURL: String, chapterURL: String, downloaded: Bool) -> ChapterDownloadStatus {
        let key = Self.key(sourceKey: sourceKey, entryURL: entryURL, chapterURL: chapterURL)
        switch states[key] {
        case .none: return downloaded ? .downloaded : .none
        case .queued: return .queued
        case .downloading: return .downloading(liveProgress[key] ?? 0)
        case .paused: return .paused
        case .failed: return .failed
        case .completed: return .downloaded
        }
    }

    func configure(context: ModelContext, sources: SourceManager) {
        guard self.context == nil else { resume(); return }
        self.context = context; self.sources = sources
        networkTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Notification.Name("LNReaderNetworkChanged")) {
                self?.resume()
            }
        }
        do {
            // One fetch, and no disk on the main actor: checking that each finished
            // download still has its files reads a manifest per item, which is
            // seconds of I/O for a big library. That part runs detached below.
            var completed: [(id: PersistentIdentifier, sourceKey: String, entryURL: String, chapterURL: String)] = []
            for item in try context.fetch(FetchDescriptor<DownloadItem>()) {
                guard let chapter = item.chapter, let entry = chapter.entry else { context.delete(item); continue }
                if item.state == .downloading { set(item, .queued) }
                if let key = key(item) { states[key] = item.state }
                if item.state == .completed {
                    completed.append((item.persistentModelID, entry.sourceKey, entry.url, chapter.url))
                }
            }
            try context.save()
            resume()
            guard !completed.isEmpty else { return }
            Task { [weak self] in
                let missing = await Task.detached(priority: .utility) {
                    completed.filter {
                        OfflineChapters.manifest(sourceKey: $0.sourceKey, entryURL: $0.entryURL, chapterURL: $0.chapterURL) == nil
                    }.map(\.id)
                }.value
                guard let self, let context = self.context, !missing.isEmpty else { return }
                for id in missing {
                    guard let item = context.model(for: id) as? DownloadItem, item.state == .completed else { continue }
                    self.set(item, .failed)
                    item.error = "Offline files are missing. Retry this download."
                }
                self.persist()
            }
        } catch { message = error.localizedDescription }
    }
    func enqueue(_ chapters: [Chapter], userInitiated: Bool = true) {
        guard let context else { return }
        do {
            var lastOrder = FetchDescriptor<DownloadItem>(sortBy: [SortDescriptor(\.order, order: .reverse)])
            lastOrder.fetchLimit = 1
            var order = (try context.fetch(lastOrder)).first?.order ?? 0
            for incoming in ChapterOrder.oldestFirst(chapters) {
                guard let chapter = context.model(for: incoming.persistentModelID) as? Chapter,
                      chapter.entry?.isLocal == false else { continue }
                if let item = chapter.downloadItem {
                    if item.state == .completed || item.state == .downloading { continue }
                    set(item, .queued); item.error = nil
                } else {
                    order += 1
                    let item = DownloadItem(chapter: chapter, order: order)
                    context.insert(item); chapter.downloadItem = item
                    set(item, .queued)
                }
            }
            try context.save()
            let wasRunning = isRunning
            resume()
            if userInitiated && !wasRunning { LibraryMaintenance.continueDownloads() }
            else { LibraryMaintenance.scheduleDownloads() }
        } catch { message = error.localizedDescription }
    }
    func pause(_ item: DownloadItem) {
        set(item, .paused)
        if active == item.persistentModelID {
            let stopping = worker
            stopping?.cancel()
            Task { [weak self] in await stopping?.value; self?.resume() }
        }
        persist()
    }
    func retry(_ item: DownloadItem) {
        set(item, .queued); item.error = nil; persist(); resume()
    }
    func remove(_ item: DownloadItem) {
        guard let context else { return }
        if active == item.persistentModelID {
            set(item, .paused); worker?.cancel()
            persist()
            let stopping = worker
            Task { [weak self] in
                await stopping?.value
                self?.remove(item)
                self?.resume()
            }
            return
        }
        do {
            if let key = key(item) { states[key] = nil; liveProgress[key] = nil }
            if let chapter = item.chapter, let entry = chapter.entry {
                let folder = OfflineChapters.folder(sourceKey: entry.sourceKey, entryURL: entry.url, chapterURL: chapter.url)
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                chapter.downloadItem = nil
            }
            context.delete(item); try context.save()
        } catch { message = error.localizedDescription }
    }
    func resume() {
        if let stopping = worker, stopping.isCancelled {
            Task { [weak self] in await stopping.value; self?.resume() }
            return
        }
        guard worker == nil, let context, let sources else { return }
        isRunning = true
        worker = Task {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Chapter downloads") {
                Task { @MainActor in ChapterDownloadManager.shared.worker?.cancel() }
            }
            var unsavedCount = 0
            defer {
                if unsavedCount > 0 {
                    try? context.save()
                    unsavedCount = 0
                }
                active = nil; isRunning = false; worker = nil
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid }
            }
            do {
                while !Task.isCancelled {
                    guard NetworkMonitor.shared.isConnected() else { message = "Waiting for a network connection."; break }
                    if UserDefaults.standard.object(forKey: "downloads.wifiOnly") as? Bool ?? true,
                       !NetworkMonitor.shared.isOnWiFi() { message = "Waiting for Wi-Fi. Tap Resume when connected."; break }
                    message = nil
                    let items = try context.fetch(FetchDescriptor<DownloadItem>(sortBy: [SortDescriptor(\.order)]))
                    guard let item = items.first(where: { $0.state == .queued }), let chapter = item.chapter,
                          let entry = chapter.entry else { break }
                    // No save here: `configure` requeues stale `.downloading` rows, and the
                    // outcome below is saved. Coalescing saves (batches of 3 or at queue end)
                    // avoids re-running every `@Query` in the app after every single chapter.
                    active = item.persistentModelID; set(item, .downloading); item.error = nil
                    do {
                        try await download(chapter, entry: entry, item: item, sources: sources)
                        try Task.checkCancellation()
                        guard item.modelContext != nil else { continue }
                        set(item, .completed); item.progress = 1
                        if let key = key(item) { liveProgress[key] = nil }
                    } catch {
                        guard item.modelContext != nil else { continue }
                        if Task.isCancelled { if item.state == .downloading { set(item, .queued) } }
                        else { set(item, .failed); item.error = error.localizedDescription }
                    }
                    if item.modelContext != nil, let key = key(item) { liveProgress[key] = nil }
                    active = nil
                    unsavedCount += 1
                    let hasMoreQueued = items.contains(where: { $0.state == .queued && $0.persistentModelID != item.persistentModelID })
                    if unsavedCount >= 3 || !hasMoreQueued {
                        try context.save()
                        unsavedCount = 0
                    }
                }
            } catch { message = error.localizedDescription }
        }
    }
    func stop() async { worker?.cancel(); await worker?.value }
    private func persist() { do { try context?.save() } catch { message = error.localizedDescription } }
    /// Everything a chapter's download touches besides the queue's own rows
    /// runs in `fetch`, off the main actor. Only the queue bookkeeping (a few
    /// model writes and one save per chapter) stays here, because the queue
    /// screen edits the same rows.
    private func download(_ chapter: Chapter, entry: Entry, item: DownloadItem, sources: SourceManager) async throws {
        let job = DownloadJob(sourceKey: entry.sourceKey, entryURL: entry.url, chapterURL: chapter.url,
                              chapterName: chapter.name, kind: entry.kind)
        let source: DownloadJob.Source
        if entry.kind == .novel {
            guard let novel = sources.novelSource(forKey: entry.sourceKey) else { throw CocoaError(.fileNoSuchFile) }
            source = .novel(novel)
        } else {
            guard let manga = sources.mangaSource(forKey: entry.sourceKey) else { throw CocoaError(.fileNoSuchFile) }
            source = .manga(manga)
        }
        let key = key(item)
        try await Self.fetch(job, from: source) { @MainActor [weak self] fraction in
            if let key { self?.liveProgress[key] = fraction }
        }
    }

    /// One chapter to download, as plain values: no models cross into `fetch`.
    private struct DownloadJob: Sendable {
        enum Source: Sendable {
            case novel(any NovelSource)
            case manga(any MangaSource)
        }
        let sourceKey: String
        let entryURL: String
        let chapterURL: String
        let chapterName: String
        let kind: ContentKind
    }

    /// Fetch a chapter and write it to its offline folder: source calls, page
    /// requests, disk writes and the manifest, all off the main actor. A
    /// removed or paused item cancels the worker, which cancels this.
    @concurrent
    private nonisolated static func fetch(
        _ job: DownloadJob,
        from source: DownloadJob.Source,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        var root = OfflineChapters.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        let folder = OfflineChapters.folder(sourceKey: job.sourceKey, entryURL: job.entryURL, chapterURL: job.chapterURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Removing the old manifest prevents partial replacements being advertised as complete.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        let sourceChapter = SourceChapter(url: job.chapterURL, name: job.chapterName)
        var files: [String] = []
        switch source {
        case .novel(let source):
            try checkSpace(at: root)
            let html = try await source.chapterHTML(sourceChapter)
            try Task.checkCancellation()
            guard !html.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try Data(html.utf8).write(to: folder.appendingPathComponent("chapter.html"), options: .atomic)
            files = ["chapter.html"]
        case .manga(let source):
            let pages = try await source.pages(sourceChapter)
            guard !pages.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            // Once per chapter: the 200 MB margin covers a chapter, and a full
            // disk still fails the write below.
            try checkSpace(at: root)
            let loader = PageLoader()
            for (index, page) in pages.enumerated() {
                try Task.checkCancellation()
                // Resolve lazy image URLs and preserve source-specific request headers.
                let request = try await source.imageRequest(page)
                guard let url = request.url else { throw CocoaError(.fileReadCorruptFile) }
                let imagePage = SourcePage(index: index, url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
                let data = try await loader.image(for: imagePage, sourceKey: job.sourceKey)
                try Task.checkCancellation()
                guard let probe = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(probe) > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let name = String(format: "%06d.page", index)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                files.append(name)
                await progress(Double(index + 1) / Double(pages.count))
            }
        }
        try Task.checkCancellation()
        let manifest = OfflineChapters.Manifest(sourceKey: job.sourceKey, entryURL: job.entryURL,
                                                chapterURL: job.chapterURL, kind: job.kind, files: files)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Never on the main actor: the "important usage" capacity is a synchronous
    /// call to the system's storage service, about 45 ms. Made once per page on
    /// the main actor, it stalled the reader four times a second while a
    /// chapter downloaded behind it.
    private nonisolated static func checkSpace(at url: URL) throws {
        let free = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > 200 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
    }

    // MARK: Reading-driven automation

    /// Chapters already counted for download-ahead this session, so the queue is
    /// touched once per chapter and not on every progress tick.
    private var aheadTriggered: Set<PersistentIdentifier> = []

    /// Called as a chapter is read. With "Download ahead" on, queues the next few
    /// chapters by number (never `sourceOrder`) that have no download yet.
    func chapterOpened(_ chapter: Chapter) {
        let ahead = UserDefaults.standard.integer(forKey: "downloads.aheadCount")
        guard ahead > 0, let entry = chapter.entry, entry.inLibrary, !entry.isLocal,
              chapter.chapterNumber >= 0,
              aheadTriggered.insert(chapter.persistentModelID).inserted else { return }
        var seen = Set<Double>()
        let window = entry.visibleChapters
            .filter { $0.chapterNumber > chapter.chapterNumber }
            .sorted { $0.chapterNumber < $1.chapterNumber }
            .filter { seen.insert($0.chapterNumber).inserted }
            .prefix(ahead)
        let missing = window.filter { $0.downloadItem == nil }
        if !missing.isEmpty { enqueue(missing, userInitiated: false) }
    }

    /// Called when a chapter flips to read. "Delete after reading" removes the
    /// download of the chapter `offset - 1` places behind it (1 = the one just
    /// read), optionally sparing bookmarks.
    func chapterFinished(_ chapter: Chapter) {
        let offset = UserDefaults.standard.integer(forKey: "downloads.deleteAfterRead")
        guard offset > 0, let entry = chapter.entry, !entry.isLocal, chapter.chapterNumber >= 0 else { return }
        let keepBookmarked = UserDefaults.standard.object(forKey: "downloads.keepBookmarked") as? Bool ?? true
        var seen = Set<Double>()
        let numbers = entry.chapters
            .map(\.chapterNumber)
            .filter { $0 <= chapter.chapterNumber && $0 >= 0 }
            .sorted(by: >)
            .filter { seen.insert($0).inserted }
        guard numbers.count >= offset else { return }
        let target = numbers[offset - 1]
        for old in entry.chapters where old.chapterNumber == target {
            guard let item = old.downloadItem, item.state == .completed else { continue }
            if keepBookmarked && old.bookmark { continue }
            remove(item)
        }
    }

    /// Chapters the user marked read by hand (selection bar). With "Remove after
    /// marked as read" on, their downloads go, sparing bookmarks if asked.
    func chaptersMarkedRead(_ chapters: [Chapter]) {
        guard UserDefaults.standard.bool(forKey: "downloads.deleteOnMarkRead") else { return }
        let keepBookmarked = UserDefaults.standard.object(forKey: "downloads.keepBookmarked") as? Bool ?? true
        for chapter in chapters {
            guard chapter.entry?.isLocal == false, let item = chapter.downloadItem, item.state == .completed else { continue }
            if keepBookmarked && chapter.bookmark { continue }
            remove(item)
        }
    }

    // MARK: Queue and per-title actions

    /// Items still to do, in the order they will run.
    private func pending() -> [DownloadItem] {
        guard let context else { return [] }
        let all = (try? context.fetch(FetchDescriptor<DownloadItem>(sortBy: [SortDescriptor(\.order)]))) ?? []
        return all.filter { $0.state != .completed }
    }

    func storedItem(_ chapterURL: String, in entry: Entry) -> DownloadItem? {
        entry.chapters.first { $0.url == chapterURL }?.downloadItem
    }

    func download(_ chapterURL: String, in entry: Entry) {
        guard let chapter = entry.chapters.first(where: { $0.url == chapterURL }) else { return }
        enqueue([chapter])
    }

    /// The next `count` unread chapters that are not already downloaded, oldest first;
    /// `nil` means every unread one.
    func enqueueUnread(_ count: Int?, in entry: Entry) {
        let candidates = ChapterOrder.oldestFirst(
            entry.visibleChapters.filter { !$0.read && !$0.isDownloaded }
        )
        enqueue(count.map { Array(candidates.prefix($0)) } ?? candidates)
    }

    func deleteDownloads(in entry: Entry) {
        for item in entry.chapters.compactMap(\.downloadItem) { remove(item) }
    }

    func pauseAll() {
        for item in pending() where item.state == .queued || item.state == .downloading { pause(item) }
    }
    func resumeAll() {
        for item in pending() where item.state == .paused || item.state == .failed { retry(item) }
        resume()
    }
    func cancelAll() {
        for item in pending() { remove(item) }
    }
    func clearAll() {
        guard let context else { return }
        for item in (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? [] { remove(item) }
    }

    func moveToTop(_ item: DownloadItem) {
        let first = pending().first?.order ?? item.order
        item.order = first - 1
        persist()
    }

    /// Reorder the pending queue as the list showed it. The same set of `order`
    /// values is handed out again, so finished rows keep their place.
    func move(_ items: [DownloadItem], from source: IndexSet, to destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        let slots = items.map(\.order).sorted()
        for (item, slot) in zip(reordered, slots) { item.order = slot }
        persist()
    }

    /// Bytes under the downloads folder; walks the disk, so call it off the main actor.
    nonisolated static func storageBytes() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: OfflineChapters.root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// What a chapter row shows for its download.
enum ChapterDownloadStatus: Equatable {
    case none, queued, downloading(Double), paused, failed, downloaded
}
