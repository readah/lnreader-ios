// LibraryView.swift
// Main library screen showing saved novels with search, categories, and sorting.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    /// An entry a `lnreader://entry` link asked for, pushed when it arrives.
    @Binding var openedEntry: SourceEntry?

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
    /// "Arrange books" from the options sheet has to wait until the sheet is
    /// gone; starting edit mode underneath it put the drag handles behind glass.
    @State private var arrangeAfterSheet = false
    /// The sort that was active before Arrange. If nothing was actually moved,
    /// Done puts it back, so a stray hold never leaves the library on Custom.
    @State private var arrangingRestore: (scope: String?, hadOverride: Bool, sort: LibrarySort)?
    @State private var didReorder = false
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
    /// "Open random unread" counts chapters on a background context.
    @State private var isPickingRandom = false
    @State private var showNoUnreadManga = false
    /// Don't hand out the same manga twice in a row when there is a choice.
    @State private var lastRandomEntryID: PersistentIdentifier?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if libraryIsEmpty {
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
            .sheet(isPresented: $showOptionsSheet, onDismiss: {
                guard arrangeAfterSheet else { return }
                arrangeAfterSheet = false
                startArranging()
            }) {
                LibraryOptionsSheet(
                    tab: $optionsTab,
                    filter: activeFilterBinding,
                    sort: activeSortBinding,
                    displayMode: displayModeBinding,
                    scopeName: selectedCategory?.name ?? "All",
                    hasSortOverride: sortStore.hasOverride(for: selectedCategory?.name),
                    hasDisplayOverride: displayStore.hasOverride(for: selectedCategory?.name),
                    onResetSort: resetActiveSort,
                    onResetDisplay: resetDisplayMode,
                    onArrange: {
                        arrangeAfterSheet = true
                        showOptionsSheet = false
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .task(id: filterCountsKey) { await loadFilterCounts() }
            .onChange(of: categoryIDs) { _, _ in
                // A category deleted on the settings page leaves this tab
                // holding a deleted model. Fall back to All before `body`
                // reads its name, rather than faulting a dead object.
                if let selected = selectedCategory, !categories.contains(where: { $0 === selected }) {
                    selectedCategory = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active && isEditingLibrary {
                    if didReorder { commitLibraryPositions(clearOrder: false) }
                    draggedItem = nil
                }
            }
            .onChange(of: draggedItem) { _, item in
                lastReorderTarget = nil
                if item == nil && isEditingLibrary && didReorder {
                    commitLibraryPositions(clearOrder: false)
                }
            }
            .onChange(of: isEditingLibrary) { _, editing in
                if !editing {
                    // Clean up drag state when leaving edit mode to prevent
                    // ghost state from affecting the next edit session.
                    draggedItem = nil
                    // Only a move is worth a save: rewriting every libraryOrder
                    // (and every @Query it wakes) for an Arrange nobody used was
                    // the other half of the stray-hold problem.
                    if didReorder { commitLibraryPositions() }
                    else { editingOrder = [] }
                    // An Arrange with no moves must not leave Custom behind.
                    restoreSortAfterArranging()
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
            .alert("No unread manga", isPresented: $showNoUnreadManga) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Every manga in your library is up to date.")
            }
            .navigationDestination(for: Entry.self) { novel in
                // A migrated entry takes the place of the one that left the
                // library, so Back goes here rather than to a dead page.
                EntryDetailView(entry: novel) { replacement in
                    if !navigationPath.isEmpty { navigationPath.removeLast() }
                    navigationPath.append(replacement)
                }
                .id(novel.persistentModelID)
                .bookZoom(from: novel.persistentModelID, in: bookTransitions)
            }
            // A linked entry that is not in the library: nothing stored to push.
            .navigationDestination(for: SourceEntry.self) { entry in
                EntryDetailView(sourceEntry: entry)
            }
            // A link can arrive before or after this screen appears; one path,
            // which clears the value so it cannot push twice.
            .onChange(of: openedEntry) { openLinkedEntry() }
            .task { openLinkedEntry() }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "epub"), .pdf].compactMap { $0 },
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let container = modelContext.container
                    Task {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        do {
                            // Parsing and writing a book is seconds of work: a background
                            // context, off the main thread. `@Query` picks the entry up on save.
                            try await Task.detached(priority: .userInitiated) {
                                let context = ModelContext(container)
                                if url.pathExtension.lowercased() == "pdf" { try LocalBookManager.importPDF(at: url, context: context) }
                                else { try LocalBookManager.importEPUB(at: url, context: context) }
                            }.value
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
                isCustomised: activeFilter.isActive
                    || sortStore.hasOverride(for: selectedCategory?.name)
                    || displayStore.hasOverride(for: selectedCategory?.name),
                hasManga: hasManga,
                isPickingRandom: isPickingRandom,
                onShowOptions: { showOptionsSheet = true },
                onImport: { showFileImporter = true },
                onOpenRandom: openRandomUnread
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
            // Arrange is a mode now, not something a stray hold falls into.
            // Say what it does and how to leave it.
            if isEditingLibrary { arrangeHint }

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
            // update has its own progress banner pinned at the bottom of the
            // screen, so the pull indicator has no job beyond starting the run.
            // Waiting (or sleeping) kept the control pinned while the update
            // saved to the store, which left the scroll view sitting in its
            // pulled position. `updateLibrary` runs in its own task, so it
            // survives the refresh action being cancelled on re-render.
            let context = modelContext, sources = sourceManager, category = selectedCategory?.name
            Task {
                await libraryManager.updateLibrary(context: context, sourceManager: sources, category: category)
            }
        }
    }

    private var arrangeHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
            Text("Drag a book to change its order. Tap Done when you're happy with it.")
                .font(Typography.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(12)
        .background(AppTheme.surface, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
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
                onArrange: startArranging,
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
                onArrange: startArranging,
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

    /// Push the entry a link asked for, once.
    private func openLinkedEntry() {
        guard let entry = openedEntry else { return }
        openedEntry = nil
        navigationPath.append(entry)
    }

    // MARK: - Open random unread

    /// `novels.isEmpty` and `novels.count` for `body`, held while the reader is
    /// open. Touching `novels` after a save re-fetches and re-sorts every entry,
    /// and the library sits under the reader re-running that on each progress write.
    private var libraryIsEmpty: Bool {
        if isReaderPresented, let held = pageCache.isEmpty { return held }
        let empty = novels.isEmpty
        pageCache.isEmpty = empty
        return empty
    }

    private var libraryCount: Int {
        if isReaderPresented, let held = pageCache.count { return held }
        let count = novels.count
        pageCache.count = count
        return count
    }

    /// A novel-only library has nothing the dice button can open.
    private var hasManga: Bool {
        if isReaderPresented, let held = pageCache.hasManga { return held }
        let value = novels.contains { $0.kind == .manga }
        pageCache.hasManga = value
        return value
    }

    /// Push the detail screen of a random manga with unread chapters, from the
    /// whole library: the kind tab, search and view filters shape what is on
    /// screen, not which books are eligible.
    ///
    /// The candidate pass runs on a background `ModelContext` and counts with
    /// `fetchCount`. `Entry.unreadCount` / `hasUnread` walk the `chapters`
    /// relationship, so asking every manga for one on the main actor would
    /// fault every chapter row in the library — the stall `LibraryChapterCounts`
    /// exists to avoid. Only IDs cross back, and the view resolves the winner
    /// against its own `@Query` before pushing.
    private func openRandomUnread() {
        guard !isPickingRandom else { return }
        isPickingRandom = true
        let container = modelContext.container

        Task { @MainActor in
            let pick = Task.detached(priority: .userInitiated) { () -> [PersistentIdentifier] in
                let context = ModelContext(container)
                let entries = (try? context.fetch(FetchDescriptor<Entry>(
                    predicate: #Predicate<Entry> { $0.inLibrary }
                ))) ?? []

                var ids: [PersistentIdentifier] = []
                for entry in entries where entry.kind == .manga {
                    let id = entry.persistentModelID
                    // Hidden chapters do not exist; the same rule the badges,
                    // filters and reader all use.
                    let unread = #Predicate<Chapter> {
                        $0.entry?.persistentModelID == id && !$0.hidden && !$0.read
                    }
                    let count = (try? context.fetchCount(FetchDescriptor<Chapter>(predicate: unread))) ?? 0
                    if count > 0 { ids.append(id) }
                }
                return ids
            }
            let candidates = await pick.value

            isPickingRandom = false
            let pool = candidates.count > 1
                ? candidates.filter { $0 != lastRandomEntryID }
                : candidates
            guard let id = pool.randomElement(),
                  let entry = novels.first(where: { $0.persistentModelID == id }) else {
                showNoUnreadManga = true
                return
            }
            lastRandomEntryID = id
            Haptics.shared.impact(.light)
            navigationPath.append(entry)
        }
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

    /// A rename leaves these IDs alone; adding or deleting a category does not.
    private var categoryIDs: [PersistentIdentifier] {
        categories.map(\.persistentModelID)
    }

    /// Re-run the count pass when the filter, the category or the library changes.
    private var filterCountsKey: String {
        "\(needsChapterCounts)|\(needsChapterDates)|\(libraryCount)|\(scenePhase == .active)"
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

    /// Arranging is always an explicit choice now (the hold menu or the Sort
    /// tab). Remember the sort we replaced so an Arrange with no moves can put
    /// it back — a hold used to silently switch the library to Custom forever.
    private func startArranging() {
        guard !isEditingLibrary else { return }
        let scope = selectedCategory?.name
        arrangingRestore = (scope, sortStore.hasOverride(for: scope), activeSort)
        didReorder = false
        let order = sortedNovels(novels).map(\.persistentModelID)
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
            editingOrder = order
            lastReorderTarget = nil
            activeSortBinding.wrappedValue = LibrarySort(order: .custom, direction: .ascending)
            isEditingLibrary = true
        }
    }

    /// Books were moved: Custom is the point of Arrange, so it stays. Nothing
    /// moved: restore the override that was there, or remove the one we added.
    private func restoreSortAfterArranging() {
        guard let saved = arrangingRestore else { return }
        arrangingRestore = nil
        guard !didReorder, saved.scope == selectedCategory?.name else { return }
        var store = sortStore
        if saved.hadOverride { store.set(saved.sort, for: saved.scope) }
        else { store.reset(saved.scope) }
        sortsJSON = store.json
    }

    private func reorderNovels(dragged: Entry, target: Entry) {
        guard lastReorderTarget != target.persistentModelID,
              dragged.persistentModelID != target.persistentModelID else { return }
        lastReorderTarget = target.persistentModelID
        didReorder = true
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

// MARK: - Hold menu

/// Quick actions on a library book. Grid and list cells share it, so an action
/// cannot exist in one layout and not the other. A hold used to mean "enter
/// manual reorder", which silently switched the library to Custom sort even
/// when nothing was moved; now the hold is a menu and Arrange is one choice in
/// it.
struct LibraryEntryQuickActions: View {
    let entry: Entry
    var onArrange: () -> Void
    var onRemove: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager

    var body: some View {
        Button {
            markAllRead()
        } label: {
            Label("Mark all as read", systemImage: "checkmark.circle")
        }

        if !entry.isLocal {
            Button {
                ChapterDownloadManager.shared.enqueueUnread(nil, in: entry)
            } label: {
                Label("Download unread chapters", systemImage: "arrow.down.circle")
            }
        }

        if let shareURL {
            ShareLink(item: shareURL) {
                Label("Share link", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        Button("Arrange books", systemImage: "arrow.up.arrow.down", action: onArrange)
        Button("Remove from library", systemImage: "trash", role: .destructive, action: onRemove)
    }

    /// No source means no link: a local EPUB/PDF has no page to point at.
    private var shareURL: URL? {
        guard sourceManager.source(forKey: entry.sourceKey) != nil else { return nil }
        return EntryLink(
            sourceKey: entry.sourceKey,
            entryPath: entry.url,
            kind: entry.kind,
            title: entry.displayTitle
        ).shareURL
    }

    /// Every visible chapter ends up read, so twins cannot disagree and no
    /// fan-out is needed. One entry, one pass, one save, off `body`.
    private func markAllRead() {
        let chapters = entry.visibleChapters.filter { !$0.read }
        guard !chapters.isEmpty else { return }
        for chapter in chapters {
            chapter.read = true
            chapter.progress = 100
            chapter.paragraphIndex = 0
            chapter.lastPageRead = 0
            chapter.pagesLeft = 0
        }
        ChapterDownloadManager.shared.chaptersMarkedRead(chapters)
        try? modelContext.save()
        LibraryChapterCounts.shared.invalidate()
        NotificationCenter.default.post(name: .lnreaderChapterReadChanged, object: entry)
        Haptics.shared.notify(.success)
    }
}

/// The menu's preview is our own compact card, not a lift of the whole cell:
/// the cell's cover carries the zoom-transition source, and lifting that into
/// the menu overlay fights the transition when the detail screen opens.
struct LibraryEntryPreview: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EntryCoverView(url: entry.displayThumbnailURL)
                .frame(width: 120)
            Text(entry.displayTitle)
                .font(Typography.headline)
                .lineLimit(2)
            if let author = entry.displayAuthor, !author.isEmpty {
                Text(author)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: 260, alignment: .leading)
    }
}

/// Not observed: writing it from `body` must not invalidate the view.
private final class PageItemsCache {
    var items: [LibraryKindFilter: [Entry]] = [:]
    var isEmpty: Bool?
    var count: Int?
    var hasManga: Bool?
}
