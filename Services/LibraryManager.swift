// LibraryManager.swift
// Library operations: adding entries, updating chapters, recording progress.

import Foundation
import Network
import Observation
import SwiftData

struct UpdateJob: Sendable {
    let id: PersistentIdentifier
    let sourceKey: String
    let url: String
    let kind: ContentKind
    let title: String
    let sourceName: String
}

struct UpdateWork {
    let source: any CatalogSource
    let job: UpdateJob
}

struct UpdateResult: Sendable {
    let job: UpdateJob
    let details: SourceEntry?
    let chapters: [SourceChapter]
    let error: String?
}

/// Merges fetched source details and chapter lists into the persistent store
/// off the main actor, so background refreshes and unlock catches never stall
/// scrolling or UI interactions.
actor LibraryUpdateMerger {
    let context: ModelContext
    private var unsaved = 0

    init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    struct Outcome: Sendable {
        let title: String
        let sourceName: String
        let fresh: Int
        let error: String?
    }

    func merge(_ result: UpdateResult) -> Outcome {
        if let details = result.details, result.error == nil {
            guard let entry = context.model(for: result.job.id) as? Entry else {
                return Outcome(title: result.job.title, sourceName: result.job.sourceName,
                               fresh: 0, error: "Entry no longer in database")
            }
            let merged = LibraryManager.applyUpdate(entry, details: details, chapters: result.chapters,
                                                    context: context, saveImmediately: false)
            unsaved += 1
            if unsaved >= 10 {
                try? context.save()
                unsaved = 0
            }
            return Outcome(title: result.job.title, sourceName: result.job.sourceName,
                           fresh: merged.fresh, error: nil)
        } else {
            return Outcome(title: result.job.title, sourceName: result.job.sourceName,
                           fresh: 0, error: result.error ?? "unknown error")
        }
    }

    func flush() {
        if unsaved > 0 {
            try? context.save()
            unsaved = 0
        }
    }
}

/// Coordinates library-level operations: adding entries from a source,
/// refreshing chapter lists, and recording reading progress.
///
/// Source-agnostic by design: it works with `SourceEntry` / `SourceChapter`
/// values and the `SourceManager` registry, so a novel and a manga go through
/// exactly the same code path.
@Observable
@MainActor
final class LibraryManager {

    /// Told when a chapter flips to read, so tracked titles stay in step.
    @ObservationIgnored weak var tracking: TrackingManager?

    /// Whether a library-wide update is in progress.
    private(set) var isUpdating = false

    /// What the current (or most recent) library update is doing, for the UI.
    /// Stays set after the update ends so its outcome can be read; the user
    /// dismisses it.
    private(set) var updateProgress: LibraryUpdateProgress?
    private var updateCancelRequested = false

    /// Stop starting new titles. Ones already being fetched finish.
    func cancelUpdate() {
        guard isUpdating else { return }
        updateCancelRequested = true
        updateProgress?.isCancelling = true
    }

    func dismissUpdateSummary() {
        if !isUpdating { updateProgress = nil }
    }

    // MARK: - Progress persistence
    //
    // Reading position changes on every scroll tick (the reader debounces its
    // JS scroll listener by 300 ms). Saving each one costs a SQLite write plus
    // a store-change notification, and that notification re-runs every `@Query`
    // in the app — the library's entry query included, which re-sorts and
    // re-walks chapter arrays. Doing that four times a second while the user
    // scrolls is what made the reader stutter.
    //
    // So: mutate the model in memory immediately (the UI stays live) and let
    // the write coalesce. `flushProgress` is called when the reader closes or
    // the app backgrounds, so the window where a crash loses position is the
    // same few seconds the reader was already tolerant of.

    /// Minimum gap between two progress writes.
    static let progressSaveInterval: Duration = .seconds(3)
    static let deferredSaveInterval: Duration = .seconds(30)

    /// Timestamp bump inside `History` / `Entry` is only useful at a coarse
    /// granularity — nothing reads it below a minute.
    private static let timestampRefreshInterval: TimeInterval = 60

    /// Bumped after every progress write lands. Screens that show chapter
    /// progress and sit under the reader watch it, because the reader's last
    /// write happens after it has already started closing.
    private(set) var progressSaveCount = 0

