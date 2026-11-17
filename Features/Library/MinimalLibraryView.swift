// MinimalLibraryView.swift
// Minimal Mode: the library alone on a full-screen dark surface, no tabs.
//
// Rows of tilted, overlapping covers that stack as they scroll under a floating
// serif title, over an ambient wash coloured by the book read most recently
// (`CoverTint`). A Liquid Glass bar at the bottom holds search, continue
// reading and refresh. It is a reader-style surface, so the dark background is
// the exception to the app's light field.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The Minimal Mode preference, shared by the Appearance screen and `ContentView`.
enum MinimalMode {
    static let enabledKey = "appearance.minimalMode"
}

struct MinimalLibraryView: View {
    /// An entry a `lnreader://entry` link asked for, pushed when it arrives.
    @Binding var openedEntry: SourceEntry?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(ReaderRouter.self) private var readerRouter

    @Query(
        filter: #Predicate<Entry> { $0.inLibrary },
        sort: \Entry.title
    )
    private var novels: [Entry]

    @Namespace private var bookTransitions
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    /// The colour of the most recently read book's cover, once `CoverTint` has it.
    @State private var ambientTint: Color?
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var showImportError = false
    /// Scroll haptics: the row under the reading line and when it last changed.
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var lastRowChange: TimeInterval = 0
    @AppStorage(MinimalMode.enabledKey) private var minimalMode = false

    private let rowHeight: CGFloat = 122
    private let topInset: CGFloat = 84

    var body: some View {
        AppNavigationStack(path: $navigationPath) {
            GeometryReader { screenGeo in
                // Rows measure themselves in global space, so the blur bands
                // are worked out against the whole screen, safe areas included.
                let screenHeight = screenGeo.size.height
                    + screenGeo.safeAreaInsets.top + screenGeo.safeAreaInsets.bottom

                ZStack {
                    ambientBackground
                        .ignoresSafeArea()
                        .animation(.easeInOut(duration: 0.55), value: ambientTint)

                    shelf(screenHeight: screenHeight)

                    vignettes(screenHeight: screenHeight)

                    VStack(spacing: 10) {
                        headerBar
                        if showSearch {
                            searchField
                                .appReveal(edge: .top)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        Spacer()
                    }

                    VStack {
                        Spacer()
                        MinimalLibraryBar(
                            resumeCoverURL: resumeEntry?.displayThumbnailURL,
                            canResume: resumeEntry != nil,
                            isSearching: showSearch,
                            isUpdating: libraryManager.isUpdating,
                            onSearch: toggleSearch,
                            onResume: resumeReading,
                            onRefresh: refreshLibrary
                        )
                        .padding(.bottom, 14)
                    }
                }
            }
            .appNavigationDestination(for: Entry.self) { novel in
                // A migrated entry takes the place of the one that left the
                // library, so Back goes here rather than to a dead page.
                EntryDetailView(entry: novel) { replacement in
                    if !navigationPath.isEmpty { navigationPath.removeLast() }
                    navigationPath.append(replacement)
                }
                .id(novel.persistentModelID)
                .bookZoom(from: novel.persistentModelID, in: bookTransitions)
            }
            // A linked entry that is not in the library: nothing stored to push.
            .appNavigationDestination(for: SourceEntry.self) { entry in
                EntryDetailView(sourceEntry: entry)
            }
            // A link can arrive before or after this screen appears; one path,
            // which clears the value so it cannot push twice.
            .onChange(of: openedEntry) { openLinkedEntry() }
            .task { openLinkedEntry() }
            .task(id: resumeEntry?.persistentModelID) {
                guard let url = resumeEntry?.displayThumbnailURL else {
                    ambientTint = nil
                    return
                }
                ambientTint = await CoverTint.color(for: url)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "epub"), .pdf].compactMap { $0 },
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let container = modelContext.container
                    Task {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        do {
                            // Parsing and writing a book is seconds of work: a background
                            // context, off the main thread. `@Query` picks the entry up on save.
                            try await Task.detached(priority: .userInitiated) {
                                let context = ModelContext(container)
                                if url.pathExtension.lowercased() == "pdf" { try LocalBookManager.importPDF(at: url, context: context) }
                                else { try LocalBookManager.importEPUB(at: url, context: context) }
                            }.value
                        } catch {
                            importError = error.localizedDescription
                            showImportError = true
                        }
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
            .appAlert("Import Error", isPresented: $showImportError, presenting: importError) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // The detail screens follow the dark surface, so the zoom transition
        // does not flip colour scheme mid-flight.
        .preferredColorScheme(.dark)
    }

    // MARK: - Shelf

    private func shelf(screenHeight: CGFloat) -> some View {
        let items = entries
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                Color.clear.frame(height: topInset)

                if novels.isEmpty {
                    emptyLibraryState
                } else if items.isEmpty {
                    noMatchesState
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.persistentModelID) { index, entry in
                        MinimalLibraryRow(
                            entry: entry,
                            rowHeight: rowHeight,
                            screenHeight: screenHeight,
                            namespace: bookTransitions
                        ) {
                            open(entry)
                        }
                        // Lower covers stack on top of upper ones.
                        .zIndex(Double(index))
                    }
                }

                // Room for the last rows to clear the bottom bar.
                Color.clear.frame(height: 150)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onScrollPhaseChange { _, phase in scrollPhase = phase }
        .onScrollGeometryChange(for: Int.self) { geometry in
            Int(((geometry.contentOffset.y + geometry.contentInsets.top) / rowHeight).rounded(.down))
        } action: { old, new in
            rowPassed(from: old, to: new, count: items.count)
        }
    }

    /// One click per book crossing the reading line, only while a finger or its
    /// momentum is moving the shelf, never past either end.
    private func rowPassed(from old: Int, to new: Int, count: Int) {
        guard old != new,
              scrollPhase == .interacting || scrollPhase == .decelerating,
              (0..<count).contains(new) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastRowChange
        lastRowChange = now
        let speed = dt > 0 ? Double(rowHeight) * Double(abs(new - old)) / dt : 0
        Haptics.shared.shelfRowPassed(speed: speed)
    }

    /// Darken the top under the title and only the last ~14% at the bottom,
    /// where the glass bar sits.
    private func vignettes(screenHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0.0),
                    .init(color: .black.opacity(0.32), location: 0.55),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 130)

