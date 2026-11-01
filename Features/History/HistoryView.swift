// HistoryView.swift
// Reading history screen showing recently read chapters.

import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(ReaderRouter.self) private var readerRouter
    @Environment(IncognitoMode.self) private var incognito
    @Namespace private var chapterTransitions
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \History.lastRead, order: .reverse)
    private var history: [History]

    /// Changes when the History tab is tapped again; opens the most recent chapter.
    var resumeTrigger = 0

    @State private var searchText = ""
    @State private var path = NavigationPath()
    @State private var showClearConfirmation = false
    /// Runs the user has opened, by `HistoryRun.id`.
    @State private var expandedRuns: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if filteredHistory.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if filteredHistory.isEmpty {
                    EmptyStateView(
                        icon: "clock",
                        title: "No Reading History",
                        subtitle: "Chapters you read will appear here."
                    )
                } else {
                    List {
                        ForEach(groupedHistory, id: \.key) { date, runs in
                            Section(date) {
                                ForEach(runs) { run in
                                    runRows(run)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationDestination(for: Entry.self) { entry in
                // A migrated entry takes the place of the one that left the library.
                NovelDetailView(entry: entry) { replacement in
                    if !path.isEmpty { path.removeLast() }
                    path.append(replacement)
                }
                .id(entry.persistentModelID)
            }
            .navigationTitle("History")
            .onChange(of: resumeTrigger) { resumeLatest() }
            .searchable(text: $searchText, prompt: "Search history")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    incognitoButton

                    if !history.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                    }
                }
            }
            // Attached here rather than inside the toolbar item: a dialog owned
            // by a toolbar button does not reliably present, which is why the
            // trash button appeared to do nothing.
            .confirmationDialog(
                "Clear all reading history?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive, action: clearAllHistory)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every entry from History. Your reading progress is kept.")
            }
        }
    }

    /// Stays in the toolbar, lit, for as long as nothing is being recorded, so
    /// incognito is never on without being visible.
    private var incognitoButton: some View {
        let on = incognito.isOn
        return Button {
            incognito.toggle()
            Haptics.shared.impact(.light, intensity: 0.8)
        } label: {
            Label(
                on ? "Incognito on" : "Incognito off",
                systemImage: on ? "eye.slash.fill" : "eye.slash"
            )
        }
        .tint(on ? AppTheme.warning : nil)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Rows

    /// A run's head row, then its earlier chapters when it is open.
    @ViewBuilder
    private func runRows(_ run: HistoryRun) -> some View {
        let isExpanded = expandedRuns.contains(run.id)
        HistoryRow(
            history: run.head,
            earlierCount: run.earlier.count,
            isExpanded: isExpanded,
            onOpenEntry: {
                if let entry = run.head.chapter?.entry { path.append(entry) }
            },
            onOpenChapter: { open(run.head) },
            onToggle: { toggle(run) }
        )
        .swipeActions {
            Button(role: .destructive) {
                delete([run.head])
            } label: {
                Label("Delete", systemImage: "trash")
            }
            if !isExpanded, !run.earlier.isEmpty {
                Button {
                    delete(run.items)
                } label: {
                    Label("Delete All", systemImage: "trash.fill")
                }
                .tint(AppTheme.warning)
            }
        }

        if isExpanded {
            ForEach(run.earlier) { item in
                HistoryChapterRow(history: item, onOpenChapter: { open(item) })
                    .swipeActions {
                        Button(role: .destructive) {
                            delete([item])
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    // MARK: - Filtering & Grouping

    private var filteredHistory: [History] {
        if searchText.isEmpty { return history }
        return history.filter { item in
            let bookTitle = item.chapter?.entry?.displayTitle ?? ""
            let chapterName = item.chapter?.name ?? ""
            return bookTitle.localizedCaseInsensitiveContains(searchText)
                || chapterName.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Day sections, each split into runs: back-to-back reads of the same
    /// entry collapse into one row. A run never crosses a day boundary.
    private var groupedHistory: [(key: String, value: [HistoryRun])] {
        let calendar = Calendar.current
        var buckets: [Date: [History]] = [:]
        for item in filteredHistory where item.chapter != nil {
            buckets[calendar.startOfDay(for: item.lastRead), default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { day in
            (day.daySectionTitle, HistoryRun.runs(of: buckets[day] ?? []))
        }
    }

    // MARK: - Actions

    private func open(_ item: History) {
        guard let chapter = item.chapter else { return }
        readerRouter.open(
            sourceKey: chapter.entry?.sourceKey ?? "",
            entryURL: chapter.entry?.url,
            kind: chapter.entry?.kind ?? .novel,
            chapterURL: chapter.url,
            chapterName: chapter.name
        )
    }

    private func toggle(_ run: HistoryRun) {
        Haptics.shared.impact(.light, intensity: 0.8)
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
            if expandedRuns.remove(run.id) == nil { expandedRuns.insert(run.id) }
        }
    }

    private func resumeLatest() {
        guard path.isEmpty, readerRouter.request == nil,
              let chapter = history.first(where: { $0.chapter != nil })?.chapter else { return }
        readerRouter.open(
            sourceKey: chapter.entry?.sourceKey ?? "",
            entryURL: chapter.entry?.url,
            kind: chapter.entry?.kind ?? .novel,
            chapterURL: chapter.url,
            chapterName: chapter.name
        )
    }

    private func delete(_ items: [History]) {
        // Delete through the view's own context. The old version opened a second
        // context in a detached task, so `@Query` never saw the change and the
        // row stayed on screen.
        for item in items { modelContext.delete(item) }
        try? modelContext.save()
    }

    private func clearAllHistory() {
        let items = history
        for item in items { modelContext.delete(item) }
        try? modelContext.save()
        expandedRuns.removeAll()
    }
}

/// Back-to-back history items for one entry, newest first.
struct HistoryRun: Identifiable {
    let items: [History]

    var head: History { items[0] }
    var earlier: ArraySlice<History> { items.dropFirst() }

    /// The oldest item's chapter, so reading on in the same entry keeps the
    /// run's id, and an open run stays open.
    var id: String { items[items.count - 1].chapterURL }

    /// Splits newest-first items wherever the entry changes. Items with no
    /// entry each stand alone.
    static func runs(of items: [History]) -> [HistoryRun] {
        var runs: [[History]] = []
        var lastEntry: PersistentIdentifier?
        for item in items {
            let entry = item.chapter?.entry?.persistentModelID
            if let entry, entry == lastEntry {
                runs[runs.count - 1].append(item)
            } else {
                runs.append([item])
            }
            lastEntry = entry
        }
        return runs.map(HistoryRun.init)
    }
}