    private var pendingProgressSave = false
    private var progressSaveTask: Task<Void, Never>?
    private var lastProgressSave = Date.distantPast

    // MARK: - Adding and removing

    /// Add an entry to the library, or return the existing row.
    ///
    /// Chapters already known for the entry are left untouched, so re-adding a
    /// removed entry keeps its read state.
    @discardableResult
    func addToLibrary(
        entry sourceEntry: SourceEntry,
        chapters: [SourceChapter],
        context: ModelContext
    ) -> Entry {
        let sourceKey = sourceEntry.sourceKey
        let url = sourceEntry.url
        let predicate = #Predicate<Entry> { $0.sourceKey == sourceKey && $0.url == url }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try? context.fetch(descriptor).first {
            existing.inLibrary = true
            if existing.chapters.isEmpty {
                insertChapters(chapters, into: existing, context: context)
                if !chapters.isEmpty { existing.lastUpdate = .now }
            }
            try? context.save()
            return existing
        }

        let entry = Entry(
            kind: sourceEntry.kind,
            sourceKey: sourceEntry.sourceKey,
            url: sourceEntry.url,
            title: sourceEntry.title
        )
        entry.thumbnailURL = sourceEntry.thumbnailURL
        entry.author = sourceEntry.author
        entry.artist = sourceEntry.artist
        entry.summary = sourceEntry.description
        entry.genres = sourceEntry.genres
        entry.status = sourceEntry.status
        entry.inLibrary = true
        entry.dateAdded = .now
        context.insert(entry)

