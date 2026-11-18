// MinimalLibraryView.swift
// Minimal Mode's library page: the shelf alone on the dark surface.
//
// Rows of tilted, overlapping covers that stack as they scroll under a floating
// serif title. The bar at the bottom is the container's, not this page's: it
// stays put while the shelf moves behind it, so the page draws only the shelf,
// its title and its scrims. The page lives inside `MinimalModeView`'s vertical
// pager, which draws the ambient wash and owns the swipe. It is a reader-style
// surface, so the dark background is the exception to the app's light field.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The Minimal Mode preference, shared by the Appearance screen and `ContentView`.
enum MinimalMode {
    static let enabledKey = "appearance.minimalMode"
    /// The share of the screen, from the bottom, where the glass bar sits: the
    /// rows blur out into it and the container darkens the same band behind it.
    /// One number, because the two have to line up exactly.
    static let bottomBand: CGFloat = 0.14
}

struct MinimalLibraryView: View {
    /// An entry a `lnreader://entry` link asked for, pushed when it arrives.
    @Binding var openedEntry: SourceEntry?
    /// The full screen height, measured by the pager container.
    let screenHeight: CGFloat
    /// The safe-area band this page's chrome has to stay inside. The page is
    /// full screen so the pages tile without a gap, so the inset the container
    /// would otherwise give it is applied by hand.
    let safeTop: CGFloat

    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<Entry> { $0.inLibrary },
        sort: \Entry.title
    )
    private var novels: [Entry]

    @Namespace private var bookTransitions
    @State private var navigationPath = NavigationPath()
    /// Owned by the container, because the bar that toggles it is no longer
    /// this page's: it sits above the pages and never moves.
    @Binding var searchText: String
    @Binding var showSearch: Bool
    /// Pull-to-refresh runs the same update as the bar's button, which lives in
    /// the container.
    let onRefresh: () -> Void
    @FocusState private var searchFocused: Bool
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
            ZStack {
                shelf(screenHeight: screenHeight)

                // Above the shelf, below the chrome: the title and the bar stay
                // full strength while the rows darken into them.
                vignettes(screenHeight: screenHeight)

                VStack(spacing: 10) {
                    MinimalPageHeader(title: "Library") { overflowMenu }
                    if showSearch {
                        searchField
                            .appReveal(edge: .top)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Spacer()
                }
                .padding(.top, safeTop)
            }
            // Rows measure themselves against this, not the screen: a page
            // being swiped must not blur its own rows on the way out.
            .coordinateSpace(.named(MinimalPageSpace.name))
            // The bar's search button lives outside this page now, so the field
            // takes its focus from the state rather than from the tap.
            .onChange(of: showSearch) { _, showing in
                searchFocused = showing
                if !showing { searchText = "" }
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
            // Lazy, and it matters: a `VStack` builds every row of the library
            // — covers, two blur effects each — before the first frame is
            // drawn, which is what made turning Minimal Mode on crawl in a big
            // library.
            LazyVStack(spacing: 0) {
                // The page starts at the screen top now, so the title's band is
                // the safe area plus the room the header takes.
                Color.clear.frame(height: safeTop + topInset)

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
        .refreshable { onRefresh() }
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

    // MARK: - Vignettes

    /// Darken the top under the title and only the last band at the bottom,
    /// where the glass bar sits. This page draws its own scrims rather than the
    /// pager container, so the title and the bar are never dimmed by them and
    /// they travel with the shelf while it is being swiped away.
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
            .frame(height: screenHeight * MinimalMode.bottomBand)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Header

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

    // MARK: - Actions

    private func open(_ entry: Entry) {
        Haptics.shared.impact(.light)
        navigationPath.append(entry)
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
    nonisolated static var bottomBand: CGFloat { MinimalMode.bottomBand }

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
                let fade = Self.fade(proxy.frame(in: .named(MinimalPageSpace.name)), screenHeight: height, bandStart: 1 - Self.bottomBand)
                return content
                    .blur(radius: fade.top * 8 + pow(fade.bottom, 1.35) * 12)
                    .opacity(max(0.18, 1 - fade.top * 0.45 - fade.bottom * 0.7))
            }

            EntryCoverView(url: entry.displayThumbnailURL, aspectRatio: 2 / 3, cornerRadius: 5)
                .frame(width: Self.coverWidth)
                .shadow(color: .black.opacity(0.6), radius: 10, x: 2, y: -4)
                .shadow(color: .black.opacity(0.4), radius: 14, x: 4, y: 8)
                .visualEffect { content, proxy in
                    let frame = proxy.frame(in: .named(MinimalPageSpace.name))
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

#Preview {
    MinimalLibraryView(
        openedEntry: .constant(nil),
        screenHeight: 852,
        safeTop: 59,
        searchText: .constant(""),
        showSearch: .constant(false),
        onRefresh: {}
    )
    .environment(MinimalPager())
    .modelContainer(for: [Entry.self, Chapter.self, History.self, Category.self], inMemory: true)
    .environment(SourceManager())
    .environment(LibraryManager())
    .environment(ReaderRouter())
}
