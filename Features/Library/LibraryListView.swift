// LibraryListView.swift
// Compact list layout alternative for the library.

import SwiftData
import SwiftUI

struct LibraryListView: View {
    var transitionNamespace: Namespace.ID? = nil
    let novels: [Entry]
    var onDelete: (Entry) -> Void
    var onSelect: (Entry) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(novels) { novel in
                InteractiveListRow(
                    transitionNamespace: transitionNamespace,
                    novel: novel,
                    onSelect: onSelect,
                    onRemove: { onDelete(novel) }
                )
                // Blurs out under the pinned kind picker; the band comes from
                // the Library through the environment. The divider follows its
                // row so a blurred row is not cut by a sharp hairline.
                .progressiveTopBlur()
                Divider()
                    .padding(.leading, 88)
                    .progressiveTopBlur()
            }
        }
    }
}

// MARK: - Interactive List Row Wrapper

struct InteractiveListRow: View {
    var transitionNamespace: Namespace.ID? = nil
    let novel: Entry
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
            LibraryListRow(
                transitionNamespace: transitionNamespace,
                novel: novel
            )
            .contentShape(Rectangle())
        } primaryAction: {
            onSelect(novel)
        }
        .menuStyle(.button)
        .buttonStyle(AppPlainButtonStyle())
        .menuOrder(.fixed)
    }
}

// MARK: - List Row

struct LibraryListRow: View {
    var transitionNamespace: Namespace.ID? = nil
    private var badgePrefs = LibraryBadgePrefs()
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    let novel: Entry

    /// Cached counts; see `LibraryChapterCounts`. Reading `novel.unreadCount`
    /// here resolved the whole chapter relationship per row, three times over.
    @State private var counts: LibraryChapterCounts.Counts?

    var body: some View {
        HStack(spacing: 12) {
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
                    AppLabel("\(counts?.total ?? 0)", systemName: "list.number", size: 17, relativeTo: .body)
                    if let badges = badges {
                        if badges.unread > 0 { AppLabel("\(badges.unread)", systemName: "eye.slash", size: 17, relativeTo: .body) }
                        if badges.new > 0 { AppLabel("\(badges.new)", systemName: "sparkles", size: 17, relativeTo: .body) }
                        if badges.downloaded > 0 { AppLabel("\(badges.downloaded)", systemName: "arrow.down.circle", size: 11, relativeTo: .caption2) }
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