        insertChapters(chapters, into: entry, context: context)
        // Chapters that came with the add count as a fetch, so opening the
        // entry later does not refetch what the user just saw.
        if !chapters.isEmpty { entry.lastUpdate = .now }
        try? context.save()
        return entry
    }

    /// Remove an entry from the library but keep its chapters and history.
    func removeFromLibrary(entry: Entry, context: ModelContext) {
        entry.inLibrary = false
        try? context.save()
    }

    private func insertChapters(
        _ chapters: [SourceChapter],
        into entry: Entry,
        context: ModelContext
    ) {
        // The boundary again: `sourceOrder` counts from the oldest chapter, so an
        // entry added straight from a browse list stores the same order a sync
        // would have written.
        for (index, sourceChapter) in ChapterOrder.normalized(chapters).enumerated() {
            let number = sourceChapter.chapterNumber > -1
                ? sourceChapter.chapterNumber
                : ChapterRecognition.parseChapterNumber(sourceChapter.name, mangaTitle: entry.title)
            let chapter = Chapter(
                url: sourceChapter.url,
                name: sourceChapter.name,
                chapterNumber: number,
                sourceOrder: index
            )
            chapter.scanlator = sourceChapter.scanlator
            chapter.dateUpload = sourceChapter.dateUpload
            chapter.entry = entry
            context.insert(chapter)
        }
    }

    // MARK: - Reading state

    /// Record that a chapter was opened.
    ///
    /// Opening is not reading: `read` only flips once the reader reaches the
    /// end, which is why this only touches history and the "recently read"
    /// timestamp.
    func recordHistory(entry: Entry, chapter: Chapter, context: ModelContext) {
        // Incognito: no history row, and `lastReadAt` stays put so the library
        // sort cannot reveal that this was opened.
        guard !IncognitoMode.shared.isOn else { return }

        let chapterURL = chapter.url
        let predicate = #Predicate<History> { $0.chapterURL == chapterURL }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try? context.fetch(descriptor).first {
            existing.lastRead = .now
        } else {
            let history = History(chapterURL: chapter.url)
            history.chapter = chapter
            context.insert(history)
        }

        entry.lastReadAt = .now
        scheduleProgressSave(context, deferred: true)
    }

    /// Record how far the user has read into a chapter.
    ///
    /// Reaching `Chapter.finishedThreshold` marks the chapter read; a finished
    /// chapter keeps 100% and reopens from the top, and rereading it never
    /// moves it back to unread.
    func recordReadingPosition(
        chapter: Chapter,
        paragraphIndex: Int,
        percent: Int,
        context: ModelContext
    ) {
        ChapterDownloadManager.shared.chapterOpened(chapter)
        let incognito = IncognitoMode.shared.isOn
        let finished = chapter.read && chapter.progress >= 100
        let clamped = min(max(percent, 0), 100)
        let wasRead = chapter.read

        if finished {
            chapter.paragraphIndex = clamped >= Int(Chapter.finishedThreshold) ? 0 : paragraphIndex
        } else if clamped >= Int(Chapter.finishedThreshold) {
            // Incognito keeps the position but never flips the chapter to read,
            // so the library counts, the read fan-out and the tracker all stay
            // untouched.
            if !incognito { chapter.read = true }
            chapter.progress = 100
            chapter.paragraphIndex = 0
        } else {
            chapter.progress = Double(clamped)
            chapter.paragraphIndex = paragraphIndex
        }

        // A chapter flipping to read is the one change the library cares about.
        if chapter.read != wasRead {
            LibraryChapterCounts.shared.invalidate()
            if chapter.read {
                ChapterTwins.fanOut(from: chapter, read: true)
                ChapterDownloadManager.shared.chapterFinished(chapter)
                if let entry = chapter.entry { tracking?.readStateChanged(entry: entry) }
            }
        }

        if !incognito { touchTimestamps(chapter) }
        scheduleProgressSave(context)
    }

    /// Refresh the "recently read" timestamps, but not on every scroll tick.
    ///
    /// `Entry.lastReadAt` is a cached column that the library sorts on, so
    /// rewriting it 4×/second invalidates the library query for no benefit:
    /// nothing distinguishes two reads one second apart.
    private func touchTimestamps(_ chapter: Chapter) {
        let now = Date.now
        if let history = chapter.history {
            if now.timeIntervalSince(history.lastRead) > Self.timestampRefreshInterval {
                history.lastRead = now
            }
        }
        if let entry = chapter.entry {
            if let lastReadAt = entry.lastReadAt,
               now.timeIntervalSince(lastReadAt) <= Self.timestampRefreshInterval {
                return
            }
            entry.lastReadAt = now
        }
    }

    /// Coalesce a progress write. Safe to call as often as the reader likes.
    ///
    /// `deferred` is for readers that turn a page every few seconds. The
    /// "first write after idle lands immediately" rule below fits a scroll
    /// stream but not page-by-page reading: every turn is a fresh idle stretch,
    /// so every turn saved, and each save re-runs every `@Query` on the main
    /// thread. Deferred writes wait out `deferredSaveInterval` instead; the
    /// reader still flushes on close, on a chapter change and on backgrounding.
    private func scheduleProgressSave(_ context: ModelContext, deferred: Bool = false) {
        pendingProgressSave = true
        guard progressSaveTask == nil else { return }

        // First write after an idle stretch lands immediately, so closing the
        // reader right after opening it still persists.
        if !deferred, Date.now.timeIntervalSince(lastProgressSave) >= 3 {
            flushProgress(context: context)
            return
        }

        let interval = deferred ? Self.deferredSaveInterval : Self.progressSaveInterval
        progressSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.progressSaveTask = nil
            self.flushProgress(context: context)
        }
    }

    /// Write any pending reading progress now.
    ///
    /// Called when a reader closes and when the app backgrounds, so the
    /// coalescing window never outlives the screen that produced it.
    func flushProgress(context: ModelContext) {
        progressSaveTask?.cancel()
        progressSaveTask = nil
        guard pendingProgressSave else { return }
        pendingProgressSave = false
        lastProgressSave = .now
        try? context.save()
        progressSaveCount += 1
    }

    /// Record a manga page turn.
    ///
    /// Separate from `recordReadingPosition` because a manga chapter is measured
    /// in pages, not paragraphs, and "finished" means the reader reached 95% or the
    /// last page.
    func recordMangaProgress(
        chapter: Chapter,
        pageIndex: Int,
        pageCount: Int,
        context: ModelContext
    ) {
        ChapterDownloadManager.shared.chapterOpened(chapter)
        let incognito = IncognitoMode.shared.isOn
        let update = MangaProgress.update(pageIndex: pageIndex, pageCount: pageCount)
        let wasRead = chapter.read

        chapter.lastPageRead = update.lastPageRead
        chapter.pagesLeft = update.pagesLeft
        chapter.progress = update.progress
        if update.finished, !incognito {
            chapter.read = true
        }

        if chapter.read != wasRead {
            LibraryChapterCounts.shared.invalidate()
            if chapter.read {
                ChapterTwins.fanOut(from: chapter, read: true)
                ChapterDownloadManager.shared.chapterFinished(chapter)
                if let entry = chapter.entry { tracking?.readStateChanged(entry: entry) }
            }
        }

        if !incognito { touchTimestamps(chapter) }
        scheduleProgressSave(context, deferred: true)
    }

    // MARK: - Network state

    /// Whether the current connection is cellular.
    private func isCellularConnection() -> Bool {
        NetworkMonitor.shared.isCellular()
    }

    // MARK: - Library updates

    /// Refresh library entries from their sources.
    ///
    /// `category` limits the run to that category's titles and ignores its
    /// "exclude from updates" flag; without it, titles in excluded categories
    /// are skipped (`LibraryUpdateScope`).
    ///
    /// The work runs in its own task. A caller can be cancelled mid-run: the
    /// pull-to-refresh task is cancelled by SwiftUI as soon as the first
    /// results change the library and the view re-renders, which used to fail
    /// every fetch after the first few with `CancellationError`. Cancelling the
    /// caller now only stops waiting; `cancelUpdate()` is what stops the run.
    func updateLibrary(context: ModelContext, sourceManager: SourceManager, automatic: Bool = false,
                       category: String? = nil) async {
        guard !isUpdating else { return }
        await Task { @MainActor in
            await self.performUpdate(context: context, sourceManager: sourceManager,
                                     automatic: automatic, category: category)
        }.value
    }

    private func performUpdate(context: ModelContext, sourceManager: SourceManager, automatic: Bool,
                               category: String?) async {
        guard !isUpdating else { return }

        if UserDefaults.standard.object(forKey: "general.updateOnWifiOnly") as? Bool ?? true {
            await NetworkMonitor.shared.waitForPath()
            if !NetworkMonitor.shared.isOnWiFi() {
                print("📶 Library update skipped: Wi-Fi only setting is enabled and current network is cellular.")
                var skipped = LibraryUpdateProgress(total: 0, automatic: automatic)
                skipped.note = "Skipped: updates are set to Wi-Fi only and this device is not on Wi-Fi."
                skipped.finishedAt = .now
                updateProgress = skipped
                return
            }
        }

        isUpdating = true
        updateCancelRequested = false
        defer {
            isUpdating = false
            updateProgress?.finishedAt = .now
        }

        let predicate = #Predicate<Entry> { $0.inLibrary }
        guard let entries = try? context.fetch(FetchDescriptor(predicate: predicate)),
              !entries.isEmpty
        else { return }

        // Fetch sources concurrently (network-bound, 4 at a time) and apply each
        // result to the store off the main actor, so new chapters arrive without
        // stalling the UI, touch, or active readers.
        var pending: [UpdateWork] = []
        var notInstalled = 0
        let skipUnread = UserDefaults.standard.bool(forKey: "updates.skipUnread")
        let skipCompleted = UserDefaults.standard.bool(forKey: "updates.skipCompleted")
        let excludedCategories: Set<String>
        if category == nil {
            let all = (try? context.fetch(FetchDescriptor<Category>())) ?? []
            excludedCategories = Set(all.filter { CategoryFlags.isExcluded($0.flags) }.map(\.name))
        } else {
            excludedCategories = []
        }
        for entry in entries where !entry.isLocal {
            guard !Task.isCancelled else { return }
            if category != nil || !excludedCategories.isEmpty {
                guard LibraryUpdateScope.includes(categories: entry.categories.map(\.name),
                                                  excluded: excludedCategories, only: category) else { continue }
            }
            // `hasUnread` faults in every chapter of the entry on the main actor,
            // so only ask when the answer can change the outcome.
            guard LibraryUpdatePolicy.permits(strategy: entry.updateStrategy, hasFetched: entry.lastUpdate != nil,
                status: entry.status, hasUnread: skipUnread ? entry.hasUnread : false,
                skipUnread: skipUnread, skipCompleted: skipCompleted) else { continue }
            guard let source = sourceManager.source(forKey: entry.sourceKey) else {
                notInstalled += 1
                continue
            }
            let job = UpdateJob(
                id: entry.persistentModelID,
                sourceKey: entry.sourceKey,
                url: entry.url,
                kind: entry.kind,
                title: entry.title,
                sourceName: source.name
            )
            pending.append(UpdateWork(source: source, job: job))
        }
        var progress = LibraryUpdateProgress(total: pending.count, automatic: automatic)
        progress.notInstalled = notInstalled
        updateProgress = progress
        guard !pending.isEmpty else { return }

        let merger = LibraryUpdateMerger(container: context.container)

        await withTaskGroup(of: UpdateResult.self) { group in
            let maxConcurrent = 4
            var queue = pending[...]

            @MainActor func submit(_ work: UpdateWork) {
                updateProgress?.inFlight.append(work.job.title)
                group.addTask {
                    let entry = SourceEntry(
                        sourceKey: work.job.sourceKey,
                        kind: work.job.kind,
                        url: work.job.url,
                        title: work.job.title
                    )
                    do {
                        try Task.checkCancellation()
                        let details = try await work.source.details(entry)
                        try Task.checkCancellation()
                        let chapters = try await work.source.chapters(entry)
                        return UpdateResult(job: work.job, details: details, chapters: chapters, error: nil)
                    } catch {
                        return UpdateResult(job: work.job, details: nil, chapters: [],
                                            error: error.localizedDescription)
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, queue.count) {
                submit(queue.removeFirst())
            }
            while let result = await group.next() {
                let outcome = await merger.merge(result)
                updateProgress?.inFlight.removeAll { $0 == outcome.title }
                updateProgress?.completed += 1
                if let error = outcome.error {
                    print("Failed to update \(outcome.title): \(error)")
                    updateProgress?.failures.append(.init(
                        title: outcome.title, source: outcome.sourceName, message: error))
                } else {
                    updateProgress?.newChapters += outcome.fresh
                    if outcome.fresh > 0 { updateProgress?.titlesWithNewChapters += 1 }
                }

                if updateCancelRequested || Task.isCancelled {
                    queue.removeAll()
                } else if !queue.isEmpty {
                    submit(queue.removeFirst())
                }
            }
        }

        await merger.flush()
        LibraryChapterCounts.shared.invalidate()
        if updateCancelRequested { updateProgress?.wasCancelled = true }
    }

    /// Merge source metadata and a chapter list into a stored entry.
    ///
    /// Metadata is overwritten from the source; the chapter list goes through
    /// `ChapterSourceSync`, which matches by URL, keeps read state, stamps new
    /// chapters for Updates and prunes chapters the source dropped.
    @discardableResult
    nonisolated static func applyUpdate(
        _ entry: Entry,
        details: SourceEntry,
        chapters: [SourceChapter],
        context: ModelContext,
        saveImmediately: Bool = true
    ) -> ChapterSyncResult {
        if !details.title.isEmpty { entry.title = details.title }
        if let thumbnail = details.thumbnailURL { entry.thumbnailURL = thumbnail }
        if let summary = details.description, !summary.isEmpty { entry.summary = summary }
        if let author = details.author { entry.author = author }
        if let artist = details.artist { entry.artist = artist }
        if !details.genres.isEmpty { entry.genres = details.genres }
        entry.status = details.status
        entry.lastUpdate = .now

        let result = ChapterSourceSync.merge(chapters, into: entry, context: context)
        Task { @MainActor in
            LibraryChapterCounts.shared.invalidate()
        }

        if saveImmediately {
            try? context.save()
        }
        return result
    }

    @discardableResult
    func applyUpdate(
        _ entry: Entry,
        details: SourceEntry,
        chapters: [SourceChapter],
        context: ModelContext,
        saveImmediately: Bool = true
    ) -> ChapterSyncResult {
        Self.applyUpdate(entry, details: details, chapters: chapters, context: context, saveImmediately: saveImmediately)
    }

    /// Mark every "new chapter" badge as seen.
    ///
    /// Runs on a background context: on a large library, touching every chapter
    /// on the main thread froze the app. A background save does not refresh the
    /// Updates `@Query` on its own, so the screen hides the rows it showed (see
    /// `UpdatesView.clearAll`).
    func clearUpdates(container: ModelContainer) async {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let predicate = #Predicate<Chapter> { $0.dateFetch != nil }
            guard let chapters = try? context.fetch(FetchDescriptor(predicate: predicate)) else { return }
            for chapter in chapters { chapter.dateFetch = nil }
            try? context.save()
        }.value
        LibraryChapterCounts.shared.invalidate()
    }
}

