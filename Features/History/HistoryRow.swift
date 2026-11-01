// HistoryRow.swift
// Single history entry showing the book, chapter, and time ago. When the same
// book was read several times in a row, the newest read heads the run and a
// count pill opens the earlier chapters beneath it as `HistoryChapterRow`s.

import SwiftUI

struct HistoryRow: View {
    let history: History
    /// Earlier reads of the same entry folded under this row; 0 shows no pill.
    var earlierCount = 0
    var isExpanded = false
    /// Tapping the cover opens the entry; tapping anywhere else opens the chapter.
    var onOpenEntry: () -> Void = {}
    var onOpenChapter: () -> Void = {}
    var onToggle: () -> Void = {}
    @Environment(SourceManager.self) private var sourceManager

    private var entry: Entry? { history.chapter?.entry }

    private var sourceName: String {
        guard let entry else { return "" }
        return sourceManager.source(forKey: entry.sourceKey)?.name
            ?? SourceKey.identifier(from: entry.sourceKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            RowCoverButton(entry: entry, stacked: earlierCount > 0 && !isExpanded, action: onOpenEntry)

            HStack(spacing: 12) {
                details
                Spacer()
                Text(history.lastRead.timeAgo)
                    .font(Typography.small)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenChapter)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue((history.chapter?.read ?? false) ? "Read" : "Unread")
            .accessibilityHint("Opens the chapter")

            if earlierCount > 0 {
                RunToggle(count: earlierCount, isExpanded: isExpanded, action: onToggle)
            }
        }
        .padding(.vertical, 4)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
                Text(entry?.displayTitle ?? "Unknown")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(history.chapter?.name ?? "")
                    .font(Typography.body)
                    .foregroundStyle((history.chapter?.read ?? false) ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(sourceName)
                        .font(Typography.small)
                        .foregroundStyle(.tertiary)

                    if let progress = history.chapter?.progress, progress > 0, progress < 100 {
                        Text("\(Int(progress))%")
                            .font(Typography.small)
                            .foregroundStyle(.secondary)
                    }
                }
            }
    }
}

/// The pill on a run's head row: how many earlier chapters it holds, and a
/// chevron that turns when they are showing.
private struct RunToggle: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        // Expanded is on, folded is off: a toggle button, not a hand-drawn pill.
        Toggle(isOn: Binding(get: { isExpanded }, set: { _ in action() })) {
            HStack(spacing: 3) {
                Text("+\(count)")
                    .font(Typography.small.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(Typography.small.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
            }
        }
        .toggleStyle(.button)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(AppTheme.primaryFill)
        .accessibilityLabel(isExpanded ? "Hide earlier chapters" : "Show \(count) earlier chapters")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// An earlier chapter inside an open run. The book is already named by the
/// head row, so this is the chapter, its progress and when, set in from the
/// cover column with a rail tying it to the head.
struct HistoryChapterRow: View {
    let history: History
    var onOpenChapter: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Divider()
                .frame(width: 44)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(history.chapter?.name ?? "")
                        .font(Typography.body)
                        .foregroundStyle((history.chapter?.read ?? false) ? .secondary : .primary)
                        .lineLimit(1)

                    if let progress = history.chapter?.progress, progress > 0, progress < 100 {
                        Text("\(Int(progress))%")
                            .font(Typography.small)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(history.lastRead.timeAgo)
                    .font(Typography.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenChapter)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue((history.chapter?.read ?? false) ? "Read" : "Unread")
        .accessibilityHint("Opens the chapter")
    }
}
