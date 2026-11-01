// BulkMigrateView.swift - Move every entry of one source to another source.
//
// Started by holding a source in Browse, because the source is the unit of the
// operation: "these books come from a site that is gone, find them elsewhere".
// Nothing changes until the user presses Migrate on the review screen.
//
// Matching and loading go through `MigrationPacer`, so a run of forty entries
// does not become forty bursts: one request at a time per source, spaced out,
// retried with exponential backoff, and a source that stops answering is left
// alone for a while instead of being asked again by every remaining entry.

import SwiftData
import SwiftUI

// MARK: - Model

@Observable
@MainActor
final class BulkMigrationModel {

    struct Row: Identifiable {
        enum State: Equatable {
            /// Not searched yet.
            case waiting
            case searching
            case matched
            /// Searched, nothing close enough to offer.
            case noMatch
            case migrating
            case done(MigrationOutcome)
            case failed(String)
        }

        let entry: Entry
        var candidate: MigrationCandidate?
        var state: State = .waiting
        /// Ticked for migration. Set from the score when a match arrives.
        var include = false
        /// Sources that did not answer for this row, for the detail line.
        var failedSources: [String] = []

        var id: PersistentIdentifier { entry.persistentModelID }
        var isReady: Bool { candidate != nil && state == .matched }
        var isSettled: Bool {
            switch state {
            case .waiting, .searching, .migrating: false
            case .matched, .noMatch, .done, .failed: true
            }
        }
    }

    private(set) var rows: [Row]
    private(set) var isMatching = false
    private(set) var isApplying = false
    /// Rows whose search has finished, for "Searching 12 of 34".
    private(set) var settledCount = 0
    /// Rows the current run has worked through, for "Migrating 3 of 12".
    private(set) var applyDone = 0
    private(set) var applyTotal = 0
    private(set) var didMatch = false

    /// Two entries in flight. Each one asks its sources in order, and the pacer
    /// keeps any single source down to one request at a time.
    private let concurrentEntries = 2

    init(entries: [Entry]) {
        rows = entries.map { Row(entry: $0) }
    }

    // MARK: Counts

    var selectedCount: Int { rows.count { $0.include && $0.isReady } }
    var matchedCount: Int { rows.count { if case .matched = $0.state { true } else { false } } }
    var doneCount: Int { rows.count { if case .done = $0.state { true } else { false } } }
    var failedCount: Int { rows.count { if case .failed = $0.state { true } else { false } } }
    var noMatchCount: Int { rows.count { if case .noMatch = $0.state { true } else { false } } }

    var totalCount: Int { rows.count }
    var searchProgress: Double { totalCount == 0 ? 0 : Double(settledCount) / Double(totalCount) }

    /// Every source that failed to answer anywhere in this run.
    var failedSources: [String] {
        Array(Set(rows.flatMap(\.failedSources))).sorted()
    }

    // MARK: Editing

