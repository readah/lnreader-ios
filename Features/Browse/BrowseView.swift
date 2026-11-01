// BrowseView.swift
// Sources, split by kind: light novels and manga are separate catalogues.
//
// Every source is built into the app, so each catalogue is just the registry filtered by kind.
// A native segmented control in a glass top bar switches between them in place.

import SwiftData
import SwiftUI

/// Which catalogue the browse screen is showing.
enum BrowseKind: String, CaseIterable, Identifiable {
    case novels
    case manga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .novels: "Light Novels"
        case .manga: "Manga"
        }
    }

    var contentKind: ContentKind {
        switch self {
        case .novels: .novel
        case .manga: .manga
        }
    }
}

struct BrowseView: View {
    @Environment(SourceManager.self) private var sourceManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("browse.kind") private var kindRaw = BrowseKind.novels.rawValue
    @State private var searchText = ""
    @State private var showDisplay = false
    /// Same keys as the Library's default display, so the two always agree.
    @AppStorage("general.defaultDisplayMode") private var displayMode = DisplayMode.comfortable
    @AppStorage(LibraryGridColumns.key) private var columnCount = LibraryGridColumns.automatic
    /// The source whose entries are being migrated, if any.
    @State private var migratingSource: MigratingSource?
    /// The source whose catalogue is open.
    @State private var openSource: SourceTarget?

    /// Library entries, only to count them per source: a source row says how many
    /// of its books are in the library, and offers to migrate them.
    @Query(filter: #Predicate<Entry> { $0.inLibrary }) private var libraryEntries: [Entry]

    private var kind: BrowseKind {
        BrowseKind(rawValue: kindRaw) ?? .novels
    }

    /// How many library entries came from each source.
    private var libraryCounts: [String: Int] {
        Dictionary(grouping: libraryEntries, by: \.sourceKey).mapValues(\.count)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Browse")
                .navigationBarTitleDisplayMode(.large)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .toolbar { toolbarContent }
                .sheet(isPresented: $showDisplay) {
                    NavigationStack {
                        DisplayOptionsList(
                            displayMode: $displayMode,
                            columnCount: $columnCount,
                            footer: "Applies to every source and to the Library. Auto fits as many covers as the screen allows."
                        )
                        .navigationTitle("Display")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showDisplay = false }.bold()
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
                // Holding a source with entries offers to move all of them, which
                // is the only bulk migration there is: the source is the unit.
                .sheet(item: $migratingSource) { source in
                    MigrateSourceSheet(sourceKey: source.key) { migratingSource = nil }
                }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showDisplay = true } label: {
                Image(systemName: "rectangle.grid.2x2")
            }
            .accessibilityLabel("Display")
        }
        if kind == .novels {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    GlobalSearchView()
                } label: {
                    Image(systemName: "text.magnifyingglass")
                }
                .accessibilityLabel("Search all sources")
            }
        }
    }

    // MARK: - Kind switcher

    /// Native segmented control: on iOS 26 it renders as glass and morphs the
    /// selection for free. It floats in the top bar so the list scrolls under it.
    private var kindSwitcher: some View {
        Picker("Catalogue", selection: $kindRaw) {
            ForEach(BrowseKind.allCases) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .hapticFeedback(.selection, trigger: kindRaw)
    }

    private var searchPrompt: String {
        kind == .novels ? "Search novel sources" : "Search manga sources"
    }

    // MARK: - Content

    /// One list for both catalogues. The switcher is its first row, so it scrolls
    /// away with the content instead of pinning over the navigation bar's search
    /// field, and switching kinds cross-fades rows in place: no second scroll view, no
    /// whole-page transition to lag behind the gesture.
    private var content: some View {
        List {
            Section {
                kindSwitcher
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            sourcesContent
        }
        // Rows cross-fade in place. Animating the rows, not the list, keeps the
        // scroll view (and the nav bar tracking it) alive, so it stays cheap.
        .animation(AppMotion.tabSwitch(reduceMotion: reduceMotion), value: kindRaw)
        .simultaneousGesture(kindSwipe)
        // Rows are buttons, not links: the hold needs to own the touch (see
        // `SourceRow`), so navigation goes through a destination instead.
        .navigationDestination(item: $openSource) { target in
            SourceDetailView(sourceKey: target.key, title: target.name)
        }
    }

    /// Steps between catalogues on a clearly horizontal swipe. Only reacts when
    /// the drag ends, so vertical scrolling is never touched.
    private var kindSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > 80, abs(dx) > abs(value.translation.height) * 2 else { return }
                let target: BrowseKind = dx < 0 ? .manga : .novels
                if target != kind { kindRaw = target.rawValue }
            }
    }

    @ViewBuilder
    private var sourcesContent: some View {
        if visibleSources.isEmpty {
            Section {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        kind == .novels ? "No novel sources" : "No manga sources",
                        systemImage: "books.vertical"
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .listRowBackground(Color.clear)
        } else {
            // Counted once for the whole list rather than per row.
            let counts = libraryCounts
            Section("Sources · \(visibleSources.count)") {
                ForEach(visibleSources, id: \.key) { source in
                    SourceRow(
                        source: source,
                        inLibrary: counts[source.key] ?? 0,
                        onOpen: { openSource = SourceTarget(key: source.key, name: source.name) },
                        onMigrate: { migratingSource = MigratingSource(key: source.key) }
                    )
                }
            }
        }
    }

    // MARK: - Filtering

    private var visibleSources: [any CatalogSource] {
        let all = sourceManager.sources(of: kind.contentKind)
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

/// A source selected for bulk migration. A `String` key is not `Identifiable`,
/// and the sheet needs one.
struct MigratingSource: Identifiable {
    let key: String
    var id: String { key }
}

/// A source to push the catalogue for. The rows are buttons, so navigation needs
/// a value to push rather than a `NavigationLink`.
private struct SourceTarget: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }
}