// MARK: - Update progress

/// A snapshot of a library update, shown by `LibraryUpdateBanner`.
struct LibraryUpdateProgress: Equatable {
    struct Failure: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let source: String
        let message: String
    }

    var total: Int
    var automatic: Bool
    var completed = 0
    var newChapters = 0
    var titlesWithNewChapters = 0
    var failures: [Failure] = []
    /// Titles being fetched right now.
    var inFlight: [String] = []
    /// Library titles skipped because their source is not installed.
    var notInstalled = 0
    var isCancelling = false
    var wasCancelled = false
    var note: String?
    let startedAt = Date()
    var finishedAt: Date?

    var isFinished: Bool { finishedAt != nil }
    var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

// MARK: - Library chapter counts

/// Cached per-entry chapter totals for the library.
///
/// `Entry.unreadCount` and `Entry.totalChapterCount` resolve the `chapters`
/// relationship, which faults every chapter row for that entry. A grid cell
/// asks for both, three times over (`totalChapterCount`, `unreadCount > 0`,
/// `unreadCount`), and sorting by unread asks for them for every entry. With a
/// few hundred books that is tens of thousands of row faults per body pass —
/// the single largest cost in library scrolling and sorting.
///
/// This counts with `fetchCount` (a SQL `COUNT`, not a materialised array) on a
/// background context, caches the answer per entry, and lets cells read it
/// synchronously. Nothing is stored on the model, so the count cannot drift
/// from the chapters themselves — it is only ever a cached read of them.
@MainActor
final class LibraryChapterCounts {

