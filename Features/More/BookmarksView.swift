// BookmarksView.swift
// The saved-highlight store: books that have highlights, then one book's
// highlights grouped by chapter.

import SwiftData
import SwiftUI

struct BookmarksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]
    @Query private var entries: [Entry]

    private var books: [BookmarkBook] {
        let entriesByKey = entryLookup
        let grouped = Dictionary(grouping: highlights, by: \.entryKey)
        return grouped.compactMap { key, items -> BookmarkBook? in
            guard let first = items.first else { return nil }
            let entry = entriesByKey[key]
            return BookmarkBook(
                id: key,
                sourceKey: first.sourceKey,
                entryURL: first.entryURL,
                title: entry?.displayTitle ?? first.displayBookTitle,
                coverURL: entry?.displayThumbnailURL ?? first.bookCoverURL,
                highlights: items.sorted { $0.createdAt > $1.createdAt }
            )
        }
        .sorted { lhs, rhs in
            (lhs.highlights.first?.createdAt ?? .distantPast) > (rhs.highlights.first?.createdAt ?? .distantPast)
        }
    }

    private var entryLookup: [String: Entry] {
        var lookup: [String: Entry] = [:]
        for entry in entries {
            let key = Highlight.entryKey(sourceKey: entry.sourceKey, entryURL: entry.url)
            if lookup[key] == nil { lookup[key] = entry }
        }
        return lookup
    }

    var body: some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView(
                    "No bookmarks yet",
                    systemImage: "highlighter",
                    description: Text("Select text while reading to save a highlight. It will appear here, grouped by book and chapter.")
                )
            } else {
                List {
                    ForEach(books) { book in
                        AppNavigationLink {
                            BookmarkedBookView(
                                sourceKey: book.sourceKey,
                                entryURL: book.entryURL,
                                fallbackTitle: book.title
                            )
                        } label: {
                            BookmarkBookRow(book: book)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .settingsScreen("Bookmarks")
    }
}

// MARK: - Grouping

private struct BookmarkBook: Identifiable {
    let id: String
    let sourceKey: String
    let entryURL: String?
    let title: String
    let coverURL: String?
    let highlights: [Highlight]

    var chapterCount: Int {
        Set(highlights.map(\.chapterURL)).count
    }
}

private struct BookmarkedChapter: Identifiable {
    let id: String
    let name: String
    let number: Double
    let sourceOrder: Int
    let highlights: [Highlight]
}

private struct BookmarkBookRow: View {
    let book: BookmarkBook

    var body: some View {
        HStack(spacing: 14) {
            EntryCoverView(url: book.coverURL, cornerRadius: 6)
                .frame(width: 44, height: 66)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(book.highlights.count) \(book.highlights.count == 1 ? "highlight" : "highlights") · \(book.chapterCount) \(book.chapterCount == 1 ? "chapter" : "chapters")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One book

private struct BookmarkedBookView: View {
    let sourceKey: String
    let entryURL: String?
    let fallbackTitle: String

    @Environment(ReaderRouter.self) private var readerRouter
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Highlight.createdAt, order: .reverse) private var allHighlights: [Highlight]
    @Query private var entries: [Entry]

    private var entryKey: String {
        Highlight.entryKey(sourceKey: sourceKey, entryURL: entryURL)
    }

    private var highlights: [Highlight] {
        allHighlights.filter { $0.entryKey == entryKey }
    }

    private var entry: Entry? {
        entries.first {
            Highlight.entryKey(sourceKey: $0.sourceKey, entryURL: $0.url) == entryKey
        }
    }

    private var title: String {
        entry?.displayTitle ?? fallbackTitle
    }

    private var chapters: [BookmarkedChapter] {
        Dictionary(grouping: highlights, by: \.chapterURL)
            .compactMap { url, items -> BookmarkedChapter? in
                guard let first = items.first else { return nil }
                return BookmarkedChapter(
                    id: url,
                    name: first.chapterName,
                    number: first.chapterNumber,
                    sourceOrder: first.sourceOrder,
                    highlights: items.sorted {
                        $0.paragraphIndex == $1.paragraphIndex
                            ? $0.startOffset < $1.startOffset
                            : $0.paragraphIndex < $1.paragraphIndex
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.number < 0 || rhs.number < 0 {
                    if lhs.number < 0 && rhs.number < 0 {
                        return lhs.sourceOrder < rhs.sourceOrder
                    }
                    return rhs.number < 0
                }
                if lhs.number != rhs.number { return lhs.number < rhs.number }
                if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        Group {
            if chapters.isEmpty {
                ContentUnavailableView(
                    "No bookmarks left",
                    systemImage: "highlighter",
                    description: Text("Highlights you delete here are removed from the page too.")
                )
            } else {
                List {
                    ForEach(chapters) { chapter in
                        Section(chapter.name) {
                            ForEach(chapter.highlights) { highlight in
                                Button {
                                    open(highlight: highlight)
                                } label: {
                                    HighlightRow(highlight: highlight)
                                }
                                .buttonStyle(AppPlainButtonStyle())
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(highlight)
                                        try? modelContext.save()
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .settingsScreen(title)
    }

    private func open(highlight: Highlight) {
        Haptics.shared.impact(.light)
        readerRouter.open(
            sourceKey: highlight.sourceKey,
            entryURL: highlight.entryURL,
            kind: .novel,
            chapterURL: highlight.chapterURL,
            chapterName: highlight.chapterName,
            paragraphIndex: highlight.paragraphIndex
        )
    }
}

private struct HighlightRow: View {
    let highlight: Highlight

    private var color: ReaderHighlightColor? {
        ReaderHighlightColor(rawValue: highlight.color)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color?.swatchColor ?? Color.secondary)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                Text(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the chapter at this highlight")
    }
}
