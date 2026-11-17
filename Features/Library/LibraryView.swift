// LibraryView.swift
// Main library screen showing saved novels with search, categories, and sorting.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    /// An entry a `lnreader://entry` link asked for, pushed when it arrives.
    @Binding var openedEntry: SourceEntry?
    /// Sends an empty library to Browse instead of leaving the reader to hunt
    /// through the tab bar.
    var onExploreSources: () -> Void = {}

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
    @State private var swipeInteraction = LibrarySwipeInteraction()
    @GestureState private var isKindDragging = false
    @State private var lastReorderTarget: PersistentIdentifier?
    @State private var editingOrder: [PersistentIdentifier] = []
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @FocusState private var searchFocused: Bool
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
    @AppStorage(MinimalMode.enabledKey) private var minimalMode = false
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
    /// Work `body` would otherwise redo on every pass: the preference stores,
    /// the last sort, and the list held while the reader covers the screen.
    @State private var bodyCache = LibraryBodyCache()

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
        AppNavigationStack(path: $navigationPath) {
            Group {
                if libraryIsEmpty {
                    emptyLibraryState
                } else {
                    libraryPager
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                librarySearch
            }
            .appNavigationTitle("Library", onTitleVerticalSwipe: {
                Haptics.shared.selection()
                withAnimation(AppMotion.tabSwitch(reduceMotion: reduceMotion)) {
                    minimalMode = true
                }
            })
            .onChange(of: isKindDragging) { _, dragging in
                if !dragging { swipeInteraction.ended(at: ProcessInfo.processInfo.systemUptime) }
            }
            .appToolbar { libraryToolbar }
            .appSheet(isPresented: $showOptionsSheet, onDismiss: {
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
                .appPresentationDetents([.medium, .large])
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
            .appAlert("Remove from Library?", isPresented: $showDeleteConfirmation, presenting: novelToDelete) { novel in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    libraryManager.removeFromLibrary(entry: novel, context: modelContext)
                }
            } message: { novel in
                Text("Are you sure you want to remove '\(novel.displayTitle)' from your library?")
            }
            .appAlert("No unread manga", isPresented: $showNoUnreadManga) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Every manga in your library is up to date.")
            }
            .appNavigationDestination(for: Entry.self) { novel in
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
            .appNavigationDestination(for: SourceEntry.self) { entry in
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
            .appAlert("Import Error", isPresented: $showImportError, presenting: importError) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error)
            }
        }
    }

    // MARK: - Empty library

    /// A new install has two ways forward. The buttons say everything the old
    /// paragraph did, so the paragraph is gone.
    private var emptyLibraryState: some View {
        ContentUnavailableView {
            AppLabel("Library Empty", systemName: "books.vertical", size: 17, relativeTo: .body)
        } actions: {
            VStack(spacing: 10) {
                Button {
                    Haptics.shared.impact(.light)
                    onExploreSources()
                } label: {
                    AppLabel("Explore Sources", systemName: "safari", size: 17, relativeTo: .body)
                        .frame(maxWidth: 260)
                }
                .primaryActionStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)

                Button {
                    Haptics.shared.impact(.light)
                    showFileImporter = true
                } label: {
                    AppLabel("Import EPUB", systemName: "square.and.arrow.down", size: 17, relativeTo: .body)
                        .frame(maxWidth: 260)
                }
                .appGlassButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Toolbar

    @AppToolbarBuilder
    private var libraryToolbar: some AppToolbarContent {
        if isEditingLibrary {
            AppToolbarItem(placement: .confirmationAction) {
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

    // MARK: - Search

    private var librarySearch: some View {
        HStack(spacing: 0) {
            if isSearchExpanded {
                AppIcon(systemName: "magnifyingglass", size: 17, relativeTo: .body)
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)

                TextField("Search library", text: $searchText)
                    .font(Typography.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .accessibilityLabel("Search library")
                    .onSubmit { searchFocused = false }
                    .task { searchFocused = true }

                if !searchText.isEmpty {
                    Button {
                        Haptics.shared.selection()
                        searchText = ""
                        searchFocused = true
                    } label: {
                        AppIcon(systemName: "xmark.circle.fill", size: 17, relativeTo: .body)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Clear search")
                }

                Button(action: collapseSearch) {
                    AppIcon(systemName: "chevron.down", size: 17, relativeTo: .body)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Close search")
                .accessibilityHint("Clears the search and shows the full library selection.")
            } else {
                Button {
                    Haptics.shared.selection()
                    withAnimation(AppMotion.glassMorph(reduceMotion: reduceMotion)) {
                        isSearchExpanded = true
                    }
                } label: {
                    AppLabel("Search library", systemName: "magnifyingglass", size: 17, relativeTo: .body)
                        .font(Typography.body)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                }
                .accessibilityHint("Expands a search field to filter your library.")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.vertical, 4)
        .frame(maxWidth: isSearchExpanded ? .infinity : nil)
        .appGlassEffect(.regular, in: .capsule)
        .accessibilityAction(.escape, collapseSearch)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func collapseSearch() {
        Haptics.shared.selection()
        searchFocused = false
        withAnimation(AppMotion.glassMorph(reduceMotion: reduceMotion)) {
            searchText = ""
            isSearchExpanded = false
        }
    }

    // MARK: - Content

    /// Only the selected kind is built; the custom selector and the swipe both
    /// move it. One scroll view, rows cross-fading in place: swapping the whole
    /// page rebuilt the scroll view under the navigation bar and lagged.
    private var libraryPager: some View {
        libraryPage(showsKindPicker ? (LibraryKindFilter(rawValue: kindFilterRaw) ?? .all) : .all)
            .animation(AppMotion.tabSwitch(reduceMotion: reduceMotion), value: kindFilterRaw)
            .simultaneousGesture(kindSwipe)
    }

    /// Steps between kinds on a clearly horizontal swipe. Only reacts when the
    /// drag ends, so vertical scrolling is never touched.
    private var kindSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($isKindDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                swipeInteraction.changed(
                    horizontal: value.translation.width,
                    vertical: value.translation.height
                )
            }
            .onEnded { value in
                swipeInteraction.ended(at: ProcessInfo.processInfo.systemUptime)
                guard !isEditingLibrary, showsKindPicker else { return }
                let step = LibrarySwipeInteraction.pageStep(
                    horizontal: value.translation.width,
                    vertical: value.translation.height
                )
                guard step != 0 else { return }
                let options = kindOptions.map(\.rawValue)
                guard let current = options.firstIndex(of: kindFilterRaw) else { return }
                let next = current + step
                if options.indices.contains(next) { kindFilterRaw = options[next] }
            }
    }

    private var kindOptions: [LibraryKindFilter] { [.all, .manga, .novels] }

    private var kindPicker: some View {
        AppSlidingPicker(
            title: "Library content",
            selection: $kindFilterRaw,
            options: kindOptions.map(\.rawValue)
        ) { raw in
            let option = LibraryKindFilter(rawValue: raw) ?? .all
            return option == .novels ? "Novel" : option.title
        }
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

            // The selector scrolls with the books rather than pinning over them.
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
        .scrollDismissesKeyboard(.interactively)
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
            AppIcon(systemName: "arrow.up.arrow.down", size: 13, relativeTo: .footnote)
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
        guard swipeInteraction.allowsActivation(at: ProcessInfo.processInfo.systemUptime) else { return }
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
        if isReaderPresented, let held = bodyCache.isEmpty { return held }
        let empty = novels.isEmpty
        bodyCache.isEmpty = empty
        return empty
    }

    private var libraryCount: Int {
        if isReaderPresented, let held = bodyCache.count { return held }
        let count = novels.count
        bodyCache.count = count
        return count
    }

    /// A novel-only library has nothing the dice button can open.
    private var hasManga: Bool {
        if isReaderPresented, let held = bodyCache.hasManga { return held }
        let value = novels.contains { $0.kind == .manga }
        bodyCache.hasManga = value
        return value
    }

    /// Push the detail screen of a random manga with unread chapters, from the
    /// whole library: the kind tab, search and view filters shape what is on
    /// screen, not which books are eligible.
    ///
    /// The counts come from `LibraryChapterCounts`, which already answers "how
    /// many unread, hidden excluded" off the main actor and caches it. This used
    /// to run its own fetch and its own `fetchCount` per manga — a second place
    /// that had to know the same rule, and a second round of queries for numbers
    /// the badges had just loaded.
    private func openRandomUnread() {
        guard !isPickingRandom else { return }
        isPickingRandom = true
        let candidates = novels.filter { $0.kind == .manga }.map(\.persistentModelID)
        let container = modelContext.container

        Task { @MainActor in
            let counts = await LibraryChapterCounts.shared.counts(
                for: candidates, container: container)
            isPickingRandom = false

            let unread = candidates.filter { (counts[$0]?.unread ?? 0) > 0 }
            let pool = unread.count > 1 ? unread.filter { $0 != lastRandomEntryID } : unread
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
        if isReaderPresented, let held = bodyCache.items[kind] { return held }
        if activeSort.needsChapterCounts, !hasLoadedCounts { return bodyCache.items[kind] ?? [] }
        let items = filteredNovels(for: kind)
        bodyCache.items[kind] = items
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

    /// The three per-category stores, decoded once per distinct JSON.
    ///
    /// They used to be computed properties that each built a store from its
    /// `@AppStorage` string on every read, and `body` reads them a dozen times
    /// (the toolbar, the filter, the sort, the display mode, the empty state) —
    /// a dozen `JSONDecoder` runs per pass over the same unchanged strings.
    private var stores: (filters: LibraryFilterStore, sorts: LibrarySortStore, displays: LibraryDisplayStore) {
        bodyCache.stores(filters: filtersJSON, sorts: sortsJSON, displays: displaysJSON)
    }

    private var filterStore: LibraryFilterStore { stores.filters }

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

    /// Re-run the count pass when the filter, the category or the library
    /// changes — and when a write dropped a count, so a finished chapter shows
    /// up in the badges and in an unread sort without a relaunch.
    private var filterCountsKey: String {
        "\(needsChapterCounts)|\(needsChapterDates)|\(libraryCount)|\(scenePhase == .active)"
            + "|\(LibraryChapterCounts.shared.revision)"
    }

    /// Sorting by unread, total or a chapter date reads chapter data too, so it
    /// needs the background count pass just as a chapter-based filter does.
    private var needsChapterCounts: Bool {
        activeFilter.needsChapterCounts || activeSort.needsChapterCounts
    }

    private var needsChapterDates: Bool { activeSort.needsChapterDates }

    /// The optional counts this screen reads. Total and unread are always
    /// counted; these are one extra query per entry each.
    private var countExtras: LibraryChapterCounts.Extras {
        var extras: LibraryChapterCounts.Extras = []
        if activeFilter.needsDownloads { extras.insert(.downloads) }
        if needsChapterDates { extras.insert(.dates) }
        return extras
    }

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

    private var displayStore: LibraryDisplayStore { stores.displays }

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

    private var sortStore: LibrarySortStore { stores.sorts }

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
        let ids = novels.map(\.persistentModelID)
        guard !ids.isEmpty else {
            filterCounts = [:]
            hasLoadedCounts = true
            return
        }
        // One call for the whole library. The cache answers every entry whose
        // count is still good, so after a single chapter read this costs one
        // entry's queries, not the library's.
        let loaded = await LibraryChapterCounts.shared.counts(
            for: ids, container: modelContext.container, extras: countExtras)
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
        let keyed: [(item: Entry, facts: LibrarySortFacts)] = novels.map { entry in
            let known = counts[entry.persistentModelID]
            return (item: entry, facts: LibrarySortFacts(
                title: entry.displayTitle,
                libraryOrder: entry.libraryOrder,
                dateAdded: entry.dateAdded,
                lastReadAt: entry.lastReadAt,
                lastChecked: entry.lastUpdate,
                total: known?.total ?? 0,
                unread: known?.unread ?? 0,
                latestUpload: known?.latestUpload,
                latestFetch: known?.latestFetch
            ))
        }
        // The sort itself is an ICU compare per element; the facts above are
        // plain reads. Building them costs a fraction of sorting, so the answer
        // is reused whenever the facts come out the same.
        return bodyCache.sorted(keyed, by: sort)
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
    var onOpen: () -> Void
    var onArrange: () -> Void
    var onRemove: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager

    @Environment(ReaderRouter.self) private var readerRouter

    var body: some View {
        Button {
            continueReading()
        } label: {
            AppLabel("Continue reading", systemName: "arrow.right.circle", size: 17, relativeTo: .body)
        }

        Button {
            markAllRead()
        } label: {
            AppLabel("Mark all as read", systemName: "checkmark.circle", size: 17, relativeTo: .body)
        }

        if !entry.isLocal {
            Button {
                ChapterDownloadManager.shared.enqueueUnread(nil, in: entry)
            } label: {
                AppLabel("Download unread chapters", systemName: "arrow.down.circle", size: 17, relativeTo: .body)
            }
        }

        if let shareURL {
            ShareLink(item: shareURL) {
                AppLabel("Share link", systemName: "square.and.arrow.up", size: 17, relativeTo: .body)
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
        LibraryChapterCounts.shared.invalidate([entry.persistentModelID])
        NotificationCenter.default.post(name: .lnreaderChapterReadChanged, object: entry)
        Haptics.shared.notify(.success)
    }

    private func continueReading() {
        guard readerRouter.request == nil else { return }
        let entryID = entry.persistentModelID
        let sourceKey = entry.sourceKey
        let entryURL = entry.url
        let kind = entry.kind
        let container = modelContext.container

        Task {
            let target = await Self.resolveResumeChapter(
                entryID: entryID,
                sourceKey: sourceKey,
                entryURL: entryURL,
                container: container
            )
            guard readerRouter.request == nil else { return }
            if let target {
                Haptics.shared.impact(.light)
                readerRouter.open(
                    sourceKey: sourceKey,
                    entryURL: entryURL,
                    kind: kind,
                    chapterURL: target.url,
                    chapterName: target.name
                )
            } else {
                onOpen()
            }
        }
    }

    @concurrent
    private nonisolated static func resolveResumeChapter(
        entryID: PersistentIdentifier,
        sourceKey: String,
        entryURL: String,
        container: ModelContainer
    ) async -> (url: String, name: String)? {
        let context = ModelContext(container)

        var descriptor = FetchDescriptor<Chapter>(
            predicate: #Predicate<Chapter> {
                $0.entry?.persistentModelID == entryID && !$0.hidden
            },
            sortBy: [SortDescriptor(\.sourceOrder)]
        )
        descriptor.relationshipKeyPathsForPrefetching = []

        var lastOpened = FetchDescriptor<History>(
            predicate: #Predicate<History> {
                $0.chapter?.entry?.url == entryURL && $0.chapter?.entry?.sourceKey == sourceKey
            },
            sortBy: [SortDescriptor(\.lastRead, order: .reverse)]
        )
        lastOpened.fetchLimit = 1

        guard let chapters = try? context.fetch(descriptor), !chapters.isEmpty else {
            return nil
        }

        let oldestFirst = ChapterOrder.oldestFirst(chapters)
        let lastOpenedPath = (try? context.fetch(lastOpened))?.first?.chapterURL

        guard let chapter = ChapterOrder.resume(
            oldestFirst: oldestFirst,
            lastOpenedPath: lastOpenedPath,
            isUnread: { !$0.read }
        ) else {
            return nil
        }
        return (chapter.url, chapter.name)
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

/// Work `body` would otherwise redo on every pass.
///
/// Not observed: writing it from `body` must not invalidate the view. It holds
/// three things that are pure functions of inputs `body` already has —
///
/// - the three per-category preference stores, decoded once per JSON string
///   instead of once per read,
/// - the last sort, reused while the facts and the sort order are unchanged,
/// - the list held while the reader covers the screen, since nothing it shows
///   can be seen and its `@Query` re-runs on every progress save.
private final class LibraryBodyCache {

    // MARK: Stores

    private struct StoreKey: Equatable {
        var filters: String
        var sorts: String
        var displays: String
    }

    private var storeKey = StoreKey(filters: "", sorts: "", displays: "")
    private var filterStore = LibraryFilterStore()
    private var sortStore = LibrarySortStore()
    private var displayStore = LibraryDisplayStore()

    func stores(
        filters: String, sorts: String, displays: String
    ) -> (filters: LibraryFilterStore, sorts: LibrarySortStore, displays: LibraryDisplayStore) {
        let key = StoreKey(filters: filters, sorts: sorts, displays: displays)
        if key != storeKey {
            storeKey = key
            filterStore = LibraryFilterStore(json: filters)
            sortStore = LibrarySortStore(json: sorts)
            displayStore = LibraryDisplayStore(json: displays)
        }
        return (filters: filterStore, sorts: sortStore, displays: displayStore)
    }

    // MARK: Sort

    private var sortFacts: [LibrarySortFacts] = []
    private var sortBy: LibrarySort?
    private var sortResult: [Entry] = []

    /// The sort for these facts, computed only when they differ from the last
    /// answer's. Comparing the facts is a struct compare; sorting them is an
    /// ICU compare per element.
    func sorted(_ keyed: [(item: Entry, facts: LibrarySortFacts)], by sort: LibrarySort) -> [Entry] {
        let facts = keyed.map(\.facts)
        if sortBy == sort, facts == sortFacts { return sortResult }
        let result = LibrarySorter.sorted(keyed, by: sort)
        sortFacts = facts
        sortBy = sort
        sortResult = result
        return result
    }

    // MARK: Held page

    var items: [LibraryKindFilter: [Entry]] = [:]
    var isEmpty: Bool?
    var count: Int?
    var hasManga: Bool?
}
