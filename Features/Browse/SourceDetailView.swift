// SourceDetailView.swift
// Browse one source with search and pagination.
//
// Talks to the v2 source layer: the source key only identifies which source to ask for,
// everything else goes through `CatalogSource`.

import SwiftUI

struct SourceDetailView: View {
    @Namespace private var bookTransitions
    let sourceKey: String
    let title: String
    @Environment(SourceManager.self) private var sourceManager

    @State private var entries: [SourceEntry] = []
    @State private var searchText = ""
    @State private var currentPage = 1
    @State private var isLoading = false
    @State private var isSearching = false
    @State private var hasMore = true
    @State private var filterDefinitions: [SourceFilter] = []
    @State private var filtersLoaded = false
    @State private var filtersFetchedAt: Date?
    @State private var isRefreshingFilters = false
    @State private var filterRefreshFailed = false
    @State private var filterState = FilterState()
    @State private var showFilters = false

    /// The Library's display preferences, set from the Browse page.
    @AppStorage("general.defaultDisplayMode") private var displayMode = DisplayMode.comfortable
    @AppStorage(LibraryGridColumns.key) private var columnCount = LibraryGridColumns.automatic

    private var columns: [GridItem] { LibraryGridColumns.gridItems(count: columnCount) }

    private var loadMoreFooter: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
            .task { await loadMore() }
    }

    @ViewBuilder
    private func entryLink(_ entry: SourceEntry) -> some View {
        NavigationLink {
            EntryDetailView(sourceEntry: entry)
                .bookZoom(from: entry.url, in: bookTransitions)
        } label: {
            if displayMode == .list {
                BrowseEntryRow(entry: entry, transitionNamespace: bookTransitions)
            } else {
                BrowseEntryCell(
                    entry: entry, displayMode: displayMode, transitionNamespace: bookTransitions)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var entriesLayout: some View {
        if displayMode == .list {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entryLink($0) }
                if hasMore && !entries.isEmpty { loadMoreFooter }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { entryLink($0) }
                if hasMore && !entries.isEmpty { loadMoreFooter }
            }
            .padding(.horizontal)
        }
    }

    /// `CatalogSource`, not `NovelSource`: browse is identical for both kinds.
    private var source: (any CatalogSource)? {
        sourceManager.source(forKey: sourceKey)
    }

    var body: some View {
        ScrollView {
            entriesLayout
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search \(title)")
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                isSearching = false
                Task { await loadPopular() }
            }
        }
        .overlay {
            if isLoading && entries.isEmpty {
                LoadingView(message: "Loading...")
            } else if entries.isEmpty && !isLoading {
                if isSearching {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "books.vertical",
                        description: Text("This source is not installed, or returned nothing.")
                    )
                }
            }
        }
        .task { await loadPopular() }
        .task { await loadFilterDefinitions() }
        .sheet(isPresented: $showFilters) {
            Group {
                if filtersLoaded {
                    SourceFilterSheet(
                        filters: filterDefinitions,
                        applied: filterState,
                        refresh: source?.filtersAreRemote == true
                            ? FilterRefresh(
                                fetchedAt: filtersFetchedAt,
                                isRefreshing: isRefreshingFilters,
                                failed: filterRefreshFailed,
                                action: { Task { await refreshFilters() } }
                            )
                            : nil
                    ) { newState in
                        guard newState != filterState else { return }
                        filterState = newState
                        Task { await reload() }
                    }
                } else {
                    LoadingView(message: "Loading filters...")
                }
            }
            .presentationDetents([.medium, .large])
        }
        .toolbar {
            if hasFilters {
                ToolbarItem(placement: .primaryAction) {
                    Button { showFilters = true } label: {
                        Label("Filters", systemImage: activeFilterCount > 0
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityValue(activeFilterCount > 0 ? "\(activeFilterCount) active" : "")
                }
            }
            if let site = CommentSite.site(for: SourceKey.identifier(from: sourceKey)) {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(destination: NovelFireLoginView(onLoginSuccess: {
                        Task { await loadPopular() }
                    }, site: site)) {
                        Label("Login", systemImage: "person.badge.key")
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    /// Shown straight away; hidden only once the source reports it has nothing to filter.
    private var hasFilters: Bool {
        !filtersLoaded || SourceFilter.flatten(filterDefinitions).contains { $0.isSelectable }
    }

    private var activeFilterCount: Int { filterState.modifiedCount(for: filterDefinitions) }

    /// Remote filter lists come from disk when there is a copy, and are refetched quietly once it
    /// is past 30 days. Sources with built-in lists are just asked, which costs nothing.
    private func loadFilterDefinitions() async {
        guard let source else { return }
        if source.filtersAreRemote, let stored = SourceFilterStore.load(sourceKey: sourceKey) {
            filterDefinitions = stored.filters
            filtersFetchedAt = stored.fetchedAt
            filtersLoaded = true
            if stored.isStale { await refreshFilters() }
            return
        }
        let loaded = (try? await source.filters()) ?? []
        filterDefinitions = loaded
        if source.filtersAreRemote, source.filtersAreComplete(loaded) {
            filtersFetchedAt = SourceFilterStore.save(loaded, sourceKey: sourceKey)?.fetchedAt
        }
        filtersLoaded = true
    }

    /// Refetches a remote list. A failed or partial result keeps the copy already on screen.
    private func refreshFilters() async {
        guard let source, source.filtersAreRemote, !isRefreshingFilters else { return }
        isRefreshingFilters = true
        filterRefreshFailed = false
        defer { isRefreshingFilters = false }

        let loaded = (try? await source.filters()) ?? []
        guard source.filtersAreComplete(loaded) else {
            filterRefreshFailed = true
            return
        }
        filterDefinitions = loaded
        filtersFetchedAt = SourceFilterStore.save(loaded, sourceKey: sourceKey)?.fetchedAt
    }

    /// Re-runs the current listing (search or browse) from the first page.
    private func reload() async {
        entries = []
        if isSearching { await search() } else { await loadPopular() }
    }

    /// One page of whatever the screen is showing. A search always carries the filters. Browsing
    /// carries them only once changed, through `popular` for sources that read them there and
    /// through an empty search for the rest.
    private func fetchPage(_ page: Int, from source: any CatalogSource) async throws -> EntriesPage {
        if isSearching {
            return try await source.search(query: searchText, page: page, filters: filterState)
        }
        if filterState.isModified(for: filterDefinitions) {
            return source.filtersApplyToPopular
                ? try await source.popular(page: page, filters: filterState)
                : try await source.search(query: "", page: page, filters: filterState)
        }
        return try await source.popular(page: page, filters: FilterState())
    }

    private func loadPopular() async {
        guard let source else { return }
        isLoading = true
        currentPage = 1
        hasMore = true

        do {
            let page = try await fetchPage(1, from: source)
            entries = page.entries
            hasMore = page.hasNextPage
        } catch {
            print("⚠️ Failed to load popular entries: \(error)")
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let source, hasMore else { return }
        currentPage += 1

        do {
            let page = try await fetchPage(currentPage, from: source)
            if page.entries.isEmpty {
                hasMore = false
            } else {
                entries.append(contentsOf: page.entries)
                hasMore = page.hasNextPage
            }
        } catch {
            hasMore = false
        }
    }

    private func search() async {
        guard let source, !searchText.isEmpty else { return }
        isLoading = true
        isSearching = true
        currentPage = 1

        do {
            let page = try await fetchPage(1, from: source)
            entries = page.entries
            hasMore = page.hasNextPage
        } catch {
            print("⚠️ Search failed: \(error)")
        }
        isLoading = false
    }
}

// MARK: - Browse Entry Cell

struct BrowseEntryCell: View {
    let entry: SourceEntry
    var displayMode: DisplayMode = .compact
    var transitionNamespace: Namespace.ID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EntryCoverView(
                url: entry.thumbnailURL,
                aspectRatio: LayoutConstants.coverAspectRatio
            )
            .bookTransitionSource(entry.url, in: transitionNamespace)

            if displayMode != .coverOnly {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(Typography.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)

                    if displayMode == .comfortable, let author = entry.author, !author.isEmpty {
                        Text(author)
                            .font(Typography.small)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// The `.list` layout: a small cover beside title and author.
struct BrowseEntryRow: View {
    let entry: SourceEntry
    var transitionNamespace: Namespace.ID? = nil

    var body: some View {
        HStack(spacing: 12) {
            EntryCoverView(
                url: entry.thumbnailURL,
                aspectRatio: LayoutConstants.coverAspectRatio
            )
            .frame(width: 60, height: 86)
            .bookTransitionSource(entry.url, in: transitionNamespace)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(Typography.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = entry.author, !author.isEmpty {
                    Text(author)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(minHeight: LayoutConstants.listRowHeight)
        .contentShape(.rect)
    }
}