// MARK: - Row

/// One source: tap opens its catalogue, hold moves its library entries elsewhere.
///
/// Deliberately not a `NavigationLink` with a `.contextMenu`: the system menu
/// lifts the row into a preview and fades that whole overlay out on dismissal,
/// which reads as the screen sticking for a beat after you back out of it. A hold
/// that opens the sheet directly has nothing to fade. Same shape as
/// `InteractiveListRow` in the library, which is where this pattern comes from.
private struct SourceRow: View {
    let source: any CatalogSource
    let inLibrary: Int
    let onOpen: () -> Void
    let onMigrate: () -> Void

    /// Set when a hold fires, so the tap that ends the same touch does not also
    /// open the catalogue. Cleared on a timer as well, because a hold that opens a
    /// sheet may never report a tap at all.
    @State private var didHold = false

    var body: some View {
        Button {
            if didHold { didHold = false } else { onOpen() }
        } label: {
            HStack(spacing: 12) {
                SourceIconView(source: source, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if source.isAdult { adultChip }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // The rows are buttons, so the disclosure chevron is ours.
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard inLibrary > 0 else { return }
                Haptics.shared.impact(.medium)
                didHold = true
                Task { try? await Task.sleep(for: .milliseconds(600)); didHold = false }
                onMigrate()
            }
        )
        .accessibilityHint(inLibrary > 0
            ? "Hold to migrate \(inLibrary) \(inLibrary == 1 ? "entry" : "entries")"
            : "")
        // The hold is a gesture, so VoiceOver needs the same action by name.
        .accessibilityActions {
            if inLibrary > 0 {
                Button(inLibrary == 1 ? "Migrate entry" : "Migrate \(inLibrary) entries") {
                    onMigrate()
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !source.lang.isEmpty { parts.append(source.lang.uppercased()) }
        if !source.supportsLatest { parts.append("Popular only") }
        if inLibrary > 0 { parts.append("\(inLibrary) in library") }
        return parts.joined(separator: " · ")
    }

    private var adultChip: some View {
        Text("18+")
            .font(Typography.small.weight(.bold))
            .foregroundStyle(AppTheme.destructive)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(AppTheme.destructive.opacity(0.15), in: Capsule())
            .accessibilityLabel("Adult content")
    }
}
