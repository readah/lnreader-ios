// MangaReaderView.swift - The manga reader: paged or continuous strip.
//
// One view for both layouts; the mode is a setting, not a different screen.
// Pages come from `MangaSource`, bytes from `PageLoader`, progress goes back
// through `LibraryManager`.

import SwiftData
import SwiftUI
import GlurBackdrop
#if canImport(UIKit)
import UIKit
#endif

struct MangaReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let sourceKey: String
    let entryURL: String?

    /// Layout settings for this series: its own overrides over the global defaults.
    @State private var seriesSettings: MangaSeriesSettings
    // Observed so a changed global default re-renders a series that follows it.
    @AppStorage(MangaReaderSettingsKey.readingMode) private var defaultModeRaw = MangaReadingMode.pager.rawValue
    @AppStorage(MangaReaderSettingsKey.direction) private var defaultDirectionRaw = MangaPagingDirection.leftToRight.rawValue

    @State private var chapterURL: String
    @State private var chapterName: String

    @State private var loader = PageLoader()
    @State private var pages: [SourcePage] = []
    /// The webtoon strip stitches chapters: the open one, then each one scrolled
    /// into. `pages` and `chapterURL` follow whichever chapter is on screen.
    @State private var segments: [ReaderSegment] = []
    /// Identity of the strip; a new one rebuilds it. The chapter changing as the
    /// reader scrolls on must not.
    @State private var stripID = UUID()
    @State private var appendTask: Task<Void, Never>?
    @State private var storedChapters: [Chapter] = []
    @State private var sourceChapters: [SourceChapter] = []
    @State private var isLoadingChapters = false
    @State private var chapterListError: String?
    @State private var chapterSourceEntry: SourceEntry?
    /// `chapterChoices` after scanlator rules.
    ///
    /// State, not a computed property: `hasChapter` asks for it twice per body
    /// evaluation, and rebuilding it means mapping every chapter plus a
    /// scanlator pass — over the whole list, for every tap and page turn.
    @State private var navigable: [SourceChapter] = []
    @State private var readerSize: CGSize = .zero
    @State private var scroller = WebtoonScrollController()
    @State private var showReaderSettings = false
    /// Volume keys, auto scroll and hold-to-scroll: one stored value for the user.
    @AppStorage(MangaControlSettings.storageKey) private var inputSettings = MangaControlSettings()
    @State private var currentIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var chrome: ReaderChromeState = .control
    @State private var showChapterSheet = false
    /// Set when stepping back a chapter so it opens on its last page.
    @State private var landOnLastPage = false
    /// The webtoon's page changes while the strip is moving. Publishing each one
    /// re-renders the reader and mutates the chapter (and every `@Query` behind
    /// it), a hitch per page; they are applied once scrolling settles instead.
    @State private var settledPage: Task<Void, Never>?
    @State private var pendingPage: Int?
    /// Webtoon progress waits for the strip to rest. Recording it mutates the
    /// chapter, and that re-runs the library's `@Query` (a fetch and a sort of
    /// every entry) on the main thread, under the reader: a hitch per write.
    @State private var progressTask: Task<Void, Never>?
    @State private var unsavedPage: Int?
    /// Scrolling with the controls up hides them after a moment.
    @State private var chromeHideTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @State private var isDismissing = false
    @State private var scanlatorSettings: ScanlatorSettings
    @AppStorage(AppearanceTint.enabledKey) private var tintDetails = true
    @AppStorage(AppearanceTint.strengthKey) private var tintStrength = AppearanceTint.defaultStrength
    @State private var coverTint: Color?

    init(sourceKey: String, entryURL: String?, chapterURL: String, chapterName: String) {
        self.sourceKey = sourceKey
        self.entryURL = entryURL
        self._chapterURL = State(initialValue: chapterURL)
        self._chapterName = State(initialValue: chapterName)
        self._scanlatorSettings = State(initialValue: ScanlatorSettings(key: "\(sourceKey)::\(entryURL ?? "")"))
        // A chapter opened outside a library entry has no series to remember,
        // so it is keyed by the chapter instead of sharing one empty-URL key.
        self._seriesSettings = State(initialValue: MangaSeriesSettings(key: "\(sourceKey)::\(entryURL ?? chapterURL)"))
    }

    private var localEntry: Entry? {
        guard let entryURL else { return nil }
        let key = sourceKey
        let predicate = #Predicate<Entry> { $0.url == entryURL && $0.sourceKey == key }
        var descriptor = FetchDescriptor<Entry>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private var displayCover: String? {
        localEntry?.displayThumbnailURL
            ?? storedChapters.first?.entry?.displayThumbnailURL
            ?? chapterSourceEntry?.thumbnailURL
    }

    private var mode: MangaReadingMode {
        _ = defaultModeRaw
        return seriesSettings.resolved.readingMode
    }

    private var direction: MangaPagingDirection {
        _ = defaultDirectionRaw
        return seriesSettings.resolved.direction
    }

    private var storedChapter: Chapter? {
        storedChapters.first { $0.url == chapterURL }
    }

    private var chapterChoices: [SourceChapter] {
        if !storedChapters.isEmpty {
            return storedChapters.map {
                SourceChapter(url: $0.url, name: $0.name, chapterNumber: $0.chapterNumber,
                              scanlator: $0.scanlator)
            }
        }
        return sourceChapters
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .contentShape(Rectangle())
                // A simultaneous gesture, not an overlay: an overlay of
                // `Color.clear` sits above the scroll view and eats the drag, so
                // the webtoon would not scroll and the pager would not swipe.
                .simultaneousGesture(
                    SpatialTapGesture()
                        // The webtoon strip handles its own taps.
                        .onEnded { value in if mode != .webtoon { handleTap(at: value.location) } }
                )

            if chrome.isControl {
                controls
            }

            scrollOverlays
        }
        .background { volumeKeys }
        .background(EdgeSwipeDismiss {
            guard !isDismissing, !showChapterSheet, !showReaderSettings else { return }
            isDismissing = true
            dismiss()
        })
        .statusBarHidden(!chrome.isControl)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { readerSize = $0 }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            await loadChapter()
            await loadChapterChoices()
        }
        .task(id: tintDetails ? (displayCover ?? "") : "") {
            coverTint = tintDetails ? await CoverTint.color(for: displayCover) : nil
        }
        .environment(\.coverTint, coverTint)
        .sheet(isPresented: $showChapterSheet) { chapterSheet }
        .sheet(isPresented: $showReaderSettings) {
            MangaReaderSettingsSheet(
                series: seriesSettings,
                controls: $inputSettings
            )
            // One height: More settings opens its own sheet. Deliberately no
            // cover tint here — the settings should not borrow the artwork.
            .presentationDetents([MangaReaderSettingsSheet.compactDetent])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(28)
        }
        .onAppear {
            setScreenAwake(true)
            configureScroller()
        }
        .onChange(of: inputSettings) { configureScroller() }
        .onChange(of: mode) { _, newMode in
            if newMode != .webtoon { scroller.stopAuto() }
        }
        .onDisappear {
            settleAndFlushProgress()
            scroller.detach()
            setScreenAwake(false)
            libraryManager.flushProgress(context: modelContext)
        }
        .onChange(of: currentIndex) { old, index in
            pageTurnHaptic(from: old, to: index)
            handlePageChange(index)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                settleAndFlushProgress()
                libraryManager.flushProgress(context: modelContext)
            }
        }
        .onChange(of: scanlatorSettings.value) { rebuildNavigable() }
        .onChange(of: mode) { _, _ in
            // Re-run the layout without refetching the page list. The strip
            // starts again from the chapter that is open.
            chrome = .control
            appendTask?.cancel()
            appendTask = nil
            segments = pages.isEmpty ? [] : [ReaderSegment(id: chapterURL, name: chapterName, pages: pages)]
            stripID = UUID()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().tint(.white)
        } else if let errorMessage {
            errorView(errorMessage)
        } else if pages.isEmpty {
            errorView("This chapter has no pages.")
        } else if mode == .webtoon {
            webtoon
        } else {
            pager
        }
    }

    private var pager: some View {
        TabView(selection: $currentIndex) {
            // Edge cards sit just outside the page range (-1 and pages.count)
            // so every existing page index keeps its meaning. Landing on one
            // opens the neighbouring chapter (`handlePageChange`).
            if hasChapter(offset: -1) {
                ChapterTransitionCard(direction: .previous, title: neighbourName(-1) ?? "")
                    .tag(-1)
            }
            ForEach(pages.indices, id: \.self) { index in
                MangaPageView(page: pages[index], sourceKey: sourceKey, loader: loader)
                    .tag(index)
            }
            if hasChapter(offset: 1) {
                ChapterTransitionCard(direction: .next, title: neighbourName(1) ?? "")
                    .tag(pages.count)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .id(chapterURL)
        .environment(\.layoutDirection, direction.layoutDirection)
        .ignoresSafeArea()
    }

    /// The strip is a `UICollectionView` (`WebtoonStrip`): rows have explicit
    /// heights, so scrolling up never meets a row whose size SwiftUI had only
    /// guessed. Which page is on screen is read from the scroll offset, and
    /// jumps go through `scroller.jumpToPage`.
    private var webtoon: some View {
        WebtoonStrip(
            segments: stripSegments,
            sourceKey: sourceKey,
            loader: loader,
            startIndex: currentIndex,
            widthFraction: CGFloat(inputSettings.stripWidth),
            controller: scroller,
            onPageChange: { chapter, index in pageScrolled(in: chapter, to: index) },
            // The divider is fully on screen only once the last page has been read
            // past: the chapter is finished, whether or not that page ever held
            // the top of the strip.
            onEndCard: { chapter in
                guard let chapter else { return }
                if chapter == chapterURL {
                    pendingPage = nil
                    scheduleProgress(pages.count - 1)
                }
                appendNextChapter()
            },
            onTap: { point in handleTap(at: point) }
        )
        .id(stripID)
        .ignoresSafeArea()
    }

    private var stripSegments: [WebtoonSegment] {
        segments.map { WebtoonSegment(id: $0.id, pages: $0.pages, nextTitle: neighbourName(1, of: $0.id)) }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await loadChapter() }
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .padding(32)
    }

    // MARK: - Chrome

    /// Keep the image legible beneath the controls with a light edge blur.
    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                GlurView(radius: 8, direction: .up)
                    .frame(height: 140)
                Spacer(minLength: 0)
                GlurView(radius: 8, direction: .down)
                    .frame(height: 140)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        GlassEffectContainer {
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    glassCircleButton("chevron.left", label: "Close reader") { dismiss() }
                    Spacer()
                    // Stacked rather than side by side: a long chapter title gets
                    // the width of the bar instead of running under the buttons.
                    VStack(spacing: 8) {
                        settingsButton
                        // Auto scroll only moves the webtoon strip.
                        if mode == .webtoon {
                            glassCircleButton(
                                "play.circle",
                                label: "Start auto scroll"
                            ) { toggleAutoScroll() }
                        }
                    }
                }

                Button { showChapterSheet = true } label: {
                    Text(chapterName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .frame(height: 46)
                        .padding(.horizontal, 20)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 60)
                .accessibilityLabel("Chapters: \(chapterName)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var settingsButton: some View {
        Button {
            showReaderSettings = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel("Reader settings")
    }

    private var bottomBar: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                if pages.count > 1 {
                    MangaPageSlider(index: Binding(get: { currentIndex }, set: seekPage), pageCount: pages.count)
                }
                HStack(spacing: 0) {
                    chapterButton(offset: -1, symbol: "chevron.left", label: "Previous chapter")
                    Divider().frame(height: 24)
                    chapterButton(offset: 1, symbol: "chevron.right", label: "Next chapter")
                }
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func glassCircleButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func chapterButton(offset: Int, symbol: String, label: String) -> some View {
        let available = !isLoading && hasChapter(offset: offset)
        return Button {
            Task { await moveChapter(by: offset) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    // MARK: - Loading

    private func loadChapter() async {
        let requestedURL = chapterURL
        // Progress writes are deferred while reading; a chapter change is a
        // natural place to land them.
        libraryManager.flushProgress(context: modelContext)
        scroller.stopAuto()
        appendTask?.cancel()
        appendTask = nil
        isLoading = true
        pages = []
        segments = []
        stripID = UUID()
        errorMessage = nil
        loadStoredChapters()

        if let entryURL, let downloaded = OfflineChapters.manga(sourceKey: sourceKey, entryURL: entryURL, chapterURL: requestedURL) {
            pages = downloaded
            segments = [ReaderSegment(id: requestedURL, name: chapterName, pages: downloaded)]
            currentIndex = resumeIndex(pageCount: downloaded.count)
            isLoading = false
            if let storedChapter, let entry = storedChapter.entry {
                libraryManager.recordHistory(entry: entry, chapter: storedChapter, context: modelContext)
            }
            return
        }

        guard let source = sourceManager.mangaSource(forKey: sourceKey) else {
            errorMessage = "This source is not available. Reinstall it and try again."
            isLoading = false
            return
        }

        let chapter = SourceChapter(url: chapterURL, name: chapterName)
        do {
            let fetched = try await source.pages(chapter)
            guard !Task.isCancelled, chapterURL == requestedURL else { return }
            pages = fetched
            segments = [ReaderSegment(id: requestedURL, name: chapterName, pages: fetched)]
            currentIndex = resumeIndex(pageCount: fetched.count)
            isLoading = false

            if let storedChapter, let entry = storedChapter.entry {
                libraryManager.recordHistory(entry: entry, chapter: storedChapter, context: modelContext)
            }
            await loader.prefetch(pages, current: currentIndex, sourceKey: sourceKey)
        } catch {
            guard !Task.isCancelled, chapterURL == requestedURL else { return }
            pages = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadStoredChapters() {
        guard let entryURL else {
            storedChapters = []
            return
        }
        let key = sourceKey
        let predicate = #Predicate<Chapter> { $0.entry?.url == entryURL && $0.entry?.sourceKey == key }
        let descriptor = FetchDescriptor<Chapter>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sourceOrder)]
        )
        storedChapters = ((try? modelContext.fetch(descriptor)) ?? []).sorted { lhs, rhs in
            if lhs.chapterNumber != rhs.chapterNumber {
                return lhs.chapterNumber < rhs.chapterNumber
            }
            return lhs.sourceOrder < rhs.sourceOrder
        }
        rebuildNavigable()
    }

    private func loadChapterChoices() async {
        guard !isLoadingChapters, storedChapters.isEmpty, sourceChapters.isEmpty, let entryURL,
              let source = sourceManager.mangaSource(forKey: sourceKey) else { return }
        isLoadingChapters = true
        chapterListError = nil
        defer { isLoadingChapters = false }
        do {
            let entry = SourceEntry(sourceKey: sourceKey, kind: .manga, url: entryURL, title: "")
            sourceChapters = try await source.chapters(entry).sorted { lhs, rhs in
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            chapterSourceEntry = try? await source.details(entry)
            rebuildNavigable()
        } catch {
            chapterListError = error.localizedDescription
        }
    }

    /// Resume a chapter that was left part-read, otherwise start at the top.
    private func resumeIndex(pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        if landOnLastPage {
            landOnLastPage = false
            return pageCount - 1
        }
        guard let storedChapter, !storedChapter.read else { return 0 }
        return min(max(storedChapter.lastPageRead, 0), pageCount - 1)
    }

    // MARK: - Progress

    /// The strip reports every page that passes the top. Prefetching follows the
    /// scroll immediately; the state and progress updates wait for it to settle.
    private func pageScrolled(in chapter: String, to index: Int) {
        if chapter != chapterURL { promote(to: chapter) }
        guard chapter == chapterURL, pages.indices.contains(index) else { return }
        // Fetch the next chapter ahead of the reader, so the divider is not a wait.
        if chapter == segments.last?.id, index >= pages.count - 3 { appendNextChapter() }
        Task { await loader.prefetch(pages, current: index, sourceKey: sourceKey) }
        guard index != currentIndex else {
            pendingPage = nil
            return
        }
        pendingPage = index
        settledPage?.cancel()
        settledPage = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            applyPendingPage()
        }
    }

    /// The strip scrolled into another stitched chapter: it becomes the open one.
    private func promote(to chapter: String) {
        guard let target = segments.firstIndex(where: { $0.id == chapter }),
              let from = segments.firstIndex(where: { $0.id == chapterURL }) else { return }
        // Progress belongs to the chapter being left. Moving on means it was
        // read to its end; moving back up leaves it where the reader last was.
        if target > from {
            settledPage?.cancel()
            settledPage = nil
            pendingPage = nil
            unsavedPage = pages.count - 1
            flushProgress()
        } else {
            settleAndFlushProgress()
        }
        chapterURL = chapter
        chapterName = segments[target].name
        pages = segments[target].pages
        currentIndex = target > from ? 0 : pages.count - 1
        if let storedChapter, let entry = storedChapter.entry {
            libraryManager.recordHistory(entry: entry, chapter: storedChapter, context: modelContext)
        }
    }

    /// Fetch the chapter after the last stitched one and add it to the strip.
    private func appendNextChapter() {
        guard mode == .webtoon, appendTask == nil, !isLoading, let last = segments.last,
              let position = navigableChapters.firstIndex(where: { $0.url == last.id }),
              navigableChapters.indices.contains(position + 1) else { return }
        let next = navigableChapters[position + 1]
        let strip = stripID
        appendTask = Task { @MainActor in
            defer { appendTask = nil }
            guard let fetched = try? await fetchPages(of: next), !fetched.isEmpty,
                  !Task.isCancelled, strip == stripID,
                  !segments.contains(where: { $0.id == next.url }) else { return }
            segments.append(ReaderSegment(id: next.url, name: next.name, pages: fetched))
            await loader.prefetch(fetched, current: 0, sourceKey: sourceKey)
        }
    }

    private func fetchPages(of chapter: SourceChapter) async throws -> [SourcePage] {
        if let entryURL, let downloaded = OfflineChapters.manga(sourceKey: sourceKey, entryURL: entryURL, chapterURL: chapter.url) {
            return downloaded
        }
        guard let source = sourceManager.mangaSource(forKey: sourceKey) else { return [] }
        return try await source.pages(SourceChapter(url: chapter.url, name: chapter.name))
    }

    private func recordProgress(_ index: Int) {
        guard let storedChapter, pages.indices.contains(index) else { return }
        libraryManager.recordMangaProgress(
            chapter: storedChapter,
            pageIndex: index,
            pageCount: pages.count,
            context: modelContext
        )
    }

    private func scheduleProgress(_ index: Int) {
        unsavedPage = index
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            flushProgress()
        }
    }

    private func flushProgress() {
        progressTask?.cancel()
        progressTask = nil
        guard let index = unsavedPage else { return }
        unsavedPage = nil
        recordProgress(index)
    }

    /// Write whatever progress is waiting, including a page that had not yet
    /// settled. For leaving the reader, changing chapter and backgrounding.
    private func settleAndFlushProgress() {
        if let index = pendingPage {
            applyPendingPage()
            unsavedPage = index
        }
        flushProgress()
    }

    private func applyPendingPage() {
        settledPage?.cancel()
        settledPage = nil
        guard let index = pendingPage else { return }
        pendingPage = nil
        if index != currentIndex { currentIndex = index }
    }

    private func handlePageChange(_ index: Int) {
        if !isLoading, mode != .webtoon {
            if index == pages.count, hasChapter(offset: 1) {
                Task { await moveChapter(by: 1) }
                return
            }
            if index == -1, hasChapter(offset: -1) {
                landOnLastPage = true
                Task { await moveChapter(by: -1) }
                return
            }
        }
        guard !isLoading, pages.indices.contains(index) else { return }

        if mode == .webtoon {
            scheduleProgress(index)
        } else {
            recordProgress(index)
        }
        // The webtoon prefetches as it scrolls (`pageScrolled`).
        if mode != .webtoon {
            Task { await loader.prefetch(pages, current: index, sourceKey: sourceKey) }
        }
    }

    // MARK: - Scrolling and volume keys

    private func configureScroller() {
        scroller.autoSpeed = inputSettings.autoScrollSpeed
        scroller.autoStyle = inputSettings.autoScrollStyle
        scroller.momentum = inputSettings.momentum
        scroller.hold = inputSettings.hold
        scroller.isHoldEnabled = inputSettings.holdScrollEnabled
        scroller.holdGoesForward = { point in
            let preferences = seriesSettings.resolved
            // Only the back zone scrolls back; the menu zone and a layout
            // without zones keep the default, forward.
            return preferences.tapZones.action(
                at: point,
                in: readerSize,
                inverted: preferences.invertTapZones
            ) != .previous
        }
        scroller.onScrollActivity = { scheduleChromeHide() }
        scroller.onReachedEnd = {
            // Out of pages: bring the controls back so the next chapter is one tap away.
            setChrome(.control)
        }
    }

    private func scheduleChromeHide() {
        guard chrome.isControl, chromeHideTask == nil else { return }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            chromeHideTask = nil
            setChrome(.focus)
        }
    }

    private func toggleAutoScroll() {
        if scroller.isAutoScrolling {
            scroller.stopAuto()
        } else {
            // Hide the controls so the page is what is on screen.
            setChrome(.focus)
            scroller.startAuto()
        }
    }

    /// Volume up goes back and volume down goes forward, unless inverted.
    private func handleVolumeKey(_ key: VolumeKey) {
        let forward = inputSettings.isForward(key)
        if mode == .webtoon {
            scroller.scrollScreen(forward: forward)
        } else {
            turnPage(forward: forward)
        }
    }

    @ViewBuilder
    private var volumeKeys: some View {
        if inputSettings.volumeKeys {
            VolumeKeyHost(onPress: handleVolumeKey)
                .frame(width: 1, height: 1)
        }
    }

    /// Auto scroll's stop button and the hold-to-scroll speed readout.
    private var scrollOverlays: some View {
        VStack {
            if let speed = scroller.holdSpeed {
                Text("\(Int(speed)) pt/s")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 60)
                    .transition(.opacity)
            }
            Spacer()
            if scroller.isAutoScrolling {
                Button { scroller.stopAuto() } label: {
                    Label("Auto scroll", systemImage: "pause.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.bottom, chrome.isControl ? 96 : 28)
                .accessibilityLabel("Stop auto scroll")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: scroller.holdSpeed != nil)
        .allowsHitTesting(scroller.isAutoScrolling)
    }

    // MARK: - Chapter navigation

    private func hasChapter(offset: Int) -> Bool {
        guard let current = navigableChapters.firstIndex(where: { $0.url == chapterURL }) else {
            return false
        }
        let target = current + offset
        return navigableChapters.indices.contains(target)
    }

    private func neighbourName(_ offset: Int, of url: String? = nil) -> String? {
        let url = url ?? chapterURL
        guard let current = navigableChapters.firstIndex(where: { $0.url == url }),
              navigableChapters.indices.contains(current + offset) else { return nil }
        return navigableChapters[current + offset].name
    }

    // MARK: - Interaction

    private func seekPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        currentIndex = index
        if mode == .webtoon { scroller.jumpToPage?(chapterURL, index) }
    }

    /// The series' tap-zone layout decides between previous, next and the
    /// controls. Paged mode turns the page (right-to-left swaps the sides);
    /// webtoon scrolls a screenful, and reading direction does not apply to a
    /// vertical strip.
    private func handleTap(at point: CGPoint) {
        // The finger lifting after a hold-to-scroll is not a tap.
        guard !scroller.justHeld else { return }

        let preferences = seriesSettings.resolved
        let isPager = mode == .pager
        switch preferences.tapZones.action(
            at: point,
            in: readerSize,
            inverted: preferences.invertTapZones,
            rightToLeft: isPager && direction == .rightToLeft
        ) {
        case .previous: isPager ? turnPage(forward: false) : scroller.scrollScreen(forward: false)
        case .next: isPager ? turnPage(forward: true) : scroller.scrollScreen(forward: true)
        case .menu: toggleControls()
        }
    }

    private func turnPage(forward: Bool) {
        let target = currentIndex + (forward ? 1 : -1)
        let edgeCard = (target == pages.count && hasChapter(offset: 1))
            || (target == -1 && hasChapter(offset: -1))
        guard pages.indices.contains(target) || edgeCard else {
            // Nothing further this way: the same wall a swipe would bounce off.
            Haptics.shared.scroll(ScrollFeel.edge(speed: 400))
            return
        }
        currentIndex = target
    }

    /// Paged mode: a swish-and-click per page, the chapter cue on landing on an
    /// edge card. Only one-page steps (a swipe, a tap zone, a volume key, the
    /// slider): a chapter opening on its resume page is not a turn.
    private func pageTurnHaptic(from old: Int, to new: Int) {
        guard mode == .pager, !isLoading, abs(new - old) == 1 else { return }
        if new == -1 || new == pages.count {
            Haptics.shared.chapterBreak()
        } else {
            Haptics.shared.pageTurn()
        }
    }

    private func setChrome(_ state: ReaderChromeState) {
        chromeHideTask?.cancel()
        chromeHideTask = nil
        guard chrome != state else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chrome = state }
        Haptics.shared.impact(.light)
    }

    private func toggleControls() {
        setChrome(chrome.toggled)
    }

    /// Reading should not be interrupted by the idle timer.
    private func setScreenAwake(_ awake: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    // MARK: - Chapter sheet

    private var directoryChapters: [ChapterDisplay] {
        let stored = Dictionary(storedChapters.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        return navigableChapters.enumerated().map { index, chapter in
            if let saved = stored[chapter.url] {
                return ChapterDisplay(chapter: saved, position: index)
            }
            return ChapterDisplay(sourceChapter: chapter, position: index, sourceKey: sourceKey,
                                  entryURL: entryURL, kind: .manga)
        }
    }

    private var navigableChapters: [SourceChapter] { navigable }

    private func rebuildNavigable() {
        let choices = chapterChoices
        let items = choices.map {
            ScanlatorRules.Item(number: $0.chapterNumber > 0 ? $0.chapterNumber : nil, scanlator: $0.scanlator)
        }
        navigable = ScanlatorRules.keptIndices(for: items, preference: scanlatorSettings.value).map { choices[$0] }
    }

    private var chapterSheet: some View {
        Group {
            if !chapterChoices.isEmpty {
                ChapterDirectoryView(
                    entry: storedChapters.first?.entry ?? localEntry,
                    chapters: directoryChapters,
                    sourceKey: sourceKey,
                    currentChapterPath: chapterURL,
                    onSelect: { selected in
                        guard let chapter = chapterChoices.first(where: { $0.url == selected.path }) else { return }
                        showChapterSheet = false
                        Task { await jumpToChapter(chapter) }
                    },
                    onClose: { showChapterSheet = false },
                    sourceEntry: chapterSourceEntry
                )
            } else {
                NavigationStack {
                    Group {
                        if isLoadingChapters {
                            ProgressView("Loading chapters…")
                        } else {
                            VStack(spacing: 16) {
                                ContentUnavailableView("Chapters unavailable", systemImage: "list.bullet",
                                    description: Text(chapterListError ?? "This source has no chapters to show."))
                                Button("Try again") { Task { await loadChapterChoices() } }
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showChapterSheet = false }
                        }
                    }
                }
            }
        }
        .environment(\.coverTint, coverTint)
        .task { await loadChapterChoices() }
    }

    private func jumpToChapter(_ chapter: SourceChapter) async {
        guard chapter.url != chapterURL else { return }
        chapterURL = chapter.url
        chapterName = chapter.name
        currentIndex = 0
        await loadChapter()
    }

    private func moveChapter(by offset: Int) async {
        guard !isLoading, let current = navigableChapters.firstIndex(where: { $0.url == chapterURL }) else { return }
        let target = current + offset
        guard navigableChapters.indices.contains(target) else { return }

        // Progress belongs to the chapter being left, so write it first.
        settleAndFlushProgress()
        let next = navigableChapters[target]
        chapterURL = next.url
        chapterName = next.name
        currentIndex = 0
        await loadChapter()
    }
}

/// A 44-point control so the scrubber aligns with the chapter navigation capsule.
private struct MangaPageSlider: View {
    @Binding var index: Int
    let pageCount: Int
    @Environment(\.coverTint) private var coverTint

    private var progress: CGFloat {
        CGFloat(index) / CGFloat(max(pageCount - 1, 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(geometry.size.width - 88, 1)
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .frame(width: 24, alignment: .trailing)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(coverTint ?? .white)
                        .frame(width: max(6, trackWidth * progress))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 6)
                .accessibilityHidden(true)
                Text("\(pageCount)")
                    .frame(width: 24, alignment: .leading)
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max((value.location.x - 44) / trackWidth, 0), 1)
                        index = Int((fraction * CGFloat(max(pageCount - 1, 0))).rounded())
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page")
        .accessibilityValue("\(index + 1) of \(pageCount)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(index + 1, pageCount - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: break
            }
        }
    }
}

/// A chapter stitched into the webtoon strip.
private struct ReaderSegment {
    let id: String
    let name: String
    let pages: [SourcePage]
}