    func setInclude(_ include: Bool, for id: PersistentIdentifier) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isReady else { return }
        rows[index].include = include
    }

    func choose(_ candidate: MigrationCandidate, for id: PersistentIdentifier) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].candidate = candidate
        rows[index].state = .matched
        rows[index].include = true
        rows[index].failedSources = []
    }

    // MARK: Matching

    /// Search every row that has not been searched, `concurrentEntries` at a time.
    func match(sources: [any CatalogSource]) async {
        guard !isMatching, !sources.isEmpty else { return }
        didMatch = true
        isMatching = true
        defer { isMatching = false }

        for index in rows.indices where rows[index].state == .waiting {
            rows[index].state = .searching
        }
        let work = rows.filter { $0.state == .searching }.map {
            ($0.id, MigrationSearch.titles(for: $0.entry), "\($0.entry.sourceKey)::\($0.entry.url)")
        }
        settledCount = rows.count { $0.isSettled }

        await withTaskGroup(of: (PersistentIdentifier, MigrationMatch).self) { group in
            var iterator = work.makeIterator()
            func launch() {
                guard let (id, titles, own) = iterator.next() else { return }
                group.addTask {
                    let match = await MigrationSearch.bestInPriority(
                        titles: titles, sources: sources, excluding: own)
                    return (id, match)
                }
            }
            for _ in 0..<concurrentEntries { launch() }
            for await (id, match) in group {
                if Task.isCancelled { break }
                record(match, for: id)
                launch()
            }
            group.cancelAll()
        }
    }

    /// Put a row back in the queue and search it again, by hand.
    func retry(_ id: PersistentIdentifier, sources: [any CatalogSource]) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        guard !rows[index].isReady else { return }
        rows[index].state = .waiting
        rows[index].candidate = nil
        rows[index].include = false
        rows[index].failedSources = []
        await match(sources: sources)
    }

    /// Reset every failed row and run again. Used by "Retry failed".
    func retryFailed(sources: [any CatalogSource]) async {
        for index in rows.indices {
            switch rows[index].state {
            case .noMatch, .failed:
                rows[index].state = .waiting
                rows[index].candidate = nil
                rows[index].include = false
                rows[index].failedSources = []
            default:
                continue
            }
        }
        settledCount = rows.count { $0.isSettled }
        await match(sources: sources)
    }

    private func record(_ match: MigrationMatch, for id: PersistentIdentifier) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].candidate = match.candidate
        rows[index].failedSources = match.failed
        rows[index].state = match.candidate == nil ? .noMatch : .matched
        // A weak match waits for the user to look at it; a strong one is ticked.
        rows[index].include = match.candidate?.isConfident == true
        settledCount = rows.count { $0.isSettled }
    }

    // MARK: Applying

    /// Migrate the ticked rows one at a time, so one failure cannot take the
    /// rest of the run with it.
    func apply(
        options: MigrationOptions,
        sourceManager: SourceManager,
        libraryManager: LibraryManager,
        context: ModelContext
    ) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let queue = rows.filter { $0.include && $0.isReady }.map(\.id)
        applyTotal = queue.count
        applyDone = 0
        await MigrationPacer.shared.reset()

        for id in queue {
            if Task.isCancelled { break }
            // One frame between entries: the insert builds the new entry's chapters
            // on the main actor, and without a breath the progress bar would only
            // jump at the end of the run.
            try? await Task.sleep(for: .milliseconds(16))
            guard let index = rows.firstIndex(where: { $0.id == id }),
                  let candidate = rows[index].candidate else { continue }
            rows[index].state = .migrating
            guard let source = sourceManager.source(forKey: candidate.entry.sourceKey) else {
                rows[index].state = .failed(MigrationError.sourceMissing.errorDescription ?? "Source missing")
                applyDone += 1
                continue
            }
            do {
                let loaded = try await MigrationSearch.load(candidate, from: source)
                let result = EntryMigrator.migrate(
                    rows[index].entry, to: loaded.details, chapters: loaded.chapters,
                    options: options, context: context, libraryManager: libraryManager)
                rows[index].state = .done(result.outcome)
                rows[index].include = false
            } catch is CancellationError {
                rows[index].state = .matched
                break
            } catch {
                rows[index].state = .failed(error.localizedDescription)
            }
            applyDone += 1
        }
        // One cue for the run, not one per entry, and none if it was abandoned.
        if !Task.isCancelled && !queue.isEmpty {
            Haptics.shared.notify(failedCount > 0 ? .warning : .success)
        }
    }
}

// MARK: - Step 1: what and where