            Spacer()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.3), location: 0.55),
                    .init(color: .black.opacity(0.55), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: screenHeight * MinimalLibraryRow.bottomBand)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Library")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .foregroundStyle(.white)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { value in
                            guard LibrarySwipeInteraction.isTitleSwipe(
                                horizontal: value.translation.width,
                                vertical: value.translation.height
                            ) else { return }
                            leaveMinimalMode()
                        }
                )
                .accessibilityHint("Swipe up or down to show the standard library.")
                .accessibilityAction(named: "Show standard library", leaveMinimalMode)

            Spacer(minLength: 0)

            overflowMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func leaveMinimalMode() {
        Haptics.shared.selection()
        withAnimation(AppMotion.tabSwitch(reduceMotion: reduceMotion)) {
            minimalMode = false
        }
    }

    /// Several actions, so the `…` menu earns its place; leaving Minimal Mode is
    /// the one that matters most, since the tab bar is the only other way out.
    private var overflowMenu: some View {
        AppMenu {
            Button {
                showFileImporter = true
            } label: {
                AppLabel("Import EPUB or PDF", systemName: "square.and.arrow.down")
            }

            Divider()

            Button {
                Haptics.shared.selection()
                minimalMode = false
            } label: {
                AppLabel("Turn off Minimal Mode", systemName: "square.grid.2x2")
            }
        } label: {
            AppIcon(systemName: "ellipsis", size: 17)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
                .appGlassEffect(.clear.interactive(), in: .circle)
        }
        .accessibilityLabel("Library actions")
    }

    private var searchField: some View {
        TextField("Search library", text: $searchText)
            .font(Typography.body)
            .foregroundStyle(.white)
            .tint(.white)
            .autocorrectionDisabled()
            .focused($searchFocused)
            .submitLabel(.search)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .appGlassEffect(.regular.tint(.white.opacity(0.12)).interactive(), in: .capsule)
            .padding(.horizontal, 20)
    }

    // MARK: - Ambient background

    /// The most recently read book's colour, washed over near-black. Neutral
    /// until `CoverTint` has an answer.
    private var ambientBackground: some View {
        let tint = ambientTint ?? Color(white: 0.08)
        return ZStack {
            Color(white: 0.03)
            tint.opacity(0.25)
            RadialGradient(
                colors: [tint.opacity(0.38), Color.black.opacity(0.9)],
                center: UnitPoint(x: 0.25, y: 0.22),
                startRadius: 20,
                endRadius: 520
            )
            LinearGradient(
                colors: [
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.75)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Empty states

    private var emptyLibraryState: some View {
        VStack(spacing: 14) {
            AppIcon(systemName: "books.vertical", size: 34, relativeTo: .title)
                .foregroundStyle(.white)
                .padding(.top, 80)

            Text("Library Empty")
                .font(.system(.title3, design: .serif, weight: .semibold))
                .foregroundStyle(.white)

            Text("Import a book, or turn Minimal Mode off to explore sources.")
                .font(Typography.body)
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)

            Button {
                showFileImporter = true
            } label: {
                AppLabel("Import EPUB", systemName: "square.and.arrow.down", size: 17, relativeTo: .body)
                    .frame(maxWidth: 240)
            }
            .appGlassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            Button {
                Haptics.shared.selection()
                minimalMode = false
            } label: {
                AppLabel("Turn off Minimal Mode", systemName: "square.grid.2x2", size: 17, relativeTo: .body)
                    .frame(maxWidth: 240)
            }
            .appGlassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(.horizontal, 32)
    }

    private var noMatchesState: some View {
        Text("Nothing matches “\(searchText)”")
            .font(Typography.body)
            .foregroundStyle(.white.opacity(0.68))
            .padding(.top, 40)
    }

    // MARK: - Entries

    /// Search first, then most recently read first, so the book in progress is
    /// at the top of the shelf.
    private var entries: [Entry] {
        let base = searchText.isEmpty
            ? novels
            : novels.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                    || ($0.displayAuthor ?? "").localizedCaseInsensitiveContains(searchText)
            }
        return base.sorted {
            ($0.lastReadAt ?? .distantPast, $0.dateAdded) > ($1.lastReadAt ?? .distantPast, $1.dateAdded)
        }
    }

    /// The library book read most recently: what the bar's centre resumes.
    private var resumeEntry: Entry? {
        var best: Entry?
        var bestDate = Date.distantPast
        for entry in novels {
            guard let date = entry.lastReadAt, date > bestDate else { continue }
            best = entry
            bestDate = date
        }
        return best
    }

    // MARK: - Actions

    private func open(_ entry: Entry) {
        Haptics.shared.impact(.light)
        navigationPath.append(entry)
    }

    private func toggleSearch() {
        Haptics.shared.selection()
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
            showSearch.toggle()
        }
        if showSearch {
            searchFocused = true
        } else {
            searchText = ""
            searchFocused = false
        }
    }

    /// Opens the last chapter read in a library book, where the reader left it.
    /// One small fetch on tap, not a `@Query` this screen keeps alive.
    private func resumeReading() {
        var descriptor = FetchDescriptor<History>(sortBy: [SortDescriptor(\.lastRead, order: .reverse)])
        descriptor.fetchLimit = 25
        let recent = (try? modelContext.fetch(descriptor)) ?? []
        guard let chapter = recent.lazy.compactMap(\.chapter).first(where: { $0.entry?.inLibrary == true }),
              let entry = chapter.entry else {
            if let entry = resumeEntry { open(entry) }
            return
        }
        Haptics.shared.impact(.light)
        readerRouter.open(
            sourceKey: entry.sourceKey,
            entryURL: entry.url,
            kind: entry.kind,
            chapterURL: chapter.url,
            chapterName: chapter.name
        )
    }

    private func refreshLibrary() {
        Haptics.shared.impact(.light)
        let context = modelContext, sources = sourceManager
        Task {
            await libraryManager.updateLibrary(context: context, sourceManager: sources)
        }
    }

    /// Push the entry a link asked for, once.
    private func openLinkedEntry() {
        guard let entry = openedEntry else { return }
        openedEntry = nil
        navigationPath.append(entry)
    }
}