    static let shared = LibraryChapterCounts()

    struct Counts: Equatable, Sendable {
        var total = 0
        var unread = 0
        /// Chapters whose download finished and is on disk.
        var downloaded = 0
        /// Unread chapters the last refresh added and Updates has not been
        /// cleared of. Filled only when `loaded` has `.newCount`.
        var new = 0
        /// Newest `dateUpload` and `dateFetch`. Filled only when `loaded`
        /// has `.dates`.
        var latestUpload: Date?
        var latestFetch: Date?
        /// Which optional fields were computed. Each is extra queries per
        /// entry, so a caller asks only for what it shows or sorts by.
        var loaded: Extras = []
    }

    struct Extras: OptionSet, Sendable {
        let rawValue: Int
        static let dates = Extras(rawValue: 1)
        static let newCount = Extras(rawValue: 2)
    }

    /// How long a count is trusted. Short enough that finishing a chapter shows
    /// up once the reader closes, long enough that scrolling never re-queries.
    private let ttl: TimeInterval = 5

    private var cache: [PersistentIdentifier: (counts: Counts, at: Date)] = [:]
    private var inFlight: [PersistentIdentifier: Task<Counts, Never>] = [:]
    /// Bumped by `invalidate()` so a count that started before a change cannot
    /// write a stale answer back into the cache.
    private var generation = 0
    /// Every extra any caller has asked for. Folded into each computation so
    /// two views asking for different extras do not keep evicting each other.
    private var wanted: Extras = []

