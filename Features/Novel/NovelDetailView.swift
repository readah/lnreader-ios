// NovelDetailView.swift
// Entry detail screen supporting both library and browse modes.
//
// One view for both kinds: the header, metadata and chapter list are shared,
// and kind-specific sections (manga reader entry, downloads) hang off the same
// `Entry` once the manga reader lands.

import SwiftData
import SwiftUI

struct NovelDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(ReaderRouter.self) private var readerRouter
    @Environment(TrackingManager.self) private var tracking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// Stored entry, when opened from the library or from a search hit that is
    /// already in the library.
    let entry: Entry?
    /// Source-side entry, when opened from browse/search.
    let sourceEntry: SourceEntry?
    let sourceKey: String
    /// Swap this screen for another entry, supplied by the stack that pushed it.
    /// `nil` where there is nothing to swap (a browse result).
    let onReplace: ((Entry) -> Void)?

    @Namespace private var chapterTransition
    @State private var localEntry: Entry? = nil
    @State private var details: SourceEntry?
    @State private var sourceChapters: [SourceChapter] = []
    @State private var isLoading = true
    @State private var showFullDescription = false
    @State private var selectedRange: ChapterRange = .progress
    @State private var selectedFilter: ChapterFilter = .all
    @State private var errorMessage: String?
    /// A manual refetch is running; the page stays up while it does.
    @State private var isRefetching = false
    @State private var refetchError: String?
    /// When this screen last fetched from the source, for entries with no
    /// stored `lastUpdate` (a browse result).
    @State private var fetchedAt: Date?

    // Search + navigation state
    @State private var chapterSearch = ""
    @State private var showTracker = false
    @State private var showMigrate = false
    @State private var showWebView = false
    /// The entry a migration produced, waiting for the sheet to finish closing.
    @State private var migratedInto: Entry?
    /// Chapter order for the detail list and the full directory (`ChapterListView` owns the menu).
    @AppStorage(ChapterOrder.ascendingKey) private var chaptersAscending = false
    @State private var navigateToChapter: ChapterDisplay? = nil
    @State private var allChapters: [ChapterDisplay] = []
    /// `allChapters` after scanlator rules, in newest-first display order.
    ///
    /// Kept as state, not a computed property: the sort compares localized
    /// titles and the scanlator pass rebuilds the array, so recomputing it on
    /// every body evaluation meant two full passes over every chapter each time
    /// a chip, a search keystroke, or a scroll tick re-rendered the screen.
    @State private var orderedChapters: [ChapterDisplay] = []
    /// The chapter opened most recently, from history; fetched with the chapters.
    @State private var lastOpenedPath: String?
    /// The chapter "Continue reading" opens, also shown on the button.
    /// Rebuilt with `orderedChapters` so the body never walks relationships.
    @State private var resumeChapter: ChapterDisplay?
    @State private var showAudioDownloads = false
    /// Hold-to-select state for the chapter list; the bar pins to this screen.
    @State private var chapterSelection = ChapterSelection()
    /// True while the entry is being written to the library.
    @State private var isAddingToLibrary = false
    /// Scanlator priority for this entry, loaded from its own defaults key.
    @State private var scanlatorSettings: ScanlatorSettings
    /// Cover tint, when the user turned it on in Settings › Appearance.
    @AppStorage(AppearanceTint.enabledKey) private var tintDetails = false
    @AppStorage(AppearanceTint.strengthKey) private var tintStrength = AppearanceTint.defaultStrength
    @State private var coverTint: Color?

    // MARK: - Initializers

    /// View a saved library entry.
    ///
    /// - Parameter onReplace: how the stack that pushed this screen swaps it for
    ///   another entry. Migration uses it: the old entry leaves the library, so
    ///   showing the new one *in its place* keeps Back pointing at the library
    ///   instead of at a book that is no longer in it. A stack that does not pass
    ///   one gets the old behaviour, a plain pop.
    init(entry: Entry, onReplace: ((Entry) -> Void)? = nil) {
        self.entry = entry
        self.sourceEntry = nil
        self.sourceKey = entry.sourceKey
        self.onReplace = onReplace
        self._localEntry = State(initialValue: entry)
        self._scanlatorSettings = State(
            initialValue: ScanlatorSettings(key: "\(entry.sourceKey)::\(entry.url)")
        )
    }

    /// View an entry discovered from browse/search.
    init(sourceEntry: SourceEntry) {
        self.entry = nil
        self.sourceEntry = sourceEntry
        self.sourceKey = sourceEntry.sourceKey
        self.onReplace = nil
        self._localEntry = State(initialValue: nil)
        self._scanlatorSettings = State(
            initialValue: ScanlatorSettings(key: "\(sourceEntry.sourceKey)::\(sourceEntry.url)")
        )
    }

    var body: some View {
        NovelDetailScrollView(
            content: VStack(spacing: 0) {
                NovelHeaderView(
                    transitionNamespace: chapterTransition,
                    name: displayTitle,
                    author: displayAuthor,
                    artist: localEntry?.displayArtist ?? details?.artist,
                    cover: displayCover,
                    status: localEntry?.status ?? details?.status ?? .unknown,
                    source: sourceName,
                    hasStartedReading: hasStartedReading,
                    isFinished: isFinished,
                    continueChapterName: resumeChapter?.name,
                    canStartReading: !allChapters.isEmpty && !isFinished,
                    onContinueReading: continueReading
                ) {
                    EntryActionBar(
                        entry: localEntry,
                        isManga: isManga,
                        isAddingToLibrary: isAddingToLibrary,
                        track: localEntry.flatMap { tracking.aniListTrack(for: $0) },
                        onToggleLibrary: toggleLibrary,
                        onTracking: { showTracker = true },
                        onAudio: { showAudioDownloads = true }
                    )
                }
                .padding(.bottom, 16)

                if isLoading && localEntry == nil {
                    ProgressView("Loading entry details…")
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                } else if let error = errorMessage {
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    NovelInfoSection(
                        summary: localEntry?.displaySummary ?? details?.description,
                        genres: displayGenres,
                        showFullDescription: $showFullDescription
                    )

                    Divider()
                        .padding(.horizontal)
                        .padding(.vertical, 20)

                    ChapterListView(
                        entry: localEntry,
                        allChapters: allChapters,
                        visibleChapters: orderedChapters,
                        chapters: pagedChapters,
                        totalCount: orderedChapters.count,
                        filteredCount: filteredChapters.count,
                        showsAllChapters: showsAllChapters,
                        scanlatorSettings: scanlatorSettings,
                        sourceKey: sourceKey,
                        isLoading: isLoading,
                        selection: localEntry == nil ? nil : chapterSelection,
                        selectedRange: $selectedRange,
                        selectedFilter: $selectedFilter,
                        searchText: $chapterSearch,
                        fetchStatus: fetchStatus
                    )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                hideKeyboard()
            }
        )
        .chapterSelectionToolbar(
            selection: chapterSelection, entry: localEntry,
            ordered: pagedChapters, allChapters: allChapters, sourceKey: sourceKey)
        // `allChapters` is a snapshot of `ChapterDisplay` values, so a read-state
        // change has to be rebuilt from the store before the rows can show it.
        .onReceive(NotificationCenter.default.publisher(for: .lnreaderChapterReadChanged)) { _ in
            refreshChapters()
        }
        .onReceive(NotificationCenter.default.publisher(for: ChapterVisibility.didChange)) { _ in
            refreshChapters()
        }
        // One colour from the cover, reused for the page, the chapter card and
        // the chapter list's buttons. Recomputed only when the cover changes.
        .task(id: tintDetails ? (displayCover ?? "") : "") {
            coverTint = tintDetails ? await CoverTint.color(for: displayCover) : nil
        }
        .environment(\.coverTint, coverTint)
        .background {
            if let coverTint {
                coverTint.opacity(tintStrength * 0.55).ignoresSafeArea()
            }
        }
        .onDisappear { chapterSelection.end() }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Both are visible buttons. Migrate used to be the only item in a
                // `…` menu, which hid the one action a broken source makes you
                // look for.
                if let localEntry, localEntry.inLibrary, !localEntry.isLocal {
                    migrateButton
                }
                if webURL != nil {
                    webViewButton
                }
                // Refresh is a toolbar button, not pull to refresh: pulling down
                // dismisses this screen.
                if canRefetch {
                    refreshButton
                }
            }
        }
        // The sheet reports the new entry; this screen closes it, and only once the
        // sheet is gone does it ask the stack to show that entry in its place. The
        // entry on screen is no longer in the library, so it is not worth going
        // back to.
        .sheet(isPresented: $showMigrate, onDismiss: {
            guard let newEntry = migratedInto else { return }
            migratedInto = nil
            if let onReplace { onReplace(newEntry) } else { dismiss() }
        }) {
            if let localEntry {
                MigrateEntrySheet(entry: localEntry) { newEntry in
                    migratedInto = newEntry
                    showMigrate = false
                }
            }
        }
        .sheet(isPresented: $showWebView) {
            if let webURL { EntryWebView(url: webURL, title: displayTitle) }
        }
        .sheet(isPresented: $showTracker) {
            if let localEntry { TrackerSheet(entry: localEntry) }
        }
        .sheet(isPresented: $showAudioDownloads) {
            BookAudioDownloadsView(
                bookId: TTSBookIdentity.make(pluginId: sourceKey, novelPath: bookPath),
                bookTitle: displayTitle,
                sourceKey: sourceKey,
                entryURL: bookPath,
                chapters: allChapters.map { TTSChapterChoice($0) },
                coverURL: displayCover
            )
            // Applied to the sheet content directly: the sheet is chained after
            // the `.environment(\.coverTint,…)` above, so it does not inherit it.
            .environment(\.coverTint, coverTint)
        }
        // The reader is a full-screen window of its own; this screen only
        // decides which chapter to open.
        .onChange(of: navigateToChapter) { _, chapter in
            guard let chapter else { return }
            openReader(chapter)
            navigateToChapter = nil
        }
        .onAppear {
            syncLocalEntry()
            refreshChapters()
        }
        .onChange(of: entry) { refreshChapters() }
        // The reader is a full-screen cover, so this screen never disappears and
        // `onAppear` does not run again. Refresh once the reader has closed and
        // again when its closing write lands.
        .onChange(of: readerRouter.request == nil) { _, closed in
            if closed { refreshChapters() }
        }
        .onChange(of: libraryManager.progressSaveCount) {
            if readerRouter.request == nil { refreshChapters() }
        }
        .onChange(of: localEntry) { refreshChapters() }
        // Scanlator priority changes the merge/hide result, so the ordered list
        // has to be rebuilt — it is no longer a computed property.
        .onChange(of: scanlatorSettings.value) { rebuildOrderedChapters() }
        .task { await fetchDetails() }
        .alert("Couldn't refresh", isPresented: Binding(
            get: { refetchError != nil },
            set: { if !$0 { refetchError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refetchError ?? "")
        }
    }

    // MARK: - Fetch status

    /// Whether this entry has a source to fetch from (local books do not).
    private var canRefetch: Bool { sourceManager.source(forKey: sourceKey) != nil }

    private var lastFetched: Date? { fetchedAt ?? localEntry?.lastUpdate }

    /// When the list was last fetched, shown under the chapter count.
    private var fetchStatus: String? {
        if isRefetching { return "Refreshing…" }
        guard canRefetch else { return nil }
        guard let lastFetched else { return "Not fetched yet" }
        return "Updated \(lastFetched.formatted(.relative(presentation: .named)))"
    }

    /// Refetches details and chapters. Turns into the spinner while it runs,
    /// so the refresh shows where it was started.
    ///
    /// Migrate is its own button next to it; see docs/DETAIL_SCREEN.md.
    private var refreshButton: some View {
        Button {
            Task { await fetchDetails(force: true) }
        } label: {
            if isRefetching {
                ProgressView()
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .disabled(isRefetching)
        .accessibilityLabel(isRefetching ? "Refreshing" : "Refresh")
    }

    /// Move this entry to another source. Its own button rather than an item in a
    /// menu: it is what you come here for when a source breaks, and a menu with a
    /// single item is a door with one room behind it.
    private var migrateButton: some View {
        Button { showMigrate = true } label: {
            Label("Migrate to another source", systemImage: "arrow.triangle.swap")
        }
        .accessibilityLabel("Migrate to another source")
    }

    /// The entry's page on its site, when its source has one.
    private var webURL: URL? {
        guard !bookPath.isEmpty else { return nil }
        return sourceManager.source(forKey: sourceKey)?.webURL(bookPath)
    }

    /// Open the entry's page on its site, in the app, sharing the scraper's
    /// cookies. A visible button, like Migrate: it is the way to check what the
    /// site shows, or to clear a Cloudflare check, when the source misbehaves.
    private var webViewButton: some View {
        Button { showWebView = true } label: {
            Label("Open in web view", systemImage: "globe")
        }
        .accessibilityLabel("Open in web view")
    }

    // MARK: - Chapter Computation

    private var bookPath: String {
        localEntry?.url ?? sourceEntry?.url ?? ""
    }

    private func refreshChapters() {
        if let localEntry {
            let entryURL = localEntry.url
            let entrySourceKey = localEntry.sourceKey
            let container = modelContext.container

            Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                let predicate = #Predicate<Chapter> {
                    $0.entry?.url == entryURL && $0.entry?.sourceKey == entrySourceKey
                }
                var descriptor = FetchDescriptor<Chapter>(
                    predicate: predicate,
                    sortBy: [SortDescriptor(\.sourceOrder)]
                )
                descriptor.relationshipKeyPathsForPrefetching = []

                var lastOpened = FetchDescriptor<History>(
                    predicate: #Predicate {
                        $0.chapter?.entry?.url == entryURL && $0.chapter?.entry?.sourceKey == entrySourceKey
                    },
                    sortBy: [SortDescriptor(\.lastRead, order: .reverse)]
                )
                lastOpened.fetchLimit = 1

                do {
                    let fetched = try context.fetch(descriptor)
                    let mapped = fetched.map { ChapterDisplay(chapter: $0) }
                    let lastOpenedPath = (try? context.fetch(lastOpened))?.first?.chapterURL
                    await MainActor.run {
                        self.allChapters = mapped
                        self.lastOpenedPath = lastOpenedPath
                        self.rebuildOrderedChapters()
                    }
                } catch {
                    print("⚠️ Failed to fetch chapters on background context: \(error)")
                    await MainActor.run {
                        let mapped = localEntry.chapters.map { ChapterDisplay(chapter: $0) }
                        self.allChapters = ChapterOrder.oldestFirst(mapped)
                        self.rebuildOrderedChapters()
                    }
                }
            }
        } else {
            let kind = localEntry?.kind ?? sourceEntry?.kind ?? .novel
            let mapped = sourceChapters.enumerated().map {
                ChapterDisplay(
                    sourceChapter: $1,
                    position: $0,
                    sourceKey: sourceKey,
                    entryURL: sourceEntry?.url,
                    kind: kind
                )
            }
            self.allChapters = mapped
            rebuildOrderedChapters()
        }
    }

    /// Newest first: the source's own order, reversed.
    ///
    /// Sources list oldest first (`CatalogSource.chapters`, enforced by
    /// `ChapterOrder.normalized`), so `sourceOrder` counts from the oldest
    /// chapter and the list is that, reversed. `ChapterOrder` is the only place
    /// that decides this; the screen never sorts chapters itself.
    private func rebuildOrderedChapters() {
        // Merge and hide by scanlator before ordering, so the list shows what
        // the user actually asked for.
        // A saved entry carries the decision (`Chapter.hidden`); only a browse
        // result, which has no stored rows, still applies the rules itself.
        let base = localEntry != nil
            ? allChapters.filter { !$0.hidden }
            : ScanlatorRules.apply(scanlatorSettings.value, to: allChapters)
        let oldestFirst = ChapterOrder.oldestFirst(base)
        orderedChapters = ChapterOrder.newestFirst(base)
        resumeChapter = Self.resumeChapter(
            oldestFirst: oldestFirst,
            lastOpened: lastOpenedPath.flatMap { path in allChapters.first { $0.path == path } }
        )
    }

    /// Reopen the chapter opened last if it is unfinished; otherwise the first
    /// unread chapter after the latest one read, then the first unread one,
    /// then the newest.
    private static func resumeChapter(oldestFirst: [ChapterDisplay], lastOpened: ChapterDisplay?) -> ChapterDisplay? {
        if let lastOpened, lastOpened.unread { return lastOpened }
        if let latestRead = oldestFirst.lastIndex(where: { !$0.unread }),
           let next = oldestFirst[latestRead...].first(where: \.unread) {
            return next
        }
        return oldestFirst.first(where: \.unread) ?? oldestFirst.last
    }

    private var filteredChapters: [ChapterDisplay] {
        var result = orderedChapters
        switch selectedFilter {
        case .all: break
        case .unread: result = result.filter { $0.unread }
        case .downloaded: result = result.filter { $0.downloaded }
        case .bookmarked: result = result.filter { $0.bookmarked }
        }
        if !chapterSearch.isEmpty {
            let query = chapterSearch.trimmingCharacters(in: .whitespaces)
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.chapterNumber.map { String(Int($0)) } == query)
            }
        }
        return result
    }

    /// Manga sources report every chapter at once, so the list shows all of
    /// them. Novels keep the windowed preview: their sources paginate, and a
    /// 2000-chapter web novel should not render 2000 rows on the detail screen.
    private var showsAllChapters: Bool { isManga }

    private var isManga: Bool {
        (localEntry?.kind ?? sourceEntry?.kind ?? .novel) == .manga
    }

    /// `orderedChapters` is newest-first; the slicing below depends on that, so
    /// the oldest-first option flips only what it hands to the screen.
    private var pagedChapters: [ChapterDisplay] {
        let page = newestFirstPage
        return chaptersAscending ? page.reversed() : page
    }

    private var newestFirstPage: [ChapterDisplay] {
        let list = filteredChapters
        guard !list.isEmpty else { return [] }
        if showsAllChapters { return list }

        if !chapterSearch.isEmpty || selectedFilter != .all { return Array(list.prefix(50)) }
        switch selectedRange {
        case .first:
            // Oldest chapters — the end of a newest-first list.
            return Array(list.suffix(10))

        case .last:
            // Newest chapters.
            return Array(list.prefix(10))

        case .progress:
            // The list is newest-first, so the first started chapter is the
            // latest one; with nothing read yet, start at the oldest chapter.
            let targetIndex = list.firstIndex { !$0.unread || $0.isInProgress } ?? list.count - 1

            let totalCount = list.count
            let sliceSize = 11
            let halfSize = 5

            var start = targetIndex - halfSize
            var end = targetIndex + halfSize

            if start < 0 {
                start = 0
                end = min(sliceSize - 1, totalCount - 1)
            }
            if end >= totalCount {
                end = totalCount - 1
                start = max(0, end - sliceSize + 1)
            }

            return Array(list[start...end])
        }
    }

    // MARK: - Display Helpers

    private var displayTitle: String {
        localEntry?.displayTitle ?? details?.title ?? sourceEntry?.title ?? "Unknown"
    }

    private var displayAuthor: String? {
        localEntry?.displayAuthor ?? details?.author ?? sourceEntry?.author
    }

    private var displayCover: String? {
        localEntry?.displayThumbnailURL ?? details?.thumbnailURL ?? sourceEntry?.thumbnailURL
    }

    private var displayGenres: [String] {
        if let local = localEntry, !local.genres.isEmpty { return local.genres }
        if let details, !details.genres.isEmpty { return details.genres }
        return sourceEntry?.genres ?? []
    }

    private var sourceName: String {
        sourceManager.source(forKey: sourceKey)?.name ?? SourceKey.identifier(from: sourceKey)
    }

    /// Every visible chapter is read, so the hero button is disabled and says so.
    private var isFinished: Bool {
        localEntry != nil && !orderedChapters.isEmpty && !orderedChapters.contains { $0.unread }
    }

    private var hasStartedReading: Bool {
        localEntry != nil
            && (lastOpenedPath != nil || allChapters.contains { !$0.unread || $0.isInProgress })
    }

    // MARK: - Actions

    private func syncLocalEntry() {
        if localEntry == nil {
            let url = entry?.url ?? sourceEntry?.url ?? ""
            guard !url.isEmpty else { return }
            let entrySourceKey = sourceKey
            let predicate = #Predicate<Entry> { $0.url == url && $0.sourceKey == entrySourceKey }
            var descriptor = FetchDescriptor<Entry>(predicate: predicate)
            descriptor.fetchLimit = 1
            if let fetched = try? modelContext.fetch(descriptor).first {
                self.localEntry = fetched
            }
        }
    }

    /// Opening an entry never refetches one that already has stored chapters:
    /// the user decides, with Refresh. A fetch happens on its own only when
    /// there is nothing to show yet (a browse result, or a library entry that
    /// was never fetched). `force` is the Refresh button.
    private func fetchDetails(force: Bool = false) async {
        syncLocalEntry()
        refreshChapters()

        if !force, let stored = localEntry, stored.lastUpdate != nil {
            isLoading = false
            return
        }

        // `CatalogSource` covers both kinds: details and the chapter list are
        // shared, only the reader differs.
        guard force || details == nil, let source = sourceManager.source(forKey: sourceKey) else {
            isLoading = false
            return
        }
        if force {
            guard !isRefetching else { return }
            isRefetching = true
        }
        defer { isRefetching = false }

        let url = localEntry?.url ?? sourceEntry?.url ?? ""
        guard !url.isEmpty else {
            isLoading = false
            return
        }

        do {
            let entry = localEntry.map(Self.sourceEntry(from:))
                ?? sourceEntry
                ?? SourceEntry(sourceKey: sourceKey, kind: .novel, url: url, title: "")
            // Two independent requests: run them together so the screen is not
            // waiting on two round trips in series.
            async let pendingDetails = source.details(entry)
            async let pendingChapters = source.chapters(entry)
            let fetchedDetails = try await pendingDetails
            let chapters = try await pendingChapters

            details = fetchedDetails
            // The boundary: a source may list newest-first, `sourceOrder` may not.
            sourceChapters = ChapterOrder.normalized(chapters)
            fetchedAt = .now
            if let localEntry {
                libraryManager.applyUpdate(localEntry, details: fetchedDetails, chapters: chapters, context: modelContext)
            }
            isLoading = false
            refreshChapters()
        } catch {
            if force {
                refetchError = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// A stored entry has to be re-expressed as a source value to be refetched.
    private static func sourceEntry(from entry: Entry) -> SourceEntry {
        SourceEntry(
            sourceKey: entry.sourceKey,
            kind: entry.kind,
            url: entry.url,
            title: entry.title,
            thumbnailURL: entry.thumbnailURL,
            author: entry.author,
            artist: entry.artist,
            description: entry.summary,
            genres: entry.genres,
            status: entry.status
        )
    }

    private func toggleLibrary() {
        guard !isAddingToLibrary else { return }

        let morph = AppMotion.glassMorph(reduceMotion: reduceMotion)

        // Removing is local and instant. The flag flips inside the animation so
        // the action bar merges back into the library button.
        if let localEntry, localEntry.inLibrary {
            withAnimation(morph) {
                libraryManager.removeFromLibrary(entry: localEntry, context: modelContext)
            }
            return
        }

        // Adding has to work the moment the screen opens, not only after the
        // details request lands. A browse result already carries everything the
        // library row needs, so seed from it and let `fetchDetails` merge the
        // chapter list when it arrives.
        let seed: SourceEntry? = localEntry.map(Self.sourceEntry(from:)) ?? details ?? sourceEntry
        guard let seed else { return }

        isAddingToLibrary = true
        Task { @MainActor in
            let added = libraryManager.addToLibrary(
                entry: seed,
                chapters: sourceChapters,
                context: modelContext
            )
            // One transaction: the other actions split out of the library
            // button as it shrinks to the left.
            withAnimation(morph) {
                localEntry = added
                isAddingToLibrary = false
            }
        }
    }

    private func openReader(_ chapter: ChapterDisplay) {
        readerRouter.open(
            chapter,
            sourceKey: sourceKey,
            entryURL: localEntry?.url ?? sourceEntry?.url,
            kind: localEntry?.kind ?? sourceEntry?.kind ?? .novel
        )
    }

    private func continueReading() {
        if let resumeChapter { navigateToChapter = resumeChapter }
    }
}

/// Filter options for the chapter list.
enum ChapterFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case downloaded = "Downloaded"
    case bookmarked = "Bookmarked"

    var id: String { rawValue }
}

/// Range options for the chapter list.
enum ChapterRange: String, CaseIterable, Identifiable {
    case progress = "Current Progress"
    case first = "First 10 Chapters"
    case last = "Last 10 Chapters"

    var id: String { rawValue }
}

/// A performance-optimized ScrollView wrapper that isolates scroll offset tracking
struct NovelDetailScrollView<Content: View>: View {
    let content: Content

    var body: some View {
        ScrollView {
            content
        }
        .ignoresSafeArea(edges: .top)
        .scrollDismissesKeyboard(.immediately)
    }
}