/// Migrate every library entry that came from one source.
struct MigrateSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager

    let sourceKey: String
    /// Called when the user is done. The presenter closes the sheet.
    let onFinished: () -> Void

    @Query private var entries: [Entry]

    @State private var options = MigrationOptions()
    @State private var showSources = false
    @State private var isReviewing = false

    init(sourceKey: String, onFinished: @escaping () -> Void) {
        self.sourceKey = sourceKey
        self.onFinished = onFinished
        _entries = Query(
            filter: #Predicate<Entry> { $0.inLibrary && $0.sourceKey == sourceKey },
            sort: [SortDescriptor(\Entry.title)])
    }

    private var source: (any CatalogSource)? { sourceManager.source(forKey: sourceKey) }
    private var destinations: [any CatalogSource] {
        MigrationSources.destinations(for: kind, in: sourceManager, excluding: sourceKey)
    }
    /// One kind per source; the registry only holds one anyway.
    private var kind: ContentKind { entries.first?.kind ?? source?.kind ?? .novel }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        if let source { SourceIconView(source: source, size: 40) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source?.name ?? sourceKey)
                                .font(Typography.headline)
                                .lineLimit(1)
                            Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries") in your library")
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    Button { showSources = true } label: {
                        HStack {
                            Text("Search in").foregroundStyle(.primary)
                            Spacer()
                            Text(destinationSummary).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                } footer: {
                    Text("Each entry takes the first source here with a strong title match.")
                }

                MigrationOptionsSection(options: $options)
                MigrationCleanupSection(options: $options)
            }
            .navigationTitle("Migrate source")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { footerBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showSources) {
                NavigationStack { MigrationSourcesView(kind: kind, current: sourceKey) }
                    .presentationDetents([.medium, .large])
            }
            .navigationDestination(isPresented: $isReviewing) {
                BulkMigrateReviewView(
                    entries: entries, kind: kind, sourceKey: sourceKey, options: options,
                    onFinished: onFinished)
            }
        }
    }

    private var destinationSummary: String {
        switch destinations.count {
        case 0: "None"
        case 1: destinations[0].name
        default: "\(destinations[0].name) + \(destinations.count - 1)"
        }
    }

    private var footerBar: some View {
        VStack(spacing: 6) {
            Button("Find matches") { isReviewing = true }
                .primaryActionStyle()
                .disabled(entries.isEmpty || destinations.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }
}

// MARK: - Step 2: review and run

struct BulkMigrateReviewView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.modelContext) private var modelContext

    let kind: ContentKind
    let sourceKey: String
    let options: MigrationOptions
    let onFinished: () -> Void

    @State private var model: BulkMigrationModel
    @State private var changing: Entry?

    init(entries: [Entry], kind: ContentKind, sourceKey: String, options: MigrationOptions, onFinished: @escaping () -> Void) {
        self.kind = kind
        self.sourceKey = sourceKey
        self.options = options
        self.onFinished = onFinished
        _model = State(initialValue: BulkMigrationModel(entries: entries))
    }

    private var destinations: [any CatalogSource] {
        MigrationSources.destinations(for: kind, in: sourceManager, excluding: sourceKey)
    }

    private var isBusy: Bool { model.isMatching || model.isApplying }

    /// The title only claims "Migrated" once the run is over and nothing is left
    /// ticked; mid-run it would be a half-truth that keeps changing.
    private var title: String {
        if model.doneCount > 0 && model.selectedCount == 0 && !isBusy {
            return "Migrated \(model.doneCount)"
        }
        return "Matches"
    }

    var body: some View {
        List {
            Section {
                header
            }
            ForEach(model.rows) { row in
                reviewRow(row)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(item: $changing) { entry in
            NavigationStack {
                MigrationCandidatePicker(entry: entry) { candidate in
                    model.choose(candidate, for: entry.persistentModelID)
                    changing = nil
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changing = nil } } }
            }
        }
        .task {
            guard !model.didMatch else { return }
            await model.match(sources: destinations)
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isMatching {
                Text("Searching \(min(model.settledCount + 1, model.totalCount)) of \(model.totalCount)")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: model.searchProgress)
            } else if model.isApplying {
                Text("Migrating \(min(model.applyDone + 1, model.applyTotal)) of \(model.applyTotal)")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                ProgressView(
                    value: Double(model.applyDone),
                    total: Double(max(1, model.applyTotal)))
            } else {
                Text(summaryLine)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.failedSources.isEmpty && !model.isMatching {
                Text("\(model.failedSources.joined(separator: ", ")) did not answer. Retry once they are back.")
                    .font(Typography.small)
                    .foregroundStyle(AppTheme.warning)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var summaryLine: String {
        let matched = model.matchedCount
        if matched == 0 && model.noMatchCount == 0 { return "Nothing to match." }
        var parts = ["\(matched) of \(model.totalCount) matched"]
        if model.noMatchCount > 0 { parts.append("\(model.noMatchCount) with no match") }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        let notMatched = model.failedCount + model.noMatchCount
        VStack(spacing: 6) {
            if isBusy {
                Button(model.isApplying ? "Migrating…" : "Searching…") {}
                    .primaryActionStyle()
                    .disabled(true)
            } else if model.selectedCount > 0 {
                Button("Migrate \(model.selectedCount)", action: apply).primaryActionStyle()
                if notMatched > 0 {
                    Button("Retry \(notMatched) not matched") {
                        Task { await model.retryFailed(sources: destinations) }
                    }
                    .font(Typography.caption)
                }
            } else if notMatched > 0 {
                Button("Retry \(notMatched) not matched") {
                    Task { await model.retryFailed(sources: destinations) }
                }
                .primaryActionStyle()
                Button("Done", action: onFinished).font(Typography.caption)
            } else if model.doneCount > 0 {
                Button("Done", action: onFinished).primaryActionStyle()
            } else {
                Button("Nothing selected") {}
                    .primaryActionStyle()
                    .disabled(true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    private func apply() {
        Task {
            await model.apply(
                options: options, sourceManager: sourceManager,
                libraryManager: libraryManager, context: modelContext)
        }
    }

    // MARK: Rows

    private func reviewRow(_ row: BulkMigrationModel.Row) -> some View {
        HStack(spacing: 12) {
            EntryCoverView(url: row.entry.displayThumbnailURL).frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.entry.displayTitle).font(Typography.headline).lineLimit(1)
                detail(row)
            }
            Spacer(minLength: 8)
            trailing(row)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(row) }
    }

    @ViewBuilder private func detail(_ row: BulkMigrationModel.Row) -> some View {
        switch row.state {
        case .waiting, .searching:
            Text("Searching…").font(Typography.caption).foregroundStyle(.secondary)
        case .noMatch:
            Text(noMatchLine(row)).font(Typography.caption).foregroundStyle(AppTheme.warning).lineLimit(2)
        case .matched, .migrating:
            if let candidate = row.candidate {
                Text("\(candidate.entry.title) · \(candidate.sourceName)")
                    .font(Typography.caption)
                    .foregroundStyle(candidate.isConfident ? Color.secondary : AppTheme.warning)
                    .lineLimit(1)
            }
        case .done(let outcome):
            Text(outcome.oldWithState == 0
                ? "Migrated"
                : "Migrated · \(outcome.carried) of \(outcome.oldWithState) carried")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(Typography.caption).foregroundStyle(AppTheme.warning).lineLimit(2)
        }
    }

    private func noMatchLine(_ row: BulkMigrationModel.Row) -> String {
        guard !row.failedSources.isEmpty else { return "No match. Tap to search." }
        return "No match · \(row.failedSources.joined(separator: ", ")) did not answer"
    }

    @ViewBuilder private func trailing(_ row: BulkMigrationModel.Row) -> some View {
        switch row.state {
        case .waiting, .searching, .migrating:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark").foregroundStyle(.secondary)
        case .noMatch, .failed:
            Button {
                Task { await model.retry(row.id, sources: destinations) }
            } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search again")
        case .matched:
            Button {
                model.setInclude(!row.include, for: row.id)
            } label: {
                Image(systemName: row.include ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.include ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.include ? "Will migrate" : "Will not migrate")
        }
    }

    private func tap(_ row: BulkMigrationModel.Row) {
        switch row.state {
        case .waiting, .searching, .migrating, .done: return
        case .matched, .noMatch, .failed: changing = row.entry
        }
    }
}
