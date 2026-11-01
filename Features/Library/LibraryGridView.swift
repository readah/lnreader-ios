// LibraryGridView.swift
// Adaptive grid layout for novel covers in the library.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryGridView: View {
    var transitionNamespace: Namespace.ID? = nil
    let novels: [Entry]
    let displayMode: DisplayMode
    let isEditing: Bool
    @Binding var draggedItem: Entry?
    var onReorder: (Entry, Entry) -> Void
    var onDelete: (Entry) -> Void
    var onStartEditing: () -> Void
    var onSelect: (Entry) -> Void

    /// Items per row; 0 picks as many as fit (`LibraryGridColumns`).
    @AppStorage(LibraryGridColumns.key) private var columnCount = LibraryGridColumns.automatic

    private var columns: [GridItem] { LibraryGridColumns.gridItems(count: columnCount) }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(novels) { novel in
                if isEditing {
                    EditableGridCell(
                        novel: novel,
                        displayMode: displayMode,
                        isDragging: draggedItem == novel,
                        onDelete: { onDelete(novel) }
                    )
                    .onDrag {
                        draggedItem = novel
                        return NSItemProvider(
                            object: (novel.url + "|" + novel.sourceKey) as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: NovelDropDelegate(
                            item: novel,
                            novels: novels,
                            draggedItem: $draggedItem,
                            onReorder: onReorder
                        ))
                } else {
                    InteractiveGridCell(
                        transitionNamespace: transitionNamespace,
                        novel: novel,
                        displayMode: displayMode,
                        onSelect: onSelect,
                        onStartEditing: onStartEditing
                    )
                }
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

// MARK: - Editable Grid Cell (edit mode wrapper)

/// Separates the delete badge from the drag surface so taps on the badge
/// aren't swallowed by the drag gesture.
struct EditableGridCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let novel: Entry
    let displayMode: DisplayMode
    let isDragging: Bool
    var onDelete: () -> Void

    var body: some View {
        NovelGridCell(
            novel: novel,
            displayMode: displayMode,
            isEditing: true,
            onDelete: onDelete
        )
        .contentShape(Rectangle())
        .wiggle(when: true)
        .opacity(isDragging ? 0.4 : 1.0)
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: isDragging)
    }
}

// MARK: - Interactive Grid Cell Wrapper

struct InteractiveGridCell: View {
    var transitionNamespace: Namespace.ID? = nil
    let novel: Entry
    let displayMode: DisplayMode
    var onSelect: (Entry) -> Void
    var onStartEditing: () -> Void

    @State private var longPressActive = false

    var body: some View {
        Button(action: {
            if longPressActive {
                longPressActive = false
            } else {
                onSelect(novel)
            }
        }) {
            NovelGridCell(
                transitionNamespace: transitionNamespace,
                novel: novel,
                displayMode: displayMode,
                isEditing: false,
                onDelete: {}
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    Haptics.shared.impact(.heavy)
                    longPressActive = true
                    onStartEditing()
                }
        )
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
    var isEditing: Bool = false
    var onDelete: () -> Void = {}

    /// Counts come from a cached `fetchCount`, never from walking the entry's
    /// chapter array — see `LibraryChapterCounts`.
    @State private var counts: LibraryChapterCounts.Counts?
    /// Reserved text heights, so a row of covers stays level at any text size.
    @ScaledMetric(relativeTo: .footnote) private var titleHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .caption2) private var authorHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                NovelCoverView(
                    url: novel.displayThumbnailURL,
                    aspectRatio: LayoutConstants.coverAspectRatio
                )
                .bookTransitionSource(novel.persistentModelID, in: transitionNamespace)

                if isEditing {
                    DeleteBadge(action: onDelete)
                        .offset(x: -6, y: -6)
                        .transition(.scale.combined(with: .opacity))
                        .zIndex(10)
                }
            }
            // An overlay, not a sibling: it takes exactly the cover's size.
            .overlay {
                if !isEditing, let badges = badges, !badges.isEmpty {
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
        .task(id: LibraryCountsTaskID(id: novel.persistentModelID, extras: badgePrefs.extras.rawValue)) {
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
