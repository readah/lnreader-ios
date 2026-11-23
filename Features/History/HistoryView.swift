// HistoryView.swift
// Reading history screen showing recently read chapters.

import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(ReaderRouter.self) private var readerRouter
    @Environment(IncognitoMode.self) private var incognito
    @Environment(LibraryManager.self) private var libraryManager
    @Namespace private var chapterTransitions
    @Environment(\.modelContext) private var modelContext
    @Query private var history: [History]

    /// Changes when the History tab is tapped again; opens the most recent chapter.
    var resumeTrigger = 0

    @State private var searchText = ""
    @State private var path = NavigationPath()
    @State private var showClearConfirmation = false
    /// Runs the user has opened, by `HistoryRun.id`.
    @State private var expandedRuns: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isReaderPresented) private var isReaderPresented
    /// The last list shown. History stays mounted under the reader, and every
    /// progress save re-runs `@Query` here: a fetch plus an in-memory sort of
    /// every row, on the main thread, mid-scroll. While the reader is open nothing
    /// here can be seen, so the list is held and rebuilt when the reader closes.
    @State private var held = HeldItems<History>()

    init(resumeTrigger: Int = 0) {
        self.resumeTrigger = resumeTrigger
        _history = Query(FeedQueries.history)
    }

    var body: some View {
        AppNavigationStack(path: $path) {
            Group {
                if filteredHistory.isEmpty, !searchText.isEmpty {
                    ScrollView {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, minHeight: 300)
                    }
                } else if filteredHistory.isEmpty {
                    ScrollView {
                        EmptyStateView(
                            icon: "clock",
                            title: "No Reading History",
                            subtitle: "Chapters you read will appear here."
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                } else {
                    List {
                        ForEach(groupedHistory, id: \.key) { date, runs in
                            Section(date) {
                                ForEach(runs) { run in
                                    runRows(run)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .appRefreshable("Refresh history") {
                libraryManager.flushProgress(context: modelContext)
                held.items = nil
                modelContext.processPendingChanges()
            }
            .appNavigationDestination(for: Entry.self) { entry in
                // A migrated entry takes the place of the one that left the library.
                EntryDetailView(entry: entry) { replacement in
                    if !path.isEmpty { path.removeLast() }
                    path.append(replacement)
                }
                .id(entry.persistentModelID)
            }
            .appNavigationTitle("History")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AppExpandableSearchBar(text: $searchText, prompt: "Search history")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .onChange(of: resumeTrigger) { resumeLatest() }
            .appToolbar {
                AppToolbarItemGroup(placement: .primaryAction) {
                    incognitoButton

                    if !history.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            AppLabel("Clear History", systemName: "trash", size: 17, relativeTo: .body)
                        }
                    }
                }
            }
            // Attached here rather than inside the toolbar item: a dialog owned
            // by a toolbar button does not reliably present, which is why the
            // trash button appeared to do nothing.
            .appConfirmationDialog(
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
            AppLabel(on ? "Incognito on" : "Incognito off", systemName: on ? "eye.slash.fill" : "eye.slash", size: 17, relativeTo: .body)
        }
        // Glass mode keeps the ordinary toolbar button: no bespoke pill, just
        // the yellow icon. Only classic chrome needs its own button style.
        .tint(on ? AppTheme.warning : nil)
        .modifier(ClassicIncognitoStyle(on: on))
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
        .listRowBackground(Color.clear)
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
                    .listRowBackground(Color.clear)
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
        if isReaderPresented, let items = held.items { return items }
        let result: [History]
        if searchText.isEmpty {
            result = history
        } else {
            result = history.filter { item in
                let bookTitle = item.chapter?.entry?.displayTitle ?? ""
                let chapterName = item.chapter?.name ?? ""
                return bookTitle.localizedCaseInsensitiveContains(searchText)
                    || chapterName.localizedCaseInsensitiveContains(searchText)
            }
        }
        held.items = result
        return result
    }

    /// Day sections, each split into runs: back-to-back reads of the same
    /// entry collapse into one row. A run never crosses a day boundary.
    private var groupedHistory: [(key: String, items: [HistoryRun])] {
        DaySections.of(filteredHistory, date: { $0.lastRead }, rows: HistoryRun.runs(of:))
    }

    // MARK: - Actions

    private func open(_ item: History) {
        guard let chapter = item.chapter else { return }
        readerRouter.open(chapter)
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
        readerRouter.open(chapter)
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

/// Classic chrome gives the lit incognito state a yellow icon; glass mode
/// inherits the normal toolbar button and only uses the tint.
private struct ClassicIncognitoStyle: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let on: Bool
    func body(content: Content) -> some View {
        if classic {
            content
                .buttonStyle(ClassicChromeButtonStyle())
                .foregroundStyle(on ? AppTheme.warning : AppTheme.accent)
        } else {
            content
        }
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
