// GlobalSearchView.swift
// Search across every installed source concurrently.

import SwiftUI

struct GlobalSearchView: View {
    @Environment(SourceManager.self) private var sourceManager
    @State private var searchText = ""
    @State private var results: [SourceSearchResult] = []
    @State private var isSearching = false

    var body: some View {
        List {
            ForEach(results) { result in
                if !result.entries.isEmpty {
                    SourceResultSection(result: result)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if results.isEmpty && !isSearching {
                ContentUnavailableView(
                    "Global Search",
                    systemImage: "magnifyingglass",
                    description: Text("Search across all installed sources at once.")
                )
            } else if isSearching && results.isEmpty {
                LoadingView(message: "Searching \(sourceManager.novelSources.count) sources...")
            }
        }
        .navigationTitle("Global Search")
        .searchable(text: $searchText, prompt: "Search all sources")
        .onSubmit(of: .search) {
            Task { await performSearch() }
        }
    }

    // MARK: - Search

    private func performSearch() async {
        guard !searchText.isEmpty else { return }
        isSearching = true
        results = []

        let query = searchText
        let sources = sourceManager.novelSources

        await withTaskGroup(of: SourceSearchResult?.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let page = try await source.search(query: query, page: 1, filters: FilterState())
                        return SourceSearchResult(
                            sourceKey: source.key,
                            sourceName: source.name,
                            entries: page.entries
                        )
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                if let result, !result.entries.isEmpty {
                    results.append(result)
                }
            }
        }

        results.sort { $0.entries.count > $1.entries.count }
        isSearching = false
    }
}

// MARK: - Result Models

struct SourceSearchResult: Identifiable {
    let id = UUID()
    let sourceKey: String
    let sourceName: String
    let entries: [SourceEntry]
}

// MARK: - Result Section

struct SourceResultSection: View {
    @Namespace private var bookTransitions
    let result: SourceSearchResult

    var body: some View {
        Section(result.sourceName) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(result.entries.prefix(10)) { entry in
                        NavigationLink {
                            EntryDetailView(sourceEntry: entry)
                                .bookZoom(from: entry.url, in: bookTransitions)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                EntryCoverView(
                                    url: entry.thumbnailURL,
                                    aspectRatio: LayoutConstants.coverAspectRatio
                                )
                                .frame(width: 120)
                                .bookTransitionSource(entry.url, in: bookTransitions)

                                Text(entry.title)
                                    .font(Typography.small)
                                    .lineLimit(2)
                                    .frame(width: 120, alignment: .leading)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }
}