    private init() {
        // Hiding or showing a scanlator changes every count at once.
        NotificationCenter.default.addObserver(
            forName: ChapterVisibility.didChange, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }
    }

    /// Synchronous read for body code. `nil` means "not known yet".
    func cached(_ id: PersistentIdentifier) -> Counts? {
        guard let entry = cache[id],
              Date.now.timeIntervalSince(entry.at) < ttl
        else { return nil }
        return entry.counts
    }

    func invalidate() {
        generation &+= 1
        cache.removeAll()
    }

    func counts(for entry: Entry, container: ModelContainer, extras: Extras = []) async -> Counts {
        let id = entry.persistentModelID
        wanted.formUnion(extras)
        if let cached = cached(id), cached.loaded.isSuperset(of: extras) { return cached }
        if let running = inFlight[id] {
            let counts = await running.value
            if counts.loaded.isSuperset(of: extras) { return counts }
        }
        let computing = wanted

        // Match on the entry's identity: comparing url + sourceKey joined Entry per
        // chapter and was ~4x slower (300 books: 10.8 s vs 2.5 s).
        let entryID = id
        let startGeneration = generation
        let completedState = DownloadState.completed

        let task = Task.detached(priority: .userInitiated) { () -> Counts in
            let context = ModelContext(container)
            do {
                // Hidden chapters do not exist: every count below skips them.
                let inEntry = #Predicate<Chapter> {
                    $0.entry?.persistentModelID == entryID && !$0.hidden
                }
                let unreadInEntry = #Predicate<Chapter> {
                    $0.entry?.persistentModelID == entryID && !$0.hidden && !$0.read
                }
                let downloadedInEntry = #Predicate<Chapter> {
                    $0.entry?.persistentModelID == entryID && !$0.hidden
                        && $0.downloadItem?.state == completedState
                }
                let total = try context.fetchCount(FetchDescriptor<Chapter>(predicate: inEntry))
                let unread = try context.fetchCount(FetchDescriptor<Chapter>(predicate: unreadInEntry))
                let downloaded = try context.fetchCount(FetchDescriptor<Chapter>(predicate: downloadedInEntry))
                var counts = Counts(total: total, unread: unread, downloaded: downloaded)
                if computing.contains(.newCount) {
                    let newInEntry = #Predicate<Chapter> {
                        $0.entry?.persistentModelID == entryID
                            && !$0.hidden && !$0.read && $0.dateFetch != nil
                    }
                    counts.new = try context.fetchCount(FetchDescriptor<Chapter>(predicate: newInEntry))
                    counts.loaded.insert(.newCount)
                }
                if computing.contains(.dates) {
                    var upload = FetchDescriptor<Chapter>(
                        predicate: #Predicate<Chapter> {
                            $0.entry?.persistentModelID == entryID && !$0.hidden && $0.dateUpload != nil
                        },
                        sortBy: [SortDescriptor(\Chapter.dateUpload, order: .reverse)]
                    )
                    upload.fetchLimit = 1
                    var fetch = FetchDescriptor<Chapter>(
                        predicate: #Predicate<Chapter> {
                            $0.entry?.persistentModelID == entryID && !$0.hidden && $0.dateFetch != nil
                        },
                        sortBy: [SortDescriptor(\Chapter.dateFetch, order: .reverse)]
                    )
                    fetch.fetchLimit = 1
                    counts.latestUpload = try context.fetch(upload).first?.dateUpload
                    counts.latestFetch = try context.fetch(fetch).first?.dateFetch
                    counts.loaded.insert(.dates)
                }
                return counts
            } catch {
                return Counts()
            }
        }

        inFlight[id] = task
        let counts = await task.value
        inFlight[id] = nil
        if startGeneration == generation {
            cache[id] = (counts, .now)
        }
        return counts
    }
}

