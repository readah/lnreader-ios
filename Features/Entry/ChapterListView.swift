// ChapterListView.swift
// Sortable, filterable chapter list. Pagination and filtering are driven
// from the parent (EntryDetailView); this view only renders what it receives.

import SwiftUI

struct ChapterListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: Entry?
    var allChapters: [ChapterDisplay] = []
    let chapters: [ChapterDisplay]
    let totalCount: Int
    let filteredCount: Int
    /// Per-entry scanlator priority, when the parent owns one.
    var scanlatorSettings: ScanlatorSettings? = nil
    let sourceKey: String
    /// The chapter list is still being fetched. Without this the screen said
    /// "No chapters yet" while the request was in flight.
    var isLoading: Bool = false
    /// Hold-to-select state, owned by the screen so its action bar can pin.
    var selection: ChapterSelection? = nil
    @Binding var selectedFilter: ChapterFilter
    @Binding var searchText: String
    /// When the list was last fetched, or that it is being fetched now.
    var fetchStatus: String? = nil
    @AppStorage(ChapterOrder.ascendingKey) private var ascending = false
    /// Colour from the open book's cover, when Settings › Appearance turns it on.
    @Environment(\.coverTint) private var coverTint
    @State private var showSearchField = false
    @State private var showScanlators = false
    @FocusState private var searchFocused: Bool

    private var isFiltered: Bool { selectedFilter != .all || !searchText.isEmpty }
    private var headerButtons: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                searchButton.foregroundStyle(iconTint)
                filterMenu.foregroundStyle(iconTint)
            }
        }
    }

    /// The glyph colour of the two header buttons: the cover's colour when
    /// tinting is on, primary otherwise.
    private var iconTint: Color { coverTint ?? AppTheme.primaryFill }

    /// The chapter card. Same surface as everywhere else, with the cover colour
    /// laid over it when tinting is on — a `Color` cannot be blended with
    /// another `Color`, so the two are stacked and clipped together.
    private var chapterCard: some View {
        ZStack {
            AppTheme.cardBackground
            if let coverTint { coverTint.opacity(0.12) }
        }
        .clipShape(.rect(cornerRadius: 18))
    }

    private var searchButton: some View {
        GlassIconButton(
            symbol: showSearchField ? "xmark" : "magnifyingglass",
            label: showSearchField ? "Close chapter search" : "Search chapters"
        ) {
            withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
                showSearchField.toggle()
                if !showSearchField { searchText = "" }
            }
            searchFocused = showSearchField
        }
    }

    /// Every scanlator in the list, for the scanlator sheet.
    private var scanlators: [String] {
        Set(allChapters.isEmpty ? chapters : allChapters)
            .compactMap(\.scanlator)
            .filter { !$0.isEmpty }
            .sorted()
    }

    private var hasActiveScanlatorRules: Bool { scanlatorSettings?.hasActiveRules ?? false }

    /// The list's only menu: order, filter, and scanlators when there are any.
    /// Entry-wide actions (downloads, tracking) live in `EntryActionBar`.
    private var filterMenu: some View {
        GlassMenuButton(
            symbol: selectedFilter != .all || hasActiveScanlatorRules
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
            label: "Sort and filter chapters"
        ) {
            Picker("Order", selection: $ascending) {
                Label("Newest first", systemImage: "arrow.down").tag(false)
                Label("Oldest first", systemImage: "arrow.up").tag(true)
            }
            Picker("Filter chapters", selection: $selectedFilter) {
                ForEach(ChapterFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            if scanlatorSettings != nil, !scanlators.isEmpty {
                Section {
                    Button { showScanlators = true } label: {
                        Label("Scanlators…", systemImage: hasActiveScanlatorRules ? "person.2.fill" : "person.2")
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chapters").font(Typography.title)
                    Text(isFiltered ? "\(filteredCount) matching chapters" : "\(totalCount) chapters")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let fetchStatus {
                        Text(fetchStatus)
                            .font(Typography.small).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                headerButtons
            }
            .padding(.top, 8)

            if showSearchField {
                TextField("Chapter name or number", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            if chapters.isEmpty && isLoading {
                ProgressView("Loading chapters…")
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(chapterCard)
            } else if chapters.isEmpty {
                ContentUnavailableView(isFiltered ? "No matching chapters" : "No chapters yet", systemImage: "text.magnifyingglass")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        let joins = selection?.neighbours(at: index, in: chapters) ?? (above: false, below: false)
                        let selected = selection?.paths.contains(chapter.path) == true
                        ChapterRow(chapter: chapter, entry: entry, sourceKey: sourceKey,
                                   selection: selection, orderedPaths: { chapters.map(\.path) },
                                   joinsAbove: joins.above, joinsBelow: joins.below)
                        // No rule inside or at the edge of a selected block.
                        if index + 1 < chapters.count {
                            Divider().padding(.leading, 22).opacity(selected || joins.below ? 0 : 1)
                        }
                    }
                }
                .background(chapterCard)
                .clipShape(.rect(cornerRadius: 18))
            }

        }
        .padding(.horizontal)
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: showSearchField)
        .onAppear { showSearchField = !searchText.isEmpty }
        .sheet(isPresented: $showScanlators) {
            if let scanlatorSettings {
                ScanlatorSettingsView(
                    settings: scanlatorSettings,
                    scanlators: scanlators
                )
            }
        }
    }
}

// MARK: - Unified Chapter Display

/// Bridges a stored chapter and a source chapter into a single displayable type.
///
/// The two sources of chapters differ (SwiftData rows carry read state, source
/// rows do not), so the list only ever renders this value.
struct ChapterDisplay: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    /// Release date, formatted on demand.
    ///
    /// It used to be a `String` formatted inside the initializer, which meant
    /// building and running a date formatter for every chapter in the book —
    /// thousands of them — to display ten rows.
    let releaseDate: Date?
    let unread: Bool
    let bookmarked: Bool
    let downloaded: Bool
    let progress: Int?
    let isInProgress: Bool
    let position: Int
    let chapterNumber: Double?
    /// Which group released this chapter, when the source says.
    let scanlator: String?
    /// Ordering key that does not depend on how the source listed the chapters.
    /// MangaFire returns newest-first, most novel sources oldest-first, so
    /// `position` is not comparable across sources — the number is.
    let sortNumber: Double
    let sourceKey: String
    let entryURL: String?
    /// Which reader opens this chapter. Needed because a browse result has no
    /// stored entry to ask.
    let kind: ContentKind
    /// Stored chapters only: `Chapter.hidden`. A source chapter has no stored
    /// decision yet, so `ScanlatorRules` is applied to those at the call site.
    let hidden: Bool

    /// Shared so a row does not rebuild a format style per access.
    private static let releaseStyle = Date.FormatStyle()

    var releaseTime: String? {
        releaseDate.map { $0.formatted(Self.releaseStyle) }
    }

    init(chapter: Chapter, position: Int? = nil) {
        self.id = chapter.url
        self.name = chapter.name
        self.path = chapter.url
        self.releaseDate = chapter.dateUpload
        self.unread = !chapter.read
        self.bookmarked = chapter.bookmark
        self.downloaded = chapter.isDownloaded
        self.progress = chapter.progress > 0 ? Int(chapter.progress) : nil
        self.isInProgress = chapter.isInProgress
        self.position = position ?? chapter.sourceOrder
        self.chapterNumber = chapter.chapterNumber >= 0 ? chapter.chapterNumber : nil
        self.scanlator = chapter.scanlator
        self.sortNumber = chapter.chapterNumber >= 0
            ? chapter.chapterNumber
            : Double((position ?? chapter.sourceOrder) + 1)
        self.sourceKey = chapter.entry?.sourceKey ?? ""
        self.entryURL = chapter.entry?.url
        self.kind = chapter.entry?.kind ?? .novel
        self.hidden = chapter.hidden
    }

    init(
        sourceChapter: SourceChapter,
        position: Int,
        sourceKey: String = "",
        entryURL: String? = nil,
        kind: ContentKind = .novel
    ) {
        self.id = sourceChapter.url
        self.name = sourceChapter.name
        self.path = sourceChapter.url
        self.releaseDate = sourceChapter.dateUpload
        self.unread = true
        self.bookmarked = false
        self.downloaded = false
        self.progress = nil
        self.isInProgress = false
        self.position = position
        self.chapterNumber = sourceChapter.chapterNumber >= 0 ? sourceChapter.chapterNumber : nil
        self.scanlator = sourceChapter.scanlator
        let parsed = sourceChapter.chapterNumber >= 0
            ? sourceChapter.chapterNumber
            : ChapterRecognition.parseChapterNumber(sourceChapter.name)
        self.sortNumber = parsed >= 0 ? parsed : Double(position + 1)
        self.sourceKey = sourceKey
        self.entryURL = entryURL
        self.kind = kind
        self.hidden = false
    }
}

/// A row's `position` is its index in the source's list, `0` = oldest — the same
/// invariant `ChapterOrder` keeps for a stored chapter's `sourceOrder`.
extension ChapterDisplay: ChapterOrdered {
    var orderIndex: Int { position }
    var orderIdentity: String { path }
}

/// Bounded chapter pages keep navigation manageable even for very long novels.
struct ChapterDirectoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.coverTint) private var coverTint
    let entry: Entry?
    let sourceEntry: SourceEntry?
    let chapters: [ChapterDisplay]
    let sourceKey: String
    let currentChapterPath: String?
    var onSelect: ((ChapterDisplay) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    let initialSearch: String
    let initialFilter: ChapterFilter

    init(entry: Entry?, chapters: [ChapterDisplay], sourceKey: String, currentChapterPath: String?, onSelect: ((ChapterDisplay) -> Void)? = nil, onClose: (() -> Void)? = nil, initialSearch: String = "", initialFilter: ChapterFilter = .all, sourceEntry: SourceEntry? = nil) {
        self.entry = entry; self.sourceEntry = sourceEntry; self.chapters = chapters; self.sourceKey = sourceKey; self.currentChapterPath = currentChapterPath
        self.onSelect = onSelect; self.onClose = onClose; self.initialSearch = initialSearch; self.initialFilter = initialFilter
        self._search = State(initialValue: initialSearch); self._selectedFilter = State(initialValue: initialFilter)
    }

    @State private var search = ""
    @State private var selectedFilter: ChapterFilter = .all
    @State private var page = 0
    @State private var jumpNumber = ""
    @State private var jumpError: String?
    @State private var initialized = false
    @State private var scrollTarget: String?
    @State private var scrollRequest = UUID()
    @State private var selection = ChapterSelection()
    @FocusState private var jumpFocused: Bool
    private let pageSize = 50

    private var filtered: [ChapterDisplay] {
        chapters.filter { chapter in
            let included: Bool
            switch selectedFilter {
            case .all: included = true
            case .unread: included = chapter.unread
            case .downloaded: included = chapter.downloaded
            case .bookmarked: included = chapter.bookmarked
            }
            return included && (search.isEmpty || chapter.name.localizedCaseInsensitiveContains(search) || String(chapter.position + 1) == search.trimmingCharacters(in: .whitespaces))
        }
    }
    private var pageCount: Int { ChapterPages.count(total: filtered.count, size: pageSize) }
    private var currentPage: Int { min(max(0, page), pageCount - 1) }
    private var visible: [ChapterDisplay] {
        let items = filtered
        if !search.isEmpty { return items }
        return Array(items[ChapterPages.bounds(total: items.count, page: currentPage, size: pageSize)])
    }
    private var pageLabel: String { label(for: currentPage) }
    private func label(for page: Int) -> String {
        let items = filtered
        guard !items.isEmpty else { return "No chapters" }
        let range = ChapterPages.bounds(total: items.count, page: page, size: pageSize)
        let ends = [items[range.lowerBound].position, items[range.upperBound - 1].position]
        return "\(ends.min()! + 1)–\(ends.max()! + 1)"
    }
    private var showsPager: Bool { !selection.isActive && search.isEmpty && pageCount > 1 }

    @ToolbarContentBuilder private var pagerItems: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { page = max(0, currentPage - 1) } label: { Label("Previous 50 chapters", systemImage: "chevron.left").labelStyle(.iconOnly) }
                .disabled(currentPage == 0)
            Spacer()
            Menu {
                ForEach(0..<pageCount, id: \.self) { index in
                    Button(label(for: index)) { page = index }
                }
            } label: { Label("\(pageLabel) · \(currentPage + 1)/\(pageCount)", systemImage: "rectangle.split.3x1").font(.subheadline.monospacedDigit()) }
            Spacer()
            Button { page = min(pageCount - 1, currentPage + 1) } label: { Label("Next 50 chapters", systemImage: "chevron.right").labelStyle(.iconOnly) }
                .disabled(currentPage + 1 >= pageCount)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    HStack(spacing: 12) {
                        EntryCoverView(url: entry?.displayThumbnailURL ?? sourceEntry?.thumbnailURL, aspectRatio: LayoutConstants.coverAspectRatio).frame(width: 42, height: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry?.displayTitle ?? sourceEntry?.title ?? "Chapters").font(.headline).lineLimit(2)
                            Text("\(chapters.count) chapters").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { goToCurrent() } label: { Label("Go to current chapter", systemImage: "location.fill").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless)
                            .tint(coverTint)
                    }
                    HStack {
                        Label { TextField("Jump to chapter", text: $jumpNumber).keyboardType(.numberPad).focused($jumpFocused) } icon: { Image(systemName: "number") }
                        Button("Go", action: jump).buttonStyle(.borderless).disabled(jumpNumber.isEmpty)
                            .tint(coverTint)
                    }
                    if let jumpError { Text(jumpError).font(.caption).foregroundStyle(AppTheme.destructive) }
                }
                Section {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, chapter in
                        let joins = selection.neighbours(at: index, in: visible)
                        let picked = selection.paths.contains(chapter.path)
                        HStack(spacing: 8) {
                            Text(String(chapter.position + 1)).font(.caption.monospacedDigit()).foregroundStyle(chapter.path == currentChapterPath ? .primary : .secondary).fontWeight(chapter.path == currentChapterPath ? .semibold : .regular).frame(minWidth: 32)
                            if let onSelect {
                                Button { onSelect(chapter) } label: {
                                    HStack {
                                        Text(chapter.name).font(.subheadline).fontWeight(chapter.path == currentChapterPath ? .semibold : .regular).foregroundStyle(.primary).lineLimit(2)
                                        Spacer()
                                        if chapter.path == currentChapterPath { Image(systemName: "book.fill").foregroundStyle(coverTint ?? .primary) }
                                        else if chapter.bookmarked { Image(systemName: "bookmark.fill").foregroundStyle(.secondary) }
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            } else {
                                ChapterRow(chapter: chapter, entry: entry, sourceKey: sourceKey,
                                           selection: entry == nil ? nil : selection, orderedPaths: { filtered.map(\.path) },
                                           joinsAbove: joins.above, joinsBelow: joins.below)
                                    .listRowInsets(EdgeInsets())
                            }
                        }
                        .listRowSeparator(picked || joins.below ? .hidden : .automatic)
                        .id(chapter.path)
                    }
                    if visible.isEmpty { ContentUnavailableView("No chapters", systemImage: "text.magnifyingglass", description: Text("Try another number, title, or filter.")) }
                } header: { Text(search.isEmpty ? "Chapters \(pageLabel)" : "\(filtered.count) results") }
            }
            .listStyle(.insetGrouped)
            .background {
                if let coverTint {
                    coverTint.opacity(0.10).ignoresSafeArea()
                }
            }
            .id("\(search.isEmpty ? currentPage : -1)-\(selectedFilter.rawValue)")
            .searchable(text: $search, prompt: "Search every chapter")
            .navigationTitle("Chapters").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Filter", selection: Binding(get: { selectedFilter }, set: { selectedFilter = $0; page = 0 })) {
                            ForEach(ChapterFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Filter chapters", systemImage: selectedFilter != .all ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                            .foregroundStyle(selectedFilter != .all ? (coverTint ?? .primary) : .primary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { if let onClose { onClose() } else { dismiss() } } }
            }
            .toolbar { if showsPager { pagerItems } }
            .toolbar(showsPager || selection.isActive ? .visible : .hidden, for: .bottomBar)
            .chapterSelectionToolbar(
                selection: selection, entry: entry, ordered: filtered,
                allChapters: chapters, sourceKey: sourceKey)
            .onChange(of: chapters) { _, _ in if !initialized && !chapters.isEmpty { if initialSearch.isEmpty && initialFilter == .all { goToCurrent() }; initialized = true } }
            .onAppear { if !initialized && !chapters.isEmpty { if initialSearch.isEmpty && initialFilter == .all { goToCurrent() }; initialized = true } }
            .onChange(of: scrollRequest) { _, request in
                Task { @MainActor in
                    await Task.yield()
                    guard scrollRequest == request, let scrollTarget else { return }
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
            }
            }
        }
    }
    private func goToCurrent() {
        search = ""; selectedFilter = .all
        page = (chapters.firstIndex { $0.path == currentChapterPath } ?? 0) / pageSize
        scrollTarget = currentChapterPath ?? chapters.first?.path; scrollRequest = UUID()
        jumpError = nil; jumpFocused = false
    }
    private func jump() {
        guard let number = Int(jumpNumber), let index = chapters.firstIndex(where: { $0.position + 1 == number }) else {
            jumpError = "Enter a chapter number from this book."; return
        }
        search = ""; selectedFilter = .all; page = index / pageSize
        scrollTarget = chapters[index].path; scrollRequest = UUID()
        jumpNumber = ""; jumpError = nil; jumpFocused = false
    }
}
