// UpdatesView.swift
// Feed of newly available chapters from library entries.

import SwiftData
import SwiftUI

struct UpdatesView: View {
    @Environment(ReaderRouter.self) private var readerRouter
    @Namespace private var chapterTransitions
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @State private var showClearConfirmation = false
    @State private var isClearing = false
    /// Chapters cleared in the background. The @Query is not refreshed reliably by a
    /// background save, so these are hidden here until the store catches up.
    @State private var clearedIDs: Set<PersistentIdentifier> = []

    @Query private var allRecentChapters: [Chapter]
    /// Tapping a cover pushes the book onto this stack, the way History does.
    @State private var path = NavigationPath()

    private var recentChapters: [Chapter] {
        clearedIDs.isEmpty ? allRecentChapters : allRecentChapters.filter { !clearedIDs.contains($0.persistentModelID) }
    }

    /// Newest-first, capped: grouping and diffing every chapter ever fetched
    /// froze the main thread for over a second on a large library.
    private static let feedLimit = 300

    init() {
        var descriptor = FetchDescriptor<Chapter>(
            predicate: #Predicate { $0.dateFetch != nil && !$0.hidden },
            sortBy: [SortDescriptor(\Chapter.dateFetch, order: .reverse)]
        )
        descriptor.fetchLimit = Self.feedLimit
        _allRecentChapters = Query(descriptor)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if recentChapters.isEmpty {
                    EmptyStateView(
                        icon: "bell.badge",
                        title: "No Updates",
                        subtitle: "New chapters from your library will appear here."
                    )
                    .refreshable {
                        // The update banner shows progress; the pull indicator
                        // has no job beyond starting the run. Sleeping here
                        // pinned it for 1.5 s while the update wrote to the
                        // store, leaving the list sitting in its pulled state.
                        let context = modelContext, sources = sourceManager
                        Task { await libraryManager.updateLibrary(context: context, sourceManager: sources) }
                    }
                } else {
                    List {
                        ForEach(groupedUpdates, id: \.key) { date, chapters in
                            Section(date) {
                                ForEach(chapters) { chapter in
                                    UpdateRow(
                                        chapter: chapter,
                                        onOpenEntry: {
                                            if let entry = chapter.entry { path.append(entry) }
                                        },
                                        onOpenChapter: {
                                            readerRouter.open(
                                                sourceKey: chapter.entry?.sourceKey ?? "",
                                                entryURL: chapter.entry?.url,
                                                kind: chapter.entry?.kind ?? .novel,
                                                chapterURL: chapter.url,
                                                chapterName: chapter.name
                                            )
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        // The update banner shows progress; the pull indicator
                        // has no job beyond starting the run. Sleeping here
                        // pinned it for 1.5 s while the update wrote to the
                        // store, leaving the list sitting in its pulled state.
                        let context = modelContext, sources = sourceManager
                        Task { await libraryManager.updateLibrary(context: context, sourceManager: sources) }
                    }
                }
            }
            .navigationTitle("Updates")
            .navigationDestination(for: Entry.self) { entry in
                // A migrated entry takes the place of the one that left the library.
                EntryDetailView(entry: entry) { replacement in
                    if !path.isEmpty { path.removeLast() }
                    path.append(replacement)
                }
                .id(entry.persistentModelID)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !recentChapters.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            if isClearing {
                                ProgressView()
                            } else {
                                Label("Clear Updates", systemImage: "trash")
                            }
                        }
                        .disabled(isClearing)
                    }

                    Button(action: {
                        Task {
                            await libraryManager.updateLibrary(context: modelContext, sourceManager: sourceManager)
                        }
                    }) {
                        if libraryManager.isUpdating {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(libraryManager.isUpdating)
                }
            }
            // Owned by the screen, not the toolbar button: a dialog attached
            // inside a toolbar item does not reliably present, which is why the
            // trash button appeared to do nothing.
            .confirmationDialog(
                "Are you sure you want to clear all updates?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    clearAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Clears every badge on a background context, with a spinner on the trash
    /// button meanwhile; nothing is mutated on the main thread.
    private func clearAll() {
        let container = modelContext.container
        let visible = Set(allRecentChapters.map(\.persistentModelID))
        isClearing = true
        Task {
            await libraryManager.clearUpdates(container: container)
            clearedIDs.formUnion(visible)
            isClearing = false
        }
    }

    // MARK: - Grouping

    /// Group chapters by the day they were fetched.
    private var groupedUpdates: [(key: String, value: [Chapter])] {
        let calendar = Calendar.current
        var buckets: [Date: [Chapter]] = [:]
        var undated: [Chapter] = []
        for chapter in recentChapters {
            guard let date = chapter.dateFetch else {
                undated.append(chapter)
                continue
            }
            buckets[calendar.startOfDay(for: date), default: []].append(chapter)
        }
        var groups = buckets.keys.sorted(by: >).map { day in
            (day.daySectionTitle, buckets[day] ?? [])
        }
        if !undated.isEmpty {
            groups.append(("Unknown", undated))
        }
        return groups
    }
}