// MARK: - Shared network path monitor

/// Singleton wrapper around NWPathMonitor. Creating a monitor per check
/// (plus a semaphore wait) blocks the caller and spins up threads;
/// share one long-lived monitor instead.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lnreader.network-monitor")
    private let lock = NSLock()
    private var _isCellular = false
    private var _isOnWiFi = false
    private var _isConnected = false
    private var _hasPath = false
    private var started = false

    private init() {}

    private func ensureStarted() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._isCellular = path.usesInterfaceType(.cellular)
            self._isOnWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            self._isConnected = path.status == .satisfied
            self._hasPath = true
            self.lock.unlock()
            NotificationCenter.default.post(name: Notification.Name("LNReaderNetworkChanged"), object: nil)
        }
        monitor.start(queue: queue)
    }

    func isCellular() -> Bool {
        ensureStarted()
        lock.lock()
        defer { lock.unlock() }
        return _isCellular
    }

    func isOnWiFi() -> Bool {
        ensureStarted()
        lock.lock(); defer { lock.unlock() }
        return _isOnWiFi
    }
    func isConnected() -> Bool {
        ensureStarted(); lock.lock(); defer { lock.unlock() }; return _isConnected
    }
    private func hasPath() -> Bool {
        lock.lock(); defer { lock.unlock() }; return _hasPath
    }
    func waitForPath() async {
        ensureStarted()
        for _ in 0..<20 {
            if hasPath() || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
