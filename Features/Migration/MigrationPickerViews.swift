// MigrationPickerViews.swift - Choosing where an entry moves to.
//
// One sheet, two steps: search every destination source, then confirm on a screen
// that shows what moves, what carries over and what is left behind. The confirm
// screen reports the outcome instead of closing over it.

import SwiftData
import SwiftUI

// MARK: - Origin

/// "What you are moving", at the top of the picker, so the sheet still makes
/// sense on its own (its navigation title is just "Migrate").
struct MigrationOriginRow: View {
    let entry: Entry
    let sourceName: String

    var body: some View {
        HStack(spacing: 12) {
            EntryCoverView(url: entry.displayThumbnailURL)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(Typography.headline)
                    .lineLimit(2)
                Text(sourceName)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Candidate picker

struct MigrationCandidatePicker: View {
    @Environment(SourceManager.self) private var sourceManager

    let entry: Entry
    let onPick: (MigrationCandidate) -> Void

    @State private var query = ""
    @State private var results: [MigrationCandidate] = []
    @State private var failedSources: [String] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var showSources = false

    private var originName: String {
        sourceManager.source(forKey: entry.sourceKey)?.name ?? entry.sourceKey
    }

    private var destinations: [any CatalogSource] {
        MigrationSources.destinations(for: entry.kind, in: sourceManager, excluding: entry.sourceKey)
    }

    var body: some View {
        List {
            Section {
                MigrationOriginRow(entry: entry, sourceName: "Currently in \(originName)")
            }

            // The result states are rows rather than an overlay, so what is being
            // moved stays on screen while the sources are searched.
            if isSearching && results.isEmpty {
                Section {
                    LoadingView(message: "Searching sources…")
                        .frame(height: 140)
                        .listRowSeparator(.hidden)
                }
            } else if results.isEmpty {
                Section {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No matches",
                        subtitle: "Try a shorter title, or choose other sources.")
                        .frame(height: 200)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(results) { candidate in
                        Button { onPick(candidate) } label: { MigrationCandidateRow(candidate: candidate) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text("Move to")
                } footer: {
                    footer
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Migrate")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search by title")
        .autocorrectionDisabled()
        .onSubmit(of: .search) { Task { await search() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSources = true } label: { Label("Sources", systemImage: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showSources, onDismiss: { Task { await search() } }) {
            NavigationStack { MigrationSourcesView(kind: entry.kind, current: entry.sourceKey) }
                .presentationDetents([.medium, .large])
        }
        .task {
            guard !didSearch else { return }
            didSearch = true
            query = entry.displayTitle
            await search()
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if destinations.count > 1 {
                Text("Searching \(destinations.count) sources.")
            }
            if !failedSources.isEmpty {
                Text("\(failedSources.joined(separator: ", ")) did not answer.")
                    .foregroundStyle(AppTheme.warning)
            }
        }
    }

    private func search() async {
        let sources = destinations
        isSearching = true
        results = []
        let result = await MigrationSearch.candidates(
            titles: MigrationSearch.titles(for: entry),
            sources: sources,
            query: query.isEmpty ? nil : query,
            excluding: "\(entry.sourceKey)::\(entry.url)")
        results = result.hits
        failedSources = result.failed
        isSearching = false
    }
}

struct MigrationCandidateRow: View {
    @Environment(SourceManager.self) private var sourceManager

    let candidate: MigrationCandidate

    var body: some View {
        HStack(spacing: 12) {
            EntryCoverView(url: candidate.entry.thumbnailURL)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.entry.title)
                    .font(Typography.headline)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let source = sourceManager.source(forKey: candidate.entry.sourceKey) {
                        SourceIconView(source: source, size: 14)
                    }
                    Text(candidate.sourceName)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if candidate.score >= 1 {
                Text("Exact").font(Typography.small).foregroundStyle(.secondary)
            } else if candidate.isConfident {
                Text("Close").font(Typography.small).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Destination sources

/// Which sources to search, and the order they are tried in. One list per content
/// kind, reused by every migration.
struct MigrationSourcesView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.dismiss) private var dismiss

    let kind: ContentKind
    /// The source the current migration is moving away from. It stays in the list
    /// (it is part of the saved order) but is never searched for this run.
    var current: String? = nil

    @State private var enabled: [String] = []
    @State private var loaded = false

    private var available: [any CatalogSource] { sourceManager.sources(of: kind) }

    private var off: [any CatalogSource] { available.filter { !enabled.contains($0.key) } }

    var body: some View {
        List {
            Section {
                ForEach(enabled, id: \.self) { key in
                    HStack {
                        Text(name(of: key))
                        if key == current {
                            Spacer()
                            Text("Current")
                                .font(Typography.small)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { enabled.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { enabled.remove(atOffsets: $0) }
            } header: {
                Text("Tried, in this order")
            } footer: {
                Text("Each entry takes the first source here with a strong title match. "
                    + "The entry's own source is marked Current and is never searched. "
                    + "This list is kept for the next migration of this kind.")
            }

            if !off.isEmpty {
                Section("Not tried") {
                    ForEach(off, id: \.key) { source in
                        Button { enabled.append(source.key) } label: {
                            HStack {
                                Text(source.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Migration sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if enabled.count > 1 { EditButton() }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.bold() }
        }
        .onAppear {
            guard !loaded else { return }
            enabled = MigrationSources.ordered(for: kind, in: sourceManager).map(\.key)
            loaded = true
        }
        .onChange(of: enabled) { _, keys in
            // The store decides what is worth saving (an empty list is not).
            if loaded { MigrationSources.save(keys, for: kind) }
        }
    }

    private func name(of key: String) -> String { sourceManager.source(forKey: key)?.name ?? key }
}

// MARK: - Options (shared with the bulk flow)

struct MigrationOptionsSection: View {
    @Binding var options: MigrationOptions

    var body: some View {
        Section {
            Toggle("Reading progress", isOn: $options.carryProgress)
            Toggle("Categories", isOn: $options.carryCategories)
            Toggle("Tracking", isOn: $options.carryTracking)
        } header: {
            Text("Carry over")
        } footer: {
            Text("The old entry leaves your library. Its chapters and history stay behind, so read state is not lost if you add it back.")
        }
    }
}

/// The one irreversible choice, kept out of the carry toggles so it is not
/// switched on by muscle memory.
struct MigrationCleanupSection: View {
    @Binding var options: MigrationOptions

    var body: some View {
        Section {
            Toggle("Delete its downloads", isOn: $options.deleteOldDownloads)
        } header: {
            Text("Old entry")
        } footer: {
            Text("Off keeps the downloaded chapters on disk. On frees the space and cannot be undone.")
        }
    }
}

// MARK: - Single entry: confirm

struct MigrateConfirmView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let old: Entry
    let candidate: MigrationCandidate
    /// Handed the entry the user now has, so the presenter can open it.
    let onFinished: (Entry) -> Void

    private enum Phase: Equatable {
        case loading, ready, running, done(MigrationOutcome)
        case failed(String)
    }

    @State private var options = MigrationOptions()
    @State private var phase: Phase = .loading
    @State private var loaded: (details: SourceEntry, chapters: [SourceChapter])?
    /// The entry this migration created, kept for the Done button.
    @State private var migrated: Entry?

    private var originName: String {
        sourceManager.source(forKey: old.sourceKey)?.name ?? old.sourceKey
    }

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                MigrationOriginRow(entry: old, sourceName: originName)
            } header: {
                Text("From")
            }

            Section {
                MigrationCandidateRow(candidate: candidate)
            } header: {
                HStack {
                    Text("To")
                    Spacer()
                    Button("Change") { dismiss() }
                        .font(Typography.caption)
                        .textCase(nil)
                }
            } footer: {
                summary
            }

            if !isDone {
                MigrationOptionsSection(options: $options)
                MigrationCleanupSection(options: $options)
            }
        }
        .navigationTitle("Migrate")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { footerBar }
        .task {
            // One fetch per visit: the chapter list is the expensive part.
            guard loaded == nil, phase != .running else { return }
            await load()
        }
    }

    @ViewBuilder private var summary: some View {
        switch phase {
        case .failed(let message):
            Text(message).foregroundStyle(AppTheme.warning)
        case .loading:
            Text("Loading chapters…")
        case .ready, .running, .done:
            if let loaded {
                let carry = MigrationSearch.previewCarry(
                    from: old, into: loaded.chapters, title: candidate.entry.title)
                Text("\(loaded.chapters.count) chapters. " + carrySentence(carry))
            }
        }
    }

    private func carrySentence(_ carry: MigrationOutcome) -> String {
        guard carry.oldWithState > 0 else { return "Nothing read yet, so only the entry moves." }
        let carried = "\(carry.carried) of \(carry.oldWithState) read or bookmarked chapters carry over."
        guard carry.missed > 0 else { return carried }
        return carried + " \(carry.missed) have no match in the new source."
    }

    @ViewBuilder private var footerBar: some View {
        VStack(spacing: 6) {
            if case .done(let outcome) = phase {
                Text(doneSentence(outcome))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") {
                    if let migrated { onFinished(migrated) }
                }
                .primaryActionStyle()
            } else if case .failed = phase {
                // A source that did not answer is worth one more ask.
                Button("Try again") { Task { await load() } }
                    .primaryActionStyle()
            } else {
                Button(action: migrate) {
                    if case .running = phase {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Migrating…")
                        }
                    } else {
                        Text("Migrate")
                    }
                }
                .primaryActionStyle()
                .disabled(loaded == nil || phase != .ready)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    private func doneSentence(_ outcome: MigrationOutcome) -> String {
        guard outcome.oldWithState > 0 else { return "Migrated." }
        return "Migrated. \(outcome.carried) of \(outcome.oldWithState) chapters carried over."
    }

    private func load() async {
        guard let source = sourceManager.source(forKey: candidate.entry.sourceKey) else {
            phase = .failed(MigrationError.sourceMissing.errorDescription ?? "Source missing.")
            return
        }
        phase = .loading
        do {
            loaded = try await MigrationSearch.load(candidate, from: source)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func migrate() {
        guard let loaded, phase == .ready else { return }
        phase = .running
        Task { @MainActor in
            // One frame, so the spinner is on screen before the insert runs: the
            // new entry's chapters are built on the main actor by `LibraryManager`.
            try? await Task.sleep(for: .milliseconds(16))
            let result = EntryMigrator.migrate(
                old, to: loaded.details, chapters: loaded.chapters,
                options: options, context: modelContext, libraryManager: libraryManager)
            migrated = result.entry
            phase = .done(result.outcome)
            Haptics.shared.notify(.success)
        }
    }
}

// MARK: - Single entry: sheet

/// Migrate one entry: pick a match, confirm, read the outcome.
struct MigrateEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: Entry
    /// Called with the new entry once the user has seen the outcome. The presenter
    /// closes the sheet and shows that entry.
    let onFinished: (Entry) -> Void

    @State private var path: [MigrationCandidate] = []

    var body: some View {
        NavigationStack(path: $path) {
            MigrationCandidatePicker(entry: entry) { path.append($0) }
                .navigationDestination(for: MigrationCandidate.self) { candidate in
                    MigrateConfirmView(old: entry, candidate: candidate, onFinished: onFinished)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}
