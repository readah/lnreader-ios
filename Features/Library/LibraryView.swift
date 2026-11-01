// LibraryView.swift
// Main library screen showing saved novels with search, categories, and sorting.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.isReaderPresented) private var isReaderPresented
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager

    @Query(
        filter: #Predicate<Entry> { $0.inLibrary },
        sort: \Entry.title
    )
    private var novels: [Entry]
    @Query(sort: \Category.order) private var categories: [Category]

    @Namespace private var bookTransitions
    @State private var lastReorderTarget: PersistentIdentifier?
    @State private var editingOrder: [PersistentIdentifier] = []
    @State private var searchText = ""
    @State private var selectedCategory: Category?
    @AppStorage("general.defaultSortOrder") private var defaultSortOrder: SortOrder = .lastRead
    @AppStorage("general.defaultSortDirection") private var defaultSortDirection: SortDirection = .descending
    /// Sort overrides, one per category (`LibrarySortStore`).
    @AppStorage("library.sorts") private var sortsJSON = "{}"
    @AppStorage("general.defaultDisplayMode") private var defaultDisplayMode: DisplayMode = .comfortable
    /// Display overrides, one per category (`LibraryDisplayStore`).
    @AppStorage("library.displays") private var displaysJSON = "{}"
    @AppStorage("general.confirmRemove") private var confirmRemove = true
    @AppStorage("library.kindFilter") private var kindFilterRaw = LibraryKindFilter.all.rawValue
    /// Tri-state filters, one per category (`LibraryFilterStore`).
    @AppStorage("library.filters") private var filtersJSON = "{}"
    /// Chapter counts for the filters, loaded off the main thread. Filtering
    /// reads this (sort and filter), not `Entry.chapters` (see `LibraryChapterCounts`).
    @State private var filterCounts: [PersistentIdentifier: LibraryChapterCounts.Counts] = [:]
    /// True once the first count pass has finished. Until then a count-based
    /// sort has nothing to sort by, and showing it anyway reshuffles the grid
    /// the moment the counts arrive.
    @State private var hasLoadedCounts = false
    @State private var showOptionsSheet = false
    @State private var optionsTab: LibraryOptionsSheet.Tab = .sort
    /// Last computed page per kind, reused while the reader covers the library.
    @State private var pageCache = PageItemsCache()

    @State private var isEditingLibrary = false
    @State private var draggedItem: Entry? = nil
    @State private var novelToDelete: Entry? = nil
    @State private var showDeleteConfirmation = false
    @State private var navigationPath = NavigationPath()
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var showImportError = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if novels.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: "Your Library is Empty",
                        subtitle: "Browse sources to find novels, or import an EPUB or PDF.",
                        actionTitle: "Import book",
                        action: { showFileImporter = true }
                    )
                } else {
                    if showsKindPicker {
                        libraryPager
                    } else {
                        libraryPage(.all)
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search library")
            .toolbar { libraryToolbar }
            .sheet(isPresented: $showOptionsSheet) {
                LibraryOptionsSheet(
                    tab: $optionsTab,
                    filter: activeFilterBinding,
                    sort: activeSortBinding,
                    displayMode: displayModeBinding,
                    scopeName: selectedCategory?.name ?? "All",
                    hasSortOverride: sortStore.hasOverride(for: selectedCategory?.name),
                    hasDisplayOverride: displayStore.hasOverride(for: selectedCategory?.name),
                    onResetSort: resetActiveSort,
                    onResetDisplay: resetDisplayMode
                )
                .presentationDetents([.medium, .large])
            }
            .task(id: filterCountsKey) { await loadFilterCounts() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active && isEditingLibrary {
                    commitLibraryPositions(clearOrder: false)
                    draggedItem = nil
                }
            }
            .onChange(of: draggedItem) { _, item in
                lastReorderTarget = nil
                if item == nil && isEditingLibrary { commitLibraryPositions(clearOrder: false) }
            }
            .onChange(of: isEditingLibrary) { _, editing in
                if !editing {
                    // Clean up drag state when leaving edit mode to prevent
                    // ghost state from affecting the next edit session.
                    draggedItem = nil
                    // Commit any pending position changes.
                    commitLibraryPositions()
                }
            }
            .alert("Remove from Library?", isPresented: $showDeleteConfirmation, presenting: novelToDelete) { novel in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    libraryManager.removeFromLibrary(entry: novel, context: modelContext)
                }
            } message: { novel in
                Text("Are you sure you want to remove '\(novel.displayTitle)' from your library?")
            }
            .navigationDestination(for: Entry.self) { novel in
                // A migrated entry takes the place of the one that left the
                // library, so Back goes here rather than to a dead page.
                NovelDetailView(entry: novel) { replacement in
                    if !navigationPath.isEmpty { navigationPath.removeLast() }
                    navigationPath.append(replacement)
                }
                .id(novel.persistentModelID)
                .bookZoom(from: novel.persistentModelID, in: bookTransitions)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "epub"), .pdf].compactMap { $0 },
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        do {
                            if url.pathExtension.lowercased() == "pdf" { try LocalBookManager.importPDF(at: url, context: modelContext) }
                            else { try LocalBookManager.importEPUB(at: url, context: modelContext) }
                        } catch {
                            importError = error.localizedDescription
                            showImportError = true
                        }
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
            .alert("Import Error", isPresented: $showImportError, presenting: importError) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if isEditingLibrary {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                        isEditingLibrary = false
                    }
                }
                .bold()
            }
        } else {
            LibraryToolbar(
                isCustomised: activeFilter.activeCount > 0,
                onShowOptions: { showOptionsSheet = true },
                onImport: { showFileImporter = true }
            )
        }
    }

    // MARK: - Content

    /// Only the selected kind is built; the segmented control and the swipe both
    /// move it. One scroll view, rows cross-fading in place: swapping the whole
    /// page rebuilt the scroll view under the navigation bar and lagged.
    private var libraryPager: some View {
        libraryPage(LibraryKindFilter(rawValue: kindFilterRaw) ?? .all)
            .animation(AppMotion.tabSwitch(reduceMotion: reduceMotion), value: kindFilterRaw)
            .simultaneousGesture(kindSwipe)
    }

    /// Steps between kinds on a clearly horizontal swipe. Only reacts when the
    /// drag ends, so vertical scrolling is never touched.
    private var kindSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                guard !isEditingLibrary,
                      abs(dx) > 80, abs(dx) > abs(value.translation.height) * 2 else { return }
                let options = LibraryKindFilter.allCases.map(\.rawValue)
                guard let current = options.firstIndex(of: kindFilterRaw) else { return }
                let next = current + (dx < 0 ? 1 : -1)
                if options.indices.contains(next) { kindFilterRaw = options[next] }
            }
    }

    private var kindPicker: some View {
        Picker("Content", selection: $kindFilterRaw) {
            ForEach(LibraryKindFilter.allCases) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .hapticFeedback(.selection, trigger: kindFilterRaw)
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// The scrollable content for one kind: category chips, then the grid.
    private func libraryPage(_ kind: LibraryKindFilter) -> some View {
        let items = pageItems(for: kind)

        return ScrollView {
            // First thing in the scroll view, so it scrolls away with the content
            // instead of pinning over the search field.
            if showsKindPicker { kindPicker }

            if !categories.isEmpty {
                CategoryTabView(
                    categories: categories,
                    selectedCategory: $selectedCategory,
                    isUpdating: libraryManager.isUpdating,
                    onUpdate: updateCategory,
                    onToggleUpdates: toggleUpdates
                )
                .padding(.horizontal)
            }

            if items.isEmpty, activeSort.needsChapterCounts, !hasLoadedCounts {
                // The sort is waiting on its counts; that is not an empty library.
                ProgressView().padding(.top, 80)
            } else if items.isEmpty {
                emptyPage(kind)
            } else {
                libraryContent(items)
            }
        }
        .immediateScrollTouches()
        .onDrop(of: [UTType.text], isTargeted: nil) { _ in
            guard draggedItem != nil else { return false }
            draggedItem = nil
            return true
        }
        .refreshable {
            // Pulling down inside a category refreshes just that category. The
            // updates modal shows progress, so the pull indicator must not
            // stay pinned for the whole run: start it and let go.
            let context = modelContext, sources = sourceManager, category = selectedCategory?.name
            Task { await libraryManager.updateLibrary(context: context, sourceManager: sources, category: category) }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    /// An empty page is normal when only one kind is in the library, so say
    /// which one is empty instead of pretending the library has nothing.
    private func emptyPage(_ kind: LibraryKindFilter) -> some View {
        let isFiltering = !searchText.isEmpty || selectedCategory != nil || activeFilter.isActive
        return EmptyStateView(
            icon: isFiltering ? "magnifyingglass" : "books.vertical",
            title: isFiltering ? "No Matches" : "No \(kind.title)",
            subtitle: isFiltering
                ? "Nothing here matches the current search or category."
                : "Add \(kind.title.lowercased()) from Browse and it will show up here."
        )
        .padding(.top, 60)
    }

    /// Split out of `body`: two 15-line cell constructors inline pushed the
    /// view builder past what the type checker will infer in reasonable time.
    @ViewBuilder
    private func libraryContent(_ items: [Entry]) -> some View {
        if displayMode == .list {
            LibraryListView(
                transitionNamespace: bookTransitions,
                novels: items,
                isEditing: isEditingLibrary,
                draggedItem: $draggedItem,
                onReorder: handleReorder,
                onDelete: handleDelete,
                onStartEditing: { startEditing() },
                onSelect: handleSelect
            )
        } else {
            LibraryGridView(
                transitionNamespace: bookTransitions,
                novels: items,
                displayMode: displayMode,
                isEditing: isEditingLibrary,
                draggedItem: $draggedItem,
                onReorder: handleReorder,
                onDelete: handleDelete,
                onStartEditing: { startEditing() },
                onSelect: handleSelect
            )
        }
    }

    private func handleReorder(_ dragged: Entry, _ target: Entry) {
        reorderNovels(dragged: dragged, target: target)
    }

    private func handleDelete(_ novel: Entry) {
        if confirmRemove {
            novelToDelete = novel
            showDeleteConfirmation = true
        } else {
            libraryManager.removeFromLibrary(entry: novel, context: modelContext)
        }
    }

    private func handleSelect(_ novel: Entry) {
        navigationPath.append(novel)
    }

    // MARK: - Filtering & Sorting

    /// Only offer the split when the library actually holds both kinds.
    private var showsKindPicker: Bool {
        var sawNovel = false
        var sawManga = false
        for entry in novels {
            if entry.kind == .novel { sawNovel = true } else { sawManga = true }
            if sawNovel && sawManga { return true }
        }
        return false
    }

    /// `filteredNovels`, except while the reader is open. The library is still
    /// alive under the reader's full screen cover and its `@Query`s re-run on
    /// every progress save; nothing it shows can be seen, so hold the last
    /// result and recompute once the reader closes.
    private func pageItems(for kind: LibraryKindFilter) -> [Entry] {
        if isReaderPresented, let held = pageCache.items[kind] { return held }
        if activeSort.needsChapterCounts, !hasLoadedCounts { return pageCache.items[kind] ?? [] }
        let items = filteredNovels(for: kind)
        pageCache.items[kind] = items
        return items
    }

    /// Entries for one page: kind, then category, then search, then sort.
    private func filteredNovels(for kind: LibraryKindFilter) -> [Entry] {
        var result = novels

        switch kind {
        case .all: break
        case .novels: result = result.filter { $0.kind == .novel }
        case .manga: result = result.filter { $0.kind == .manga }
        }

        if let category = selectedCategory {
            result = result.filter { $0.categories.contains(category) }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(searchText)
            }
        }

        let filter = activeFilter
        if filter.isActive {
            result = result.filter { filter.matches(facts(for: $0, filter: filter)) }
        }

        return sortedNovels(result)
    }

    // MARK: Filters

    private var filterStore: LibraryFilterStore { LibraryFilterStore(json: filtersJSON) }

    private var activeFilter: LibraryFilter { filterStore.filter(for: selectedCategory?.name) }

    private var activeFilterBinding: Binding<LibraryFilter> {
        let name = selectedCategory?.name
        return Binding(
            get: { filterStore.filter(for: name) },
            set: {
                var store = filterStore
                store.set($0, for: name)
                filtersJSON = store.json
            }
        )
    }

    /// Re-run the count pass when the filter, the category or the library changes.
    private var filterCountsKey: String {
        "\(needsChapterCounts)|\(needsChapterDates)|\(novels.count)|\(scenePhase == .active)"
    }

    /// Sorting by unread, total or a chapter date reads chapter data too, so it
    /// needs the background count pass just as a chapter-based filter does.
    private var needsChapterCounts: Bool {
        activeFilter.needsChapterCounts || activeSort.needsChapterCounts
    }

    private var needsChapterDates: Bool { activeSort.needsChapterDates }

    // MARK: Categories

    private func updateCategory(_ category: Category) {
        Task {
            await libraryManager.updateLibrary(
                context: modelContext, sourceManager: sourceManager, category: category.name)
        }
    }

    private func toggleUpdates(_ category: Category) {
        category.flags = CategoryFlags.setting(category.flags, excluded: !CategoryFlags.isExcluded(category.flags))
        try? modelContext.save()
    }

    // MARK: Display

    private var displayStore: LibraryDisplayStore { LibraryDisplayStore(json: displaysJSON) }

    /// The display mode for the selected category, else the global default.
    private var displayMode: DisplayMode {
        displayStore.mode(for: selectedCategory?.name, default: defaultDisplayMode)
    }

    private var displayModeBinding: Binding<DisplayMode> {
        let name = selectedCategory?.name
        return Binding(
            get: { displayStore.mode(for: name, default: defaultDisplayMode) },
            set: {
                var store = displayStore
                store.set($0, for: name)
                displaysJSON = store.json
            }
        )
    }

    private func resetDisplayMode() {
        var store = displayStore
        store.reset(selectedCategory?.name)
        displaysJSON = store.json
    }

    // MARK: Sorts

    private var defaultSort: LibrarySort {
        LibrarySort(order: defaultSortOrder, direction: defaultSortDirection)
    }

    private var sortStore: LibrarySortStore { LibrarySortStore(json: sortsJSON) }

    /// The sort for the selected category, else the global default.
    private var activeSort: LibrarySort {
        sortStore.sort(for: selectedCategory?.name, default: defaultSort)
    }

    private var activeSortBinding: Binding<LibrarySort> {
        let name = selectedCategory?.name
        return Binding(
            get: { sortStore.sort(for: name, default: defaultSort) },
            set: {
                var store = sortStore
                store.set($0, for: name)
                sortsJSON = store.json
            }
        )
    }

    private func resetActiveSort() {
        var store = sortStore
        store.reset(selectedCategory?.name)
        sortsJSON = store.json
    }

    private func loadFilterCounts() async {
        guard needsChapterCounts else { return }
        let container = modelContext.container
        let extras: LibraryChapterCounts.Extras = needsChapterDates ? .dates : []
        // The queries run on background contexts; asking for all of them at once
        // lets them overlap instead of queueing one book behind another.
        let loaded = await withTaskGroup(of: (PersistentIdentifier, LibraryChapterCounts.Counts).self) { group in
            for novel in novels {
                let id = novel.persistentModelID
                group.addTask { @MainActor in
                    (id, await LibraryChapterCounts.shared.counts(for: novel, container: container, extras: extras))
                }
            }
            var out: [PersistentIdentifier: LibraryChapterCounts.Counts] = [:]
            for await (id, counts) in group { out[id] = counts }
            return out
        }
        if Task.isCancelled { return }
        filterCounts = loaded
        hasLoadedCounts = true
    }

    /// An entry whose counts have not loaded yet is treated as passing, so a
    /// filter never blanks the library while the count pass runs.
    private func facts(for entry: Entry, filter: LibraryFilter) -> LibraryFilterFacts {
        var facts = LibraryFilterFacts()
        if filter.needsChapterCounts, let counts = filterCounts[entry.persistentModelID] {
            facts.unread = counts.unread
            facts.total = counts.total
            facts.downloaded = counts.downloaded
        } else if filter.needsChapterCounts {
            // Unknown: satisfy whatever the filter asks so the entry stays visible.
            facts.unread = filter.unread == .exclude ? 0 : 1
            facts.total = filter.started == .exclude ? facts.unread : facts.unread + 1
            facts.downloaded = filter.downloaded == .exclude ? 0 : 1
        }
        facts.isCompleted = entry.status == .completed
        if filter.tracked != .off { facts.isTracked = !entry.tracks.isEmpty }
        return facts
    }

    private func sortedNovels(_ novels: [Entry]) -> [Entry] {
        let sort = activeSort
        if sort.order == .custom, isEditingLibrary {
            let ranks = Dictionary(uniqueKeysWithValues: editingOrder.enumerated().map { ($1, $0) })
            return novels.sorted { (ranks[$0.persistentModelID] ?? Int.max) < (ranks[$1.persistentModelID] ?? Int.max) }
        }
        // Counts come from the background pass (`loadFilterCounts`). Never walk
        // `novel.chapters` here: this runs in `body`, and faulting every chapter
        // of every entry was ~19 of 31 s of main-thread time in a profile. An
        // entry whose count has not loaded yet sorts as 0 until it arrives.
        let counts = sort.needsChapterCounts ? filterCounts : [:]
        return LibrarySorter.sorted(novels, by: sort) { entry in
            let known = counts[entry.persistentModelID]
            return LibrarySortFacts(
                title: entry.displayTitle,
                libraryOrder: entry.libraryOrder,
                dateAdded: entry.dateAdded,
                lastReadAt: entry.lastReadAt,
                lastChecked: entry.lastUpdate,
                total: known?.total ?? 0,
                unread: known?.unread ?? 0,
                latestUpload: known?.latestUpload,
                latestFetch: known?.latestFetch
            )
        }
    }

    private func startEditing() {
        let order = sortedNovels(novels).map(\.persistentModelID)
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
            editingOrder = order
            lastReorderTarget = nil
            activeSortBinding.wrappedValue = LibrarySort(order: .custom, direction: .ascending)
            isEditingLibrary = true
        }
    }

    private func reorderNovels(dragged: Entry, target: Entry) {
        guard lastReorderTarget != target.persistentModelID,
              dragged.persistentModelID != target.persistentModelID else { return }
        lastReorderTarget = target.persistentModelID
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
            editingOrder = LibraryReordering.move(dragged.persistentModelID, to: target.persistentModelID, in: editingOrder)
        }
    }

    private func commitLibraryPositions(clearOrder: Bool = true) {
        let byID = Dictionary(uniqueKeysWithValues: novels.map { ($0.persistentModelID, $0) })
        let current = Set(editingOrder)
        let order = editingOrder + novels.filter { !current.contains($0.persistentModelID) }.map(\.persistentModelID)
        for (index, id) in order.enumerated() { byID[id]?.libraryOrder = index }
        try? modelContext.save()
        if clearOrder { editingOrder = [] }
    }
}

/// Library split between light novels and manga.
enum LibraryKindFilter: String, CaseIterable, Identifiable {
    case all
    case novels
    case manga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .novels: "Novels"
        case .manga: "Manga"
        }
    }
}

/// Not observed: writing it from `body` must not invalidate the view.
private final class PageItemsCache {
    var items: [LibraryKindFilter: [Entry]] = [:]
}
