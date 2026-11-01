// UpdateRow.swift
// Single update entry showing book cover thumbnail and chapter info.

import SwiftUI

struct UpdateRow: View {
    let chapter: Chapter
    /// The cover opens the book; the rest of the row opens the chapter. Same
    /// split as `HistoryRow`, through the same `RowCoverButton`.
    var onOpenEntry: () -> Void = {}
    var onOpenChapter: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Book cover thumbnail
            if let entry = chapter.entry {
                RowCoverButton(entry: entry, action: onOpenEntry)
            }

            details
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenChapter)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(chapter.read ? "Read" : "Unread")
                .accessibilityHint("Opens the chapter")
        }
        .padding(.vertical, 4)
    }

    private var details: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // Book title
                if let entry = chapter.entry {
                    Text(entry.displayTitle)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Chapter name
                Text(chapter.name)
                    .font(Typography.body)
                    .foregroundStyle(chapter.read ? .secondary : .primary)
                    .lineLimit(2)

                // Release date
                if let released = chapter.dateUpload?.formatted {
                    Text(released)
                        .font(Typography.small)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Unread indicator
            if !chapter.read {
                Image(systemName: "circle.fill")
                    .font(Typography.small)
                    .imageScale(.small)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
        }
    }
}
