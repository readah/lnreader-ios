// LibraryGridView.swift
// Adaptive grid layout for novel covers in the library.

import SwiftData
import SwiftUI

struct LibraryGridView: View {
    var transitionNamespace: Namespace.ID? = nil
    let novels: [Entry]
    let displayMode: DisplayMode
    var onDelete: (Entry) -> Void
    var onSelect: (Entry) -> Void

    /// Items per row; 0 picks as many as fit (`LibraryGridColumns`).
    @AppStorage(LibraryGridColumns.key) private var columnCount = LibraryGridColumns.automatic

    private var columns: [GridItem] { LibraryGridColumns.gridItems(count: columnCount) }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(novels) { novel in
                InteractiveGridCell(
                    transitionNamespace: transitionNamespace,
                    novel: novel,
                    displayMode: displayMode,
                    onSelect: onSelect,
                    onRemove: { onDelete(novel) }
                )
            }
        }
        .padding(.horizontal)
    }
}

/// The "items per row" preference, shared by the grid and the options sheet.
enum LibraryGridColumns {
    static let key = "library.gridColumns"
    static let automatic = 0
    static let range = 2...8

    /// Grid columns for a stored count; anything outside `range` means "as many as fit".
    @MainActor static func gridItems(count: Int) -> [GridItem] {
        if count >= range.lowerBound {
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: min(count, range.upperBound))
        }
        return [GridItem(.adaptive(minimum: LayoutConstants.gridItemMinSize), spacing: 12)]
    }
}

// MARK: - Interactive Grid Cell Wrapper

struct InteractiveGridCell: View {
    var transitionNamespace: Namespace.ID? = nil
    let novel: Entry
    let displayMode: DisplayMode
    var onSelect: (Entry) -> Void
    var onRemove: () -> Void

    var body: some View {
        // A `Menu` with a primary action, not `.contextMenu`: tap opens, hold
        // shows the actions, and sliding onto one and lifting picks it — the
        // system's press-drag-release, which a context menu does not offer.
        Menu {
            LibraryEntryQuickActions(
                entry: novel,
                onOpen: { onSelect(novel) },
                onRemove: onRemove
            )
        } label: {
            NovelGridCell(
                transitionNamespace: transitionNamespace,
                novel: novel,
                displayMode: displayMode
            )
            .contentShape(Rectangle())
        } primaryAction: {
            onSelect(novel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
    }
}

// MARK: - Grid Cell

struct NovelGridCell: View {
    var transitionNamespace: Namespace.ID? = nil
    private var badgePrefs = LibraryBadgePrefs()
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    let novel: Entry
    let displayMode: DisplayMode

    /// Counts come from a cached `fetchCount`, never from walking the entry's
    /// chapter array — see `LibraryChapterCounts`.
    @State private var counts: LibraryChapterCounts.Counts?
    /// Reserved text heights, so a row of covers stays level at any text size.
    @ScaledMetric(relativeTo: .footnote) private var titleHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .caption2) private var authorHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EntryCoverView(
                url: novel.displayThumbnailURL,
                aspectRatio: LayoutConstants.coverAspectRatio
            )
            .bookTransitionSource(novel.persistentModelID, in: transitionNamespace)
            // An overlay, not a sibling: it takes exactly the cover's size.
            .overlay {
                if let badges = badges, !badges.isEmpty {
                    LibraryCoverBadges(badges: badges)
                }
            }

            if displayMode != .coverOnly {
                VStack(alignment: .leading, spacing: 2) {
                    Text(novel.displayTitle)
                        .font(Typography.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                        .frame(height: titleHeight, alignment: .topLeading)

                    if displayMode == .comfortable {
                        Text(novel.displayAuthor ?? "")
                            .font(Typography.small)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(height: authorHeight, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: LibraryCountsTaskID(id: novel.persistentModelID,
                                      extras: badgePrefs.extras.rawValue,
                                      revision: LibraryChapterCounts.shared.revision)) {
            if let cached = LibraryChapterCounts.shared.cached(novel.persistentModelID) {
                counts = cached
            }
            counts = await LibraryChapterCounts.shared.counts(
                for: novel, container: modelContext.container, extras: badgePrefs.extras)
        }
    }

    private var badges: LibraryBadges? {
        guard let counts else { return nil }
        return LibraryBadges.resolve(
            unread: counts.unread, downloaded: counts.downloaded, new: counts.new,
            lang: sourceManager.source(for: novel)?.lang, isLocal: novel.isLocal,
            settings: badgePrefs.settings)
    }
}
