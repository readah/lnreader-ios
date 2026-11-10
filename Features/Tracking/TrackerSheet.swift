// TrackerSheet.swift
// Bind a library title to AniList and edit its list entry.

import SwiftData
import SwiftUI

struct TrackerSheet: View {
    let entry: Entry
    @Environment(TrackingManager.self) private var tracking
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [TrackSearchResult] = []
    @State private var isBusy = false
    @State private var error: String?
    @State private var confirmRemove = false
    @State private var searchTask: Task<Void, Never>?
    /// The title picked from search. Nothing is sent to AniList until Done.
    @State private var draft: TrackSearchResult?
    @State private var draftPrivate = false

    private var track: Track? { tracking.aniListTrack(for: entry) }

    var body: some View {
        NavigationStack {
            Group {
                if !tracking.isLoggedIn {
                    loggedOut
                } else if let track {
                    editor(track)
                } else if let draft {
                    draftForm(draft)
                } else {
                    search
                }
            }
            .navigationTitle("AniList")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if draft != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { draft = nil } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() }.bold() }
            }
            .overlay { if isBusy { ProgressView().controlSize(.large).padding(24).glassEffect(.regular, in: .rect(cornerRadius: 16)) } }
            .alert("Couldn't reach AniList", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(draft != nil)
        .onAppear { if query.isEmpty { query = entry.displayTitle } }
    }

    // MARK: Logged out

    private var loggedOut: some View {
        ContentUnavailableView {
            Label("Not logged in", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Log in to AniList to track your progress.")
        } actions: {
            Button("Log in") { run { try await tracking.login() } }.primaryActionStyle()
        }
    }

    // MARK: Search

    private var search: some View {
        List {
            Section {
                TextField("Search AniList", text: $query)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(runSearch)
            }
            Section {
                ForEach(results) { result in
                    Button { draft = result } label: { resultRow(result) }
                        .buttonStyle(.plain)
                }
            } footer: {
                if results.isEmpty && !isBusy {
                    Text("Search for the title, then pick the matching entry.")
                }
            }
        }
        .task { runSearch() }
    }

    private func resultRow(_ result: TrackSearchResult) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.cover) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary) }
                .frame(width: 44, height: 62).clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text([result.format, result.year.map(String.init),
                      result.totalChapters > 0 ? "\(result.totalChapters) ch" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, tracking.isLoggedIn else { return }
        searchTask?.cancel()
        searchTask = Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let found = try await tracking.search(text, kind: entry.kind)
                if !Task.isCancelled { results = found }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func draftForm(_ result: TrackSearchResult) -> some View {
        Form {
            Section { resultRow(result) }
            Section {
                Toggle("Private", isOn: $draftPrivate)
            } footer: {
                Text("Private entries stay off your AniList profile and activity feed. Tap Done to start tracking.")
            }
        }
    }

    /// Done binds a picked title with the chosen options, then closes the sheet.
    private func finish() {
        guard let result = draft else { dismiss(); return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                _ = try await tracking.bind(result, to: entry, isPrivate: draftPrivate, context: modelContext)
                draft = nil
                dismiss()
            } catch AniListError.cancelled {} catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Editor

    private func editor(_ track: Track) -> some View {
        let status = TrackStatus(rawValue: track.status) ?? .planning
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.headline)
                    if let url = URL(string: track.remoteURL) {
                        Link("Open on AniList", destination: url).font(.subheadline)
                    }
                }
            }
            Section {
                Picker("Status", selection: Binding(get: { status }, set: { new in
                    run { try await tracking.update(track, status: new, context: modelContext) }
                })) {
                    ForEach(TrackStatus.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: Binding(get: { Int(track.lastChapterRead) }, set: { new in
                    run { try await tracking.update(track, progress: new, context: modelContext) }
                }), in: 0...(track.totalChapters > 0 ? track.totalChapters : 10_000)) {
                    LabeledContent("Chapters", value: track.totalChapters > 0
                        ? "\(Int(track.lastChapterRead)) / \(track.totalChapters)" : "\(Int(track.lastChapterRead))")
                }
                Toggle("Private", isOn: Binding(get: { track.isPrivate }, set: { new in
                    run { try await tracking.update(track, isPrivate: new, context: modelContext) }
                }))
                Picker("Score", selection: Binding(get: { Int((track.score / 10).rounded()) }, set: { new in
                    run { try await tracking.update(track, score: Double(new) * 10, context: modelContext) }
                })) {
                    Text("—").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section {
                dateRow("Started", date: track.startDate) { new in
                    run { try await tracking.update(track, start: .some(new), context: modelContext) }
                }
                dateRow("Finished", date: track.finishDate) { new in
                    run { try await tracking.update(track, finish: .some(new), context: modelContext) }
                }
            }
            Section {
                Button("Stop tracking", role: .destructive) { confirmRemove = true }
                    .confirmationDialog("Stop tracking?", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove from AniList too", role: .destructive) { remove(track, remote: true) }
                        Button("Only stop tracking here") { remove(track, remote: false) }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        }
    }

    private func dateRow(_ title: String, date: Date?, set: @escaping (Date?) -> Void) -> some View {
        HStack {
            if let date {
                DatePicker(title, selection: Binding(get: { date }, set: { set($0) }), displayedComponents: .date)
                Button { set(nil) } label: { Label("Clear \(title.lowercased()) date", systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            } else {
                Text(title)
                Spacer()
                Button("Set") { set(.now) }.buttonStyle(.borderless)
            }
        }
    }

    private func remove(_ track: Track, remote: Bool) {
        run { try await tracking.remove(track, fromAniList: remote, context: modelContext) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do { try await work() } catch AniListError.cancelled {} catch { self.error = error.localizedDescription }
        }
    }
}