// MARK: - Row

/// One book: a tilted cover with the title and author beside it. Rows blur as
/// they slide under the title, and again only inside the bottom band where the
/// glass bar sits. The effects run in `visualEffect`, so scrolling never
/// re-evaluates a row's body.
private struct MinimalLibraryRow: View {
    let entry: Entry
    let rowHeight: CGFloat
    let screenHeight: CGFloat
    var namespace: Namespace.ID
    let onTap: () -> Void

    /// The share of the screen, from the bottom, where rows blur out.
    nonisolated static let bottomBand: CGFloat = 0.14

    private static let coverLeading: CGFloat = 24
    private static let coverWidth: CGFloat = 92
    private static let textLeading: CGFloat = coverLeading + coverWidth + 24

    var body: some View {
        let height = screenHeight
        let tilt = baseTilt

        ZStack(alignment: .leading) {
            VStack {
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.11))
                    .frame(height: 0.6)
                    .padding(.leading, Self.textLeading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayTitle)
                    .font(Typography.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let author = entry.displayAuthor, !author.isEmpty {
                    Text(author)
                        .font(Typography.body)
                        .foregroundStyle(Color.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
            .padding(.leading, Self.textLeading)
            .padding(.trailing, 20)
            .visualEffect { content, proxy in
                let fade = Self.fade(proxy.frame(in: .global), screenHeight: height, bandStart: 1 - Self.bottomBand)
                return content
                    .blur(radius: fade.top * 8 + pow(fade.bottom, 1.35) * 12)
                    .opacity(max(0.18, 1 - fade.top * 0.45 - fade.bottom * 0.7))
            }

            EntryCoverView(url: entry.displayThumbnailURL, aspectRatio: 2 / 3, cornerRadius: 5)
                .frame(width: Self.coverWidth)
                .shadow(color: .black.opacity(0.6), radius: 10, x: 2, y: -4)
                .shadow(color: .black.opacity(0.4), radius: 14, x: 4, y: 8)
                .visualEffect { content, proxy in
                    let frame = proxy.frame(in: .global)
                    // The cover blurs a little later than its label.
                    let fade = Self.fade(frame, screenHeight: height, bandStart: 1 - Self.bottomBand * 0.75)
                    let drift = Double((frame.midY / max(1, height)) - 0.45) * 2.2
                    return content
                        .rotationEffect(.degrees(tilt + drift))
                        .blur(radius: fade.top * 9 + pow(fade.bottom, 1.45) * 14)
                }
                .bookTransitionSource(entry.persistentModelID, in: namespace)
                .padding(.leading, Self.coverLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.displayTitle)
        .accessibilityHint("Opens the book")
        .accessibilityAddTraits(.isButton)
    }

    /// 0...1 for how far the row is under the title (`top`) and into the bottom
    /// band (`bottom`, which starts at `bandStart` of the screen height).
    nonisolated private static func fade(_ frame: CGRect, screenHeight: CGFloat, bandStart: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let top = max(0, min(1, (128 - frame.minY) / 75))
        let start = screenHeight * bandStart
        let span = max(1, screenHeight - start)
        let bottom = max(0, min(1, (frame.midY - start) / span))
        return (top, bottom)
    }

    /// A tilt that stays the same per book, between -6° and 5°.
    private var baseTilt: Double {
        let sum = entry.displayTitle.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Double((sum % 12) - 6)
    }
}

// MARK: - Bottom bar

/// The Liquid Glass bar: search on the left, continue reading in a recessed
/// centre pill with the book's cover, refresh on the right.
private struct MinimalLibraryBar: View {
    let resumeCoverURL: String?
    let canResume: Bool
    let isSearching: Bool
    let isUpdating: Bool
    let onSearch: () -> Void
    let onResume: () -> Void
    let onRefresh: () -> Void

    private let pillWidth: CGFloat = 236
    private let pillHeight: CGFloat = 62
    private let innerPillWidth: CGFloat = 120
    private let innerPillHeight: CGFloat = 46
    private let ink = Color.white

    var body: some View {
        ZStack {
            Button(action: onResume) {
                HStack(spacing: 9) {
                    EntryCoverView(url: resumeCoverURL, aspectRatio: 2 / 3, cornerRadius: 3)
                        .frame(width: 22)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    Text("Resume")
                        .font(.system(.subheadline, design: .serif, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(width: innerPillWidth, height: innerPillHeight)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .appGlassEffect(.clear.interactive(), in: .capsule)
            .disabled(!canResume)
            .opacity(canResume ? 1 : 0.5)
            .accessibilityLabel("Continue reading")

            HStack(spacing: 0) {
                sideButton(systemName: isSearching ? "xmark" : "magnifyingglass", action: onSearch)
                    .accessibilityLabel(isSearching ? "Close search" : "Search library")

                Spacer().frame(width: innerPillWidth)

                Group {
                    if isUpdating {
                        ProgressView()
                            .tint(ink)
                            .frame(width: (pillWidth - innerPillWidth) / 2, height: pillHeight)
                    } else {
                        sideButton(systemName: "arrow.triangle.2.circlepath", action: onRefresh)
                    }
                }
                .accessibilityLabel(isUpdating ? "Updating library" : "Refresh library")
            }
            .frame(width: pillWidth, height: pillHeight)
        }
        .frame(width: pillWidth, height: pillHeight)
        .appGlassEffect(.clear.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }

    private func sideButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppIcon(systemName: systemName, size: 19)
                .foregroundStyle(ink)
                .frame(width: (pillWidth - innerPillWidth) / 2, height: pillHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MinimalLibraryView(openedEntry: .constant(nil))
        .modelContainer(for: [Entry.self, Chapter.self, History.self, Category.self], inMemory: true)
        .environment(SourceManager())
        .environment(LibraryManager())
        .environment(ReaderRouter())
}
