// LibraryListView.swift
// Compact list layout alternative for the library.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryListView: View {
    var transitionNamespace: Namespace.ID? = nil
    let novels: [Entry]
    let isEditing: Bool
    @Binding var draggedItem: Entry?
    var onReorder: (Entry, Entry) -> Void
    var onDelete: (Entry) -> Void
    var onStartEditing: () -> Void
    var onSelect: (Entry) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(novels) { novel in
                Group {
                    if isEditing {
                        EditableListRow(
                            novel: novel,
                            isDragging: draggedItem == novel,
                            onDelete: { onDelete(novel) }
                        )
                        .onDrag {
                            self.draggedItem = novel
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
                        InteractiveListRow(
                            transitionNamespace: transitionNamespace,
                            novel: novel,
                            onSelect: onSelect,
                            onStartEditing: onStartEditing
                        )
                    }
                }
                Divider()
                    .padding(.leading, isEditing ? 120 : 88)
            }
        }
    }
}

// MARK: - Editable List Row (edit mode wrapper)

/// Separates the delete button from the drag surface so taps on the button
/// aren't swallowed by the drag gesture.
struct EditableListRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let novel: Entry
    let isDragging: Bool
    var onDelete: () -> Void

    var body: some View {
        LibraryListRow(
            novel: novel,
            isEditing: true,
            onDelete: onDelete
        )
        .contentShape(Rectangle())
        .wiggle(when: true)
        .opacity(isDragging ? 0.4 : 1.0)
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: isDragging)
    }
}

// MARK: - Interactive List Row Wrapper

struct InteractiveListRow: View {
    var transitionNamespace: Namespace.ID? = nil
    let novel: Entry
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
            LibraryListRow(
                transitionNamespace: transitionNamespace,
                novel: novel,
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

// MARK: - List Row

struct LibraryListRow: View {
    var transitionNamespace: Namespace.ID? = nil
    private var badgePrefs = LibraryBadgePrefs()
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    let novel: Entry
    var isEditing: Bool = false
    var onDelete: () -> Void = {}

    /// Cached counts; see `LibraryChapterCounts`. Reading `novel.unreadCount`
    /// here resolved the whole chapter relationship per row, three times over.
    @State private var counts: LibraryChapterCounts.Counts?

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                DeleteBadge(action: onDelete)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(10)
            }

            EntryCoverView(
                url: novel.displayThumbnailURL,
                aspectRatio: LayoutConstants.coverAspectRatio
            )
            .frame(width: 60, height: 86)
            .bookTransitionSource(novel.persistentModelID, in: transitionNamespace)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(novel.displayTitle)
                    .font(Typography.headline)
                    .lineLimit(2)

                if let author = novel.displayAuthor {
                    Text(author)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Label("\(counts?.total ?? 0)", systemImage: "list.number")
                    if let badges = badges {
                        if badges.unread > 0 { Label("\(badges.unread)", systemImage: "eye.slash") }
                        if badges.new > 0 { Label("\(badges.new)", systemImage: "sparkles") }
                        if badges.downloaded > 0 { Label("\(badges.downloaded)", systemImage: "arrow.down.circle") }
                        if let language = badges.language { Text(language) }
                    }
                }
                .font(Typography.small)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(minHeight: LayoutConstants.listRowHeight)
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
